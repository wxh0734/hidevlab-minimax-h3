#!/usr/bin/env bash
# =============================================================================
# h3_hidevlab.sh —— 在华为 HiDevLab（免费 100 卡时 / Ascend NPU）上部署
#                   MiniMax H3 视频生成（ComfyUI + INT8 权重）
#
# 上游仓库：https://ai.gitcode.com/xujiashuai/minimax-h3-int8
#           （Ascend 910 双卡 INT8 / 53GB 权重 / Turbo 8 步 / ComfyUI）
# 本脚本是「HiDevLab 适配层」，不改上游代码，只负责：
#   1) 把 53GB 权重落到挂载持久化目录（HiDevLab 非挂载目录上限 30GB！）
#   2) 复用 /shared_assets 里平台预置的权重，省掉下载
#   3) 自动定位 CANN set_env.sh 与带 torch_npu 的 Python
#   4) 按可见 NPU 数自动选双卡 / 单卡工作流
#   5) 补齐 jq / uv 等容器里常缺的命令
#   6) 服务管理 + 一键出测试片 + 关机刷新后幂等恢复
#
# 用法（在 HiDevLab WebIDE 终端里）：
#   bash h3_hidevlab.sh doctor     环境预检（第一步必跑）
#   bash h3_hidevlab.sh install    一键安装（代码 + 权重 + venv + NPU 补丁）
#   bash h3_hidevlab.sh start      启动 ComfyUI（8188）
#   bash h3_hidevlab.sh status     查看状态 / 健康检查
#   bash h3_hidevlab.sh logs       跟踪日志
#   bash h3_hidevlab.sh stop       停止服务
#   bash h3_hidevlab.sh test       用 API 工作流跑一条测试视频
#   bash h3_hidevlab.sh resume     容器刷新 / 关机开机后恢复（install + start）
#
# 可覆盖的环境变量：
#   PERSIST_DIR        挂载持久化目录（默认自动探测 /workspace/user_data）
#   ASCEND_HOME_PATH   含 set_env.sh 的 CANN 根目录（默认自动探测）
#   COMFY_PORT         ComfyUI 端口，默认 8188
#   CHUNK_N            权重分片并行连接数，默认 16
#   SKIP_SHARED_ASSETS 1 = 不扫描 /shared_assets
# =============================================================================
set -euo pipefail

REPO_NAME="minimax-h3-int8"
REPO_URL="https://atomgit.com/xujiashuai/minimax-h3-int8.git"
BOOTSTRAP_URL="https://atomgit.com/api/v5/repos/xujiashuai/minimax-h3-int8/raw/bootstrap.sh?ref=main"
COMFY_PORT="${COMFY_PORT:-8188}"
CHUNK_N="${CHUNK_N:-16}"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m OK \033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m WARN \033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m ERROR \033[0m %s\n' "$*" >&2; exit 1; }
line() { printf '%s\n' '------------------------------------------------------------'; }

# ---------------------------------------------------------------------------
# 探测
# ---------------------------------------------------------------------------
detect_persist() {
  if [ -n "${PERSIST_DIR:-}" ]; then echo "$PERSIST_DIR"; return; fi
  local d
  for d in /workspace/user_data /workspace /mnt/workspace /home/developer; do
    if [ -d "$d" ] && [ -w "$d" ]; then echo "$d"; return; fi
  done
  echo "$HOME"
}

detect_cann() {
  if [ -n "${ASCEND_HOME_PATH:-}" ] && [ -f "$ASCEND_HOME_PATH/set_env.sh" ]; then
    echo "$ASCEND_HOME_PATH"; return
  fi
  local c f
  for c in /usr/local/Ascend/ascend-toolkit/latest \
           /usr/local/Ascend/ascend-toolkit \
           /usr/local/Ascend/cann-8.5.1 \
           /home/miniconda3/Ascend/cann \
           "$HOME/miniconda3/Ascend/cann"; do
    [ -f "$c/set_env.sh" ] && { echo "$c"; return; }
  done
  f="$(find /usr/local/Ascend /opt /home -maxdepth 5 -name set_env.sh -print 2>/dev/null | head -n 1 || true)"
  [ -n "$f" ] && { dirname "$f"; return; }
  echo ""
}

detect_npu() {
  local n
  n="$(ls /dev/davinci[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] && { echo "$n"; return; }
  if command -v npu-smi >/dev/null 2>&1; then
    n="$(npu-smi info -l 2>/dev/null | grep -ci 'NPU ID' || true)"
    [ "${n:-0}" -gt 0 ] && { echo "$n"; return; }
  fi
  echo 0
}

detect_py() {
  local py bindir
  bindir="$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("BINDIR"))' 2>/dev/null || echo /usr/bin)"
  for py in "$bindir/python3" "$(command -v python3 || true)" \
            /usr/local/python3.11.14/bin/python3 /usr/bin/python3; do
    [ -x "$py" ] || continue
    if "$py" -c 'import torch, torch_npu' >/dev/null 2>&1; then echo "$py"; return; fi
  done
  echo ""
}

PERSIST_DIR="$(detect_persist)"
REPO_DIR="$PERSIST_DIR/$REPO_NAME"
OUTPUT_DIR="$PERSIST_DIR/h3-output"
SHIM_DIR="$PERSIST_DIR/bin"
ENV_FILE="$PERSIST_DIR/h3-env.sh"
CANN_HOME="$(detect_cann)"
NPU_COUNT="$(detect_npu)"
SYS_PY="$(detect_py)"

# ---------------------------------------------------------------------------
# 依赖补齐（容器常缺 jq / uv；无 root 时用 shim 兜底）
# ---------------------------------------------------------------------------
make_jq_shim() {
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/jq" <<'JQEOF'
#!/usr/bin/env bash
# 最小 jq 兼容层：仅实现上游 symlink 脚本用到的查询
if [ "${1:-}" = "-r" ]; then shift; fi
query="${1:-}"; file="${2:-}"
case "$query" in
  *'.files[]'*|*'@tsv'*)
    python3 - "$file" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for f in m["files"]:
    print(f["path"] + "\t" + f["target_dir"])
PY
    ;;
  *) echo "jq shim: 不支持的查询: $query" >&2; exit 2 ;;
esac
JQEOF
  chmod +x "$SHIM_DIR/jq"
  export PATH="$SHIM_DIR:$PATH"
  ok "已生成 jq 兼容层: $SHIM_DIR/jq"
}

ensure_deps() {
  local missing=0 c
  for c in git curl python3 sha256sum patch; do
    if ! command -v "$c" >/dev/null 2>&1; then
      warn "缺少 $c（openEuler: sudo dnf install -y git curl coreutils patch）"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "请先补齐基础命令再重跑"

  if ! command -v jq >/dev/null 2>&1; then
    say "补齐 jq"
    if command -v dnf >/dev/null 2>&1 && dnf install -y jq >/dev/null 2>&1; then
      ok "dnf 安装 jq 完成"
    elif command -v apt-get >/dev/null 2>&1 && apt-get install -y jq >/dev/null 2>&1; then
      ok "apt 安装 jq 完成"
    else
      make_jq_shim
    fi
  else
    ok "jq 就绪"
  fi

  export PATH="$HOME/.local/bin:$SHIM_DIR:$PATH"
  if ! command -v uv >/dev/null 2>&1; then
    say "补齐 uv（setup_comfyui.sh 需要）"
    python3 -m pip install --no-cache-dir \
      -i https://pypi.tuna.tsinghua.edu.cn/simple uv >/dev/null 2>&1 \
      || warn "uv 自动安装失败；可手动 pip install uv 后重跑"
  fi
  command -v uv >/dev/null 2>&1 && ok "uv 就绪" || warn "uv 仍不可用，setup 阶段会报错"
}

# ---------------------------------------------------------------------------
# 预检
# ---------------------------------------------------------------------------
preflight() {
  line
  echo " 架构          : $(uname -m)   （昇腾 NPU 实例应为 aarch64）"
  echo " 持久化目录    : $PERSIST_DIR"
  echo " CANN 根目录   : ${CANN_HOME:-未找到}"
  echo " 可见 NPU 数   : $NPU_COUNT"
  echo " torch_npu Py  : ${SYS_PY:-未找到}"
  echo " 安装目标      : $REPO_DIR"
  echo " 输出目录      : $OUTPUT_DIR"
  echo " 端口 / 分片   : $COMFY_PORT / $CHUNK_N"
  if command -v npu-smi >/dev/null 2>&1; then
    npu-smi info 2>/dev/null | grep -Ei 'Name|Chip|Health|Power' | head -n 8 || true
  fi
  if [ -n "$SYS_PY" ]; then
    "$SYS_PY" -c 'import torch,torch_npu; print(" torch 版本     :",torch.__version__); print(" torch_npu 版本:",torch_npu.__version__)' 2>/dev/null || true
  fi
  python3 -V 2>&1 | sed 's/^/ /'
  local avail
  avail="$(df -Pk "$PERSIST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$avail" ]; then
    echo " 可用空间      : $(( avail / 1048576 )) GB"
  fi
  if [ -d /shared_assets ]; then
    echo " /shared_assets: 存在（会尝试复用预置权重）"
  else
    echo " /shared_assets: 不存在（权重需完整下载约 53GB）"
  fi
  line

  [ -n "$CANN_HOME" ] || die '找不到 CANN 的 set_env.sh。请先 source 环境，或显式指定：export ASCEND_HOME_PATH=/path/to/cann'
  [ "$NPU_COUNT" -ge 1 ] || die '未检测到 NPU（/dev/davinci* 为空）。请确认创建环境时选的是昇腾算力规格'
  [ -n "$SYS_PY" ] || die '系统 Python 里没有 torch_npu。请改选预置 PyTorch/CANN 业务镜像，或先 source CANN set_env.sh'
  if [ -n "$avail" ] && [ "$avail" -lt 60000000 ]; then
    die "挂载目录可用空间不足 60GB（权重 53GB + venv）。当前 $(( avail / 1048576 ))GB。请确认 $PERSIST_DIR 是挂载目录，别把权重放非挂载目录（上限 30GB）"
  fi
  case "$(python3 -c 'import sys;print("%d%d"%(sys.version_info[0],sys.version_info[1]))' 2>/dev/null)" in
    311) ok "Python 3.11 —— 与上游补丁匹配" ;;
    *)   warn "Python 不是 3.11：上游 setup_comfyui.sh 里 comfy_kitchen 补丁路径硬编码 python3.11，很可能失败。建议重建环境时选 openeuler24.03-python3.11-base 镜像" ;;
  esac
  ok "预检通过"
}

cmd_doctor() { preflight; }

# ---------------------------------------------------------------------------
# 复用平台预置权重
# ---------------------------------------------------------------------------
link_shared_assets() {
  [ "${SKIP_SHARED_ASSETS:-0}" = "1" ] && { warn "按 SKIP_SHARED_ASSETS=1 跳过"; return; }
  [ -d /shared_assets ] || { warn "/shared_assets 不存在，跳过复用"; return; }
  say "扫描 /shared_assets 是否已有 H3 权重"
  local manifest="$REPO_DIR/MANIFEST.json"
  [ -f "$manifest" ] || { warn "MANIFEST.json 不存在，跳过复用"; return; }
  mkdir -p "$REPO_DIR/models"
  local hits=0
  while IFS=$'\t' read -r name size sha; do
    [ -n "$name" ] || continue
    local dest="$REPO_DIR/models/$name"
    [ -f "$dest" ] && continue
    local src
    src="$(find /shared_assets -type f -name "$name" -size "+1M" -print 2>/dev/null | head -n 1 || true)"
    if [ -n "$src" ] && [ "$(stat -c %s "$src" 2>/dev/null || echo 0)" = "$size" ]; then
      ln -s "$src" "$dest"
      ok "复用: $(basename "$name")  <-  $src"
      hits=$(( hits + 1 ))
    fi
  done < <(python3 - "$manifest" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    n = f["path"].split("/")[-1]
    print("%s\t%s\t%s" % (n, f["size_bytes"], f["sha256"]))
PY
)
  if [ "$hits" -eq 0 ]; then
    warn "未命中预置权重，53GB 全部需要下载"
  else
    ok "命中 $hits 个，下载脚本会用 SHA-256 复核，不合格会自动重下"
  fi
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
write_env_file() {
  local wf="api_t2v_int8_turbo.json"
  [ "$NPU_COUNT" -lt 2 ] && wf="api_t2v_int8_single.json"
  cat > "$ENV_FILE" <<EOF
# 由 h3_hidevlab.sh 自动生成；start / test / resume 会读取
export PERSIST_DIR="$PERSIST_DIR"
export REPO_DIR="$REPO_DIR"
export ASCEND_HOME_PATH="$CANN_HOME"
export SYS_PY="$SYS_PY"
export NPU_COUNT="$NPU_COUNT"
export H3_WORKFLOW="$wf"
export COMFY_PORT="$COMFY_PORT"
export COMFY_OUTPUT_DIR="$OUTPUT_DIR"
export PATH="$SHIM_DIR:\$HOME/.local/bin:\$PATH"
EOF
  ok "环境文件: $ENV_FILE"
}

cmd_install() {
  say "0/6 环境预检"
  preflight
  ensure_deps

  say "1/6 拉取代码（跳过 LFS，权重稍后单独下，便于复用 /shared_assets）"
  curl -fsSL "$BOOTSTRAP_URL" | \
    INSTALL_DIR="$PERSIST_DIR" SKIP_WEIGHTS=1 CHUNK_N="$CHUNK_N" bash
  [ -d "$REPO_DIR/.git" ] || die "代码拉取失败：$REPO_DIR 不存在"
  ok "代码就位: $REPO_DIR"

  say "2/6 复用平台预置权重（若有）"
  link_shared_assets

  say "3/6 下载 INT8 权重（约 53GB，首次 25-45 分钟；断点续传，已完整自动跳过）"
  ( cd "$REPO_DIR" && CHUNK_N="$CHUNK_N" bash scripts/download_weights_curl.sh )
  local cnt
  cnt="$(find "$REPO_DIR/models" -maxdepth 1 -name '*.safetensors' | wc -l | tr -d ' ')"
  [ "$cnt" -ge 4 ] || die "权重不完整：只找到 $cnt 个 safetensors（至少 4 个必需）"
  ok "权重就绪：$cnt 个文件"

  say "4/6 建立权重软链 + 创建 venv + 打 NPU 补丁"
  export ASCEND_HOME_PATH="$CANN_HOME"
  [ -n "$SYS_PY" ] && export PATH="$(dirname "$SYS_PY"):$PATH"
  export PATH="$SHIM_DIR:$HOME/.local/bin:$PATH"
  ( cd "$REPO_DIR" && bash scripts/setup_comfyui.sh ) \
    || die "setup_comfyui.sh 失败。多半是 Python 版本非 3.11 或 comfy-kitchen 版本与补丁不符，看上面报错定位"
  ok "NPU 补丁与 venv 完成"

  say "5/6 写环境文件"
  write_env_file

  say "6/6 完成"
  mkdir -p "$OUTPUT_DIR"
  line
  echo " 下一步："
  echo "   bash h3_hidevlab.sh start      # 启动 ComfyUI"
  echo "   bash h3_hidevlab.sh status     # 确认 type=npu"
  echo "   bash h3_hidevlab.sh test       # 跑一条测试视频"
  echo " 生成目录：$OUTPUT_DIR"
  echo " 工作流  ：$(grep '^export H3_WORKFLOW' "$ENV_FILE")"
  line
}

# ---------------------------------------------------------------------------
# 服务管理
# ---------------------------------------------------------------------------
load_env() {
  if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"; fi
  REPO_DIR="${REPO_DIR:-$PERSIST_DIR/$REPO_NAME}"
  OUTPUT_DIR="${COMFY_OUTPUT_DIR:-$PERSIST_DIR/h3-output}"
  COMFY_PORT="${COMFY_PORT:-8188}"
  NPU_COUNT="${NPU_COUNT:-$(detect_npu)}"
  CANN_HOME="${ASCEND_HOME_PATH:-$(detect_cann)}"
  H3_WORKFLOW="${H3_WORKFLOW:-api_t2v_int8_turbo.json}"
  [ -d "$REPO_DIR/.git" ] || die "未安装：找不到 $REPO_DIR。先跑 bash h3_hidevlab.sh install"
}

cmd_start() {
  load_env
  say "启动 ComfyUI（端口 $COMFY_PORT，NPU=$NPU_COUNT）"
  export ASCEND_HOME_PATH="$CANN_HOME"
  export COMFY_PORT="$COMFY_PORT"
  export COMFY_OUTPUT_DIR="$OUTPUT_DIR"
  if [ "$NPU_COUNT" -ge 2 ]; then
    unset ASCEND_RT_VISIBLE_DEVICES || true
    ok "双卡模式：扩散+VAE 在 npu:0，文本编码器在 npu:1，工作流 $H3_WORKFLOW"
  else
    export ASCEND_RT_VISIBLE_DEVICES=0
    warn "单卡模式：文本编码器退回 CPU，会慢 3-5 倍，工作流 $H3_WORKFLOW"
  fi
  ( cd "$REPO_DIR" && bash scripts/start-comfyui-dual-npu.sh start )
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1; then
      ok "服务已就绪"
      curl -s "http://127.0.0.1:$COMFY_PORT/system_stats" | python3 -m json.tool 2>/dev/null | head -n 20 || true
      echo ""
      echo " WebIDE 里打开「端口」面板 → 转发 $COMFY_PORT → 浏览器访问即可"
      return 0
    fi
    sleep 3
  done
  warn "90 秒内未就绪，看日志：bash h3_hidevlab.sh logs"
  return 1
}

cmd_stop() {
  load_env
  ( cd "$REPO_DIR" && bash scripts/start-comfyui-dual-npu.sh stop )
  ok "已停止"
}

cmd_status() {
  load_env
  ( cd "$REPO_DIR" && bash scripts/start-comfyui-dual-npu.sh status ) || true
  echo ""
  if curl -sf "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1; then
    ok "HTTP 健康检查通过"
    curl -s "http://127.0.0.1:$COMFY_PORT/system_stats" | python3 -m json.tool 2>/dev/null | head -n 25 || true
  else
    warn "HTTP 未响应（服务未启动或仍在加载模型）"
  fi
  echo ""
  echo " 输出视频：$(find "$OUTPUT_DIR" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ') 个，目录 $OUTPUT_DIR"
}

cmd_logs() {
  load_env
  local f="$REPO_DIR/third_party/ComfyUI/logs/comfyui.log"
  [ -f "$f" ] || die "日志文件不存在：$f"
  tail -n 60 -f "$f"
}

# ---------------------------------------------------------------------------
# 出测试片
# ---------------------------------------------------------------------------
cmd_test() {
  load_env
  local wf="$REPO_DIR/workflows/$H3_WORKFLOW"
  [ -f "$wf" ] || die "工作流不存在：$wf"
  curl -sf "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1 \
    || die "ComfyUI 没在跑，先 bash h3_hidevlab.sh start"
  say "提交测试任务：$H3_WORKFLOW （双卡 Turbo 约 76s，单卡 CPU 编码约 550s）"
  python3 - "$wf" "$COMFY_PORT" <<'PY'
import json, sys, time, urllib.request

wf_path, port = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:%s" % port
wf = json.load(open(wf_path, encoding="utf-8"))
body = json.dumps({"prompt": wf, "client_id": "hidevlab-h3"}).encode("utf-8")
req = urllib.request.Request(base + "/prompt", data=body,
                             headers={"Content-Type": "application/json"})
try:
    pid = json.load(urllib.request.urlopen(req, timeout=30))["prompt_id"]
except Exception as e:
    print("提交失败:", e)
    sys.exit(1)
print("prompt_id =", pid, flush=True)

deadline = time.time() + 900
while time.time() < deadline:
    time.sleep(5)
    try:
        hist = json.load(urllib.request.urlopen(base + "/history/" + pid, timeout=15))
    except Exception:
        continue
    if pid not in hist:
        continue
    item = hist[pid]
    status = item.get("status", {})
    if status.get("completed"):
        print("完成 ✓")
        for node_out in item.get("outputs", {}).values():
            for key in ("images", "videos", "gifs"):
                for v in node_out.get(key, []):
                    print("  产物:", v.get("filename"), "子目录:", v.get("subfolder", ""))
        sys.exit(0)
    if status.get("status_str") == "error":
        print("任务失败:", json.dumps(status, ensure_ascii=False)[:1500])
        sys.exit(2)
print("超时（15 分钟）。看日志：bash h3_hidevlab.sh logs")
sys.exit(3)
PY
  ok "测试完成，视频在 $OUTPUT_DIR"
}

cmd_resume() {
  say "容器刷新 / 关机开机后恢复（install 幂等：代码 git pull、权重校验跳过、补丁 dry-run 跳过）"
  cmd_install
  cmd_start
}

cmd_gen() {
  load_env
  local prompt="${1:-}"
  [ -n "$prompt" ] || die '用法：bash h3_hidevlab.sh gen "你的视频提示词"'
  local wf="$REPO_DIR/workflows/$H3_WORKFLOW"
  [ -f "$wf" ] || die "工作流不存在：$wf"
  curl -sf "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1 \
    || die "ComfyUI 没在跑，先 bash h3_hidevlab.sh start"
  say "生成：$prompt"
  python3 - "$wf" "$COMFY_PORT" "$prompt" <<'PY'
import json, sys, time, urllib.request

wf_path, port, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
base = "http://127.0.0.1:%s" % port
wf = json.load(open(wf_path, encoding="utf-8"))
changed = 0
for node in wf.values():
    if not isinstance(node, dict):
        continue
    inp = node.get("inputs", {})
    if isinstance(inp.get("text"), str) and changed == 0:
        inp["text"] = prompt
        changed += 1
if changed == 0:
    print("警告：工作流没找到 text 字段，沿用内置提示词", flush=True)

body = json.dumps({"prompt": wf, "client_id": "hidevlab-h3"}).encode("utf-8")
req = urllib.request.Request(base + "/prompt", data=body,
                             headers={"Content-Type": "application/json"})
try:
    pid = json.load(urllib.request.urlopen(req, timeout=30))["prompt_id"]
except Exception as e:
    print("提交失败:", e)
    sys.exit(1)
print("prompt_id =", pid, flush=True)

deadline = time.time() + 900
while time.time() < deadline:
    time.sleep(5)
    try:
        hist = json.load(urllib.request.urlopen(base + "/history/" + pid, timeout=15))
    except Exception:
        continue
    if pid not in hist:
        continue
    item = hist[pid]
    st = item.get("status", {})
    if st.get("completed"):
        print("完成 ✓")
        for out in item.get("outputs", {}).values():
            for key in ("videos", "images", "gifs"):
                for v in out.get(key, []):
                    print("  产物:", v.get("filename"), "子目录:", v.get("subfolder", ""))
        sys.exit(0)
    if st.get("status_str") == "error":
        print("任务失败:", json.dumps(st, ensure_ascii=False)[:1500])
        sys.exit(2)
print("超时（15 分钟），看日志：bash h3_hidevlab.sh logs")
sys.exit(3)
PY
  ok "视频在 $OUTPUT_DIR（含 H.264 画面 + AAC 原生音轨）"
}

usage() {
  cat <<'EOF'
h3_hidevlab.sh —— HiDevLab 上部署 MiniMax H3 视频生成

  doctor   环境预检（第一步必跑，检查 CANN / NPU / torch_npu / 磁盘）
  install  一键安装：代码 + 53GB INT8 权重 + venv + NPU 补丁
  start    启动 ComfyUI（8188），自动选双卡 / 单卡工作流
  status   服务状态 + HTTP 健康检查 + 已生成视频数
  logs     跟踪 comfyui.log
  stop     停止服务（关机前建议先停）
  test     用内置工作流跑一条测试视频
  gen "提示词"   替换提示词并出片（最常用）
  resume   容器刷新后恢复（install + start）

示例：
  bash h3_hidevlab.sh doctor
  bash h3_hidevlab.sh install
  bash h3_hidevlab.sh start
  bash h3_hidevlab.sh gen "A chef lifts a bowl of beef noodles, steam rising, slow push in"
EOF
}

case "${1:-help}" in
  doctor)  cmd_doctor ;;
  install) cmd_install ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  test)    cmd_test ;;
  gen)     cmd_gen "${2:-}" ;;
  resume)  cmd_resume ;;
  help|*)  usage ;;
esac
