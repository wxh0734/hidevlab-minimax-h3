# HiDevLab 免费 100 卡时 · 从零部署 MiniMax H3 视频生成

> 目标：在华为 HiDevLab 的昇腾 NPU 云环境里，把 **MiniMax H3**（原生带音频的视频生成）跑起来，能用自己的提示词出 MP4。
> 方案：基于开源仓库 `xujiashuai/minimax-h3-int8`（Ascend 910 双卡 INT8 / ComfyUI / 53GB 权重 / Turbo 8 步最快 76 秒），本项目加一层 HiDevLab 适配脚本。
> 时间预期：首次约 **40–60 分钟**（其中 53GB 权重下载 25–45 分钟），之后每次开机约 2 分钟。

---

## 0. 交付物与能力边界

| 文件 | 作用 |
|---|---|
| `h3_hidevlab.sh` | 一键脚本：`doctor / install / start / stop / status / logs / test / gen / resume` |
| `HiDevLab-H3-从零部署教程.md` | 本教程 |

脚本是**在你自己的 HiDevLab WebIDE 终端里执行**的——云端环境需要你的账号登录，我无法代登。教程里所有命令都做成「复制一整块粘贴即可」，不需要你理解每一行。

### 极简速查卡（装好以后日常就用这几条）

```bash
cd /workspace/user_data
bash h3_hidevlab.sh start
bash h3_hidevlab.sh gen "A chef lifts a bowl of beef noodles, steam rising, slow push in"
bash h3_hidevlab.sh status
bash h3_hidevlab.sh stop
```

---

## 1. 先看懂 HiDevLab 的规则（这决定了脚本怎么写）

从你的控制台截图 + 官方在线开发页核实：

| 规则 | 具体值 | 对部署的影响 |
|---|---|---|
| 初始卡时 | **100 / 100**，已用 0 | 2 NPU 规格 ≈ **2 卡时/小时**，即约 50 小时可用 |
| 计费 | 1NPU≈1、2NPU≈2、4NPU≈4 卡时/小时；**关机即停扣** | 不用就关机，别挂着 |
| 自动关机 | 连续 **1 小时未操作**自动关机 | 下载 53GB 期间别离开太久，或在终端保持活动 |
| 自动回收 | 连续运行 **>8 小时**可能被回收；停机超 **2 周**删除环境 | 一次装完，权重放挂载目录 |
| 挂载目录 | 创建环境时列表里的「挂载目录」列，典型 `/workspace/user_data`；关机保留、删除清除 | **53GB 权重必须放这里** |
| 非挂载目录 | 上限 **30GB**，超限会导致镜像异常 | 千万别用默认 `/data`（上游脚本默认值） |
| `/workspace` | 服务本地目录，高 IO，容量上限 300GB | 可作备选安装根 |
| `/shared_assets` | 平台预置常见模型权重/软件包，官方建议优先使用 | 脚本会自动扫描复用，命中可省 53GB 下载 |
| 算力类型 | 资格池 A2/A3/950PR，规格 1 / 2 / 4 NPU | 本项目只走 **A2 / 2 NPU**；950PR 是 arch35 + CANN 9.x，与 H3 补丁不兼容（见下方前置一步） |
| 镜像 | 预置 CANN / PyTorch / vLLM / SGLang 等，例 `openeuler24.03-python3.11-base` | 建议选 **Python 3.11 + PyTorch/CANN 业务镜像** |

> **最重要的一条**：上游 `minimax-h3-int8` 默认把 53GB 权重装到 `/data`（那是 AtomGit/CANNLab 的 empty-dir）。HiDevLab 没有这个约定，且非挂载目录只有 30GB——直接照抄官方一条 curl 会撑爆镜像。本脚本强制把 `INSTALL_DIR` 指到挂载目录。

### 前置一步（仅首次）：「开通算力资格」这一页怎么选

第一次进在线开发会先跳到「在线开发 > 开发环境 > **开通算力资格**」，三步：① 选择算力 → ② 填写开通信息 → ③ 提交。页面给三个勾选项：「全部算力资格」「950系列」「A3/A2/310P系列」。

**这一步不是选本次环境的规格**，只是开通你账号有资格使用的算力池。官方在线开发页原文：

> 支持多账户（HUAWEI、GitCode、GitHub），选择所需算力（A2/A3/950PR），**开通长期有效**，**仅首次操作**；创建环境才「选择算力规格与预置镜像」；「高峰时段资源紧张，可尝试切换算力类型」。

| 场景 | 选法 |
|---|---|
| 允许全选、无需额外说明 | **勾「全部算力资格」** —— 一次开完，后面 950 池空闲时也能临时换，资格≠实际使用，不多扣卡时 |
| 只能单选 / 要填用途说明 / 想尽快过审 | **只勾「A3/A2/310P系列」** |
| 本项目的实际使用 | 下一步创建环境仍按 **A2 / 2 * NPU** 选（见下表） |

**别为了「新」去选 950 系列跑 H3**，四个硬原因：

1. 架构跨代：A2(910B)/A3(910C) 是 `arch22 / 2201`，950PR/950DT 是 `arch35 / 3510`（SIMD→SIMD+SIMT、L0 分形 ZZ→NZ、Fixpipe 参数全变）。跨代算子不是重编译就能跑。
2. CANN 代差：950PR 要 **CANN 9.0.0+**、950DT 要 **9.1.0+**；本套部署验证组合是 **CANN 8.5.1 / torch 2.9.0+cpu / torch_npu 2.9.0.post1 / ComfyUI 0.33.1**，NPU 补丁与 comfy-kitchen 补丁都按 910 写死。
3. 工作流按 2×64GiB A2 双卡切分（扩散+VAE 在 npu:0、文本编码器在 npu:1）；950 的 128GB 大显存在这里用不上，反而缺现成的 INT8 权重与双卡工作流。
4. 950 池资源更紧、排队概率高，100 卡时经不起空等。

#### 第 2 步「填写开通信息」逐项怎么填

| 字段 | 推荐填法 | 理由 |
|---|---|---|
| 您的身份角色是什么 | **社区开发者** | 个人/开源开发者身份；高校开发者、企业开发者通常要对应资质或邮箱，没必要多一道证明 |
| **开源项目链接**（选社区开发者后才出现，带 `*` 必填） | **自己真实的公开仓库 URL**（GitHub / GitCode 均可） | 这是社区开发者身份的核验材料，必须填、且链接要能公开打开。没有现成仓库就新建一个公开仓，把本教程与脚本推上去（内容与补充说明完全对得上，最好过审）；命令见下方 |
| 是否有华为合作项目 | **否** | 没有合作项目编号；勾「是」多半要补项目信息，容易卡审核 |
| 资源用途（多选） | ☑ **模型推理** ☑ **应用迁移调试** | H3 是视频生成推理 + 把 ComfyUI/CUDA 生态往 NPU 迁移适配；**不要**勾模型训练、算子开发（我们确实不做） |
| 涉及框架/工具链（多选） | ☑ **CANN** ☑ **PyTorch** | 实际只用这两个（`torch_npu` 是 PyTorch 的 NPU 后端）；vLLM / Triton / TileLang / SGLang / veRL / MindIE / MindSpore / MindSpeed / MindStudio / MindSDK / MindCluster 全不勾，多勾显得用途不清 |
| 补充说明（0/200） | 见下方文案，直接复制 | 写具体、可验证的技术目标，别写「学习体验」「测试一下」这类空话 |

补充说明文案（约 90 字，可直接粘贴）：

```
在昇腾 A2 环境上完成 MiniMax-H3 视频生成模型的 ComfyUI 推理适配与验证，
基于 CANN 与 PyTorch(torch_npu) 调试 NPU 补丁、INT8 权重加载及双卡工作流，
产出可复现的开源部署文档与工作流，用于社区技术分享。
```

**没有自己的公开仓库？3 分钟现开一个。** 本目录已备好可直接上传的三个文件：`README.md`、`HiDevLab-H3-从零部署教程.md`、`h3_hidevlab.sh`（均已检查，**无 token / 密钥 / 内网地址**，可安全公开）。

#### 路线 A（推荐）：网页端建仓 + 网页端上传，零配置

适合 GitHub / GitCode 网页已登录、但本机 git 没配代理或没配 Personal Access Token 的情况——全程不碰命令行：

1. 右上角 `+` → **New repository**（或主页「All repositories」旁的 `+`）。
2. Repository name 填 `hidevlab-minimax-h3`；Description 填「HiDevLab 昇腾 A2 上部署 MiniMax H3 视频生成」。
3. **必须选 Public**；`Add a README file` / `.gitignore` / `license` **全部不勾**（保持空仓，避免与要上传的 README.md 同名冲突）。
4. 点 **Create repository**。
5. 在空仓页面点 **uploading an existing file**（或 `Add file` → `Upload files`），把上面三个文件拖进去。Windows 文件选择器里最省事的做法：在地址栏粘贴 `C:\Users\Administrator\WorkBuddy\2026-11-10-10-45-00\HiDevLab-H3` 回车 → `Ctrl+A` 全选（目录里正好只有这三个文件）→ 打开。
6. Commit message 填 `docs: add HiDevLab MiniMax H3 deployment guide`，点 **Commit changes**。
7. 复制地址栏 URL（形如 `https://github.com/<你的用户名>/hidevlab-minimax-h3`），填进「开源项目链接」。**注意去掉结尾的 `.git`** —— Quick setup 蓝框里那个 `....git` 是 clone 地址，不是项目主页地址。
8. 用**退出登录的浏览器或无痕窗口**再打开一次该 URL，确认能公开访问——审核要能点开。

> **空仓不能提交**：刚建好的公开仓打开是 `This repository is empty.`，此时把链接填进表单，审核点开看不到任何内容，基本会被驳回。**必须先完成第 5–6 步上传文件**，看到 README 渲染出来再提交。

#### 路线 B（可选）：本地 git push

需要本机可访问 GitHub/GitCode 且已配置 PAT 或凭据；国内网络通常还要挂代理。若浏览器能开网页但命令行连不上，直接走路 A。

```bash
cd /c/Users/Administrator/WorkBuddy/2026-11-10-10-45-00/HiDevLab-H3
git init -b main
git config user.name  "你的用户名"
git config user.email "你的邮箱"
git add README.md "HiDevLab-H3-从零部署教程.md" h3_hidevlab.sh
git commit -m "docs: HiDevLab 昇腾 A2 部署 MiniMax H3 视频生成"
git remote add origin https://github.com/<你的用户名>/hidevlab-minimax-h3.git
git push -u origin main
# 若网络不通，再按需加代理：git -c http.proxy=http://<代理地址:端口> push -u origin main
```

> 不要填：个人主页 URL、私有/空仓库、打不开的链接、随便一个不相干的大项目——审核打不开基本直接驳回。
> 兜底（不推荐）：可填本项目依托的上游开源仓 `https://ai.gitcode.com/xujiashuai/minimax-h3-int8`，但需把补充说明改成「基于该开源项目开展昇腾 A2 适配验证与文档贡献」，且存在被判为「非本人项目」追问的风险。

#### 第 3 步「提交」之后

这一步本质是**权限申请**，提交后不一定马上能建环境：

- 去 **个人中心 → 权限管理** 看审核状态；若仍显示审核中，等通过再点「创建环境」。
- 平台操作指南（第三方整理版）写明需「选择身份角色并完成对应内容填写 → 提交 → 在权限管理查看审核状态」；比赛类申请一般 1–2 个工作日审批，普通申请通常更快，**具体时长官方在线开发页未承诺**。
- 权限是**长期有效、仅首次开通**，通过后不用再填；之后创建环境直接选规格。
- 审核通过后回到「开发环境」页点「创建环境」，才进入真正的规格选择（下一节）。

---

## 2. Step 1 · 创建开发环境

1. 打开 https://hidevlab.huawei.com → 顶部「在线开发」→「前往开发环境」。
2. 点 **创建环境**，按下表选：

| 配置项 | 推荐值 | 说明 |
|---|---|---|
| 算力类型 | **昇腾算力 / A2（910B）** | 上游在 Ascend 910 上验证；A3 也可，但补丁按 910 写 |
| 配置规格 | **2 * NPU**（≥64GiB HBM/卡） | 双卡：扩散+VAE 在 npu:0，文本编码器在 npu:1，Turbo 8 步约 76 秒。抢不到 2 卡就选 1 NPU，脚本会自动切单卡工作流（文本编码器退回 CPU，约 550 秒/条） |
| 选择镜像 | **openeuler24.03-python3.11-base** 或带 PyTorch/CANN 的业务镜像 | 上游 `setup_comfyui.sh` 里 comfy-kitchen 补丁路径硬编码 `python3.11`，**非 3.11 会失败** |
| 存储大小 | **300G** | 权重 53G + venv + 输出，别省 |
| 环境名称 | `h3video` | 随意，≤15 字符、不以数字开头 |

3. 确认后等 1–2 分钟，状态变「运行中 / 已就绪」。
4. **记下列表里「挂载目录」一列的实际值**（通常是 `/workspace/user_data`）。后面所有路径以它为准；脚本也会自动探测。

---

## 3. Step 2 · 连接 WebIDE 并打开终端

- 操作栏「连接」→「WebIDE」，浏览器里打开 VS Code 版 IDE。
- 菜单 **终端 → 新建终端**（或 `` Ctrl+` ``）。
- 先跑三条确认环境：

```bash
uname -m                      # 应为 aarch64
ls /dev/davinci*              # 有几张卡就列几个，2 NPU 应有 2 个
npu-smi info                  # 看芯片型号与显存
python3 -c 'import torch, torch_npu; print(torch.__version__, torch_npu.__version__)'
```

最后一条若报 `No module named torch_npu`，**换带 PyTorch/CANN 的预置镜像重建环境**，别硬装——`setup_comfyui.sh` 依赖系统已装好的 `torch 2.9.0+cpu / torch_npu 2.9.0.post1`。

---

## 4. Step 3 · 把安装脚本放进环境

### 方式 A（推荐）：上传文件

1. 把本地 `h3_hidevlab.sh` 拖进 WebIDE 左侧文件树的挂载目录（`/workspace/user_data`）。
2. 终端执行：

```bash
cd /workspace/user_data
chmod +x h3_hidevlab.sh
bash h3_hidevlab.sh doctor
```

### 方式 B：不上传文件，纯命令行（功能等价，少了单卡/复用/管理等自动化）

```bash
# 0) 定义变量（挂载目录按实际改）
export P=/workspace/user_data
export ASCEND_HOME_PATH="$(dirname "$(find /usr/local/Ascend /opt /home -maxdepth 5 -name set_env.sh 2>/dev/null | head -n1)")"

# 1) 补依赖（openEuler；Ubuntu 把 dnf 换 apt-get）
sudo dnf install -y git curl jq patch || true
python3 -m pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple uv
export PATH="$HOME/.local/bin:$PATH"

# 2) 拉代码 + 53GB 权重（约 30-50 分钟，断点续传）
curl -fsSL "https://atomgit.com/api/v5/repos/xujiashuai/minimax-h3-int8/raw/bootstrap.sh?ref=main" \
  | INSTALL_DIR="$P" CHUNK_N=16 bash

# 3) 建 venv + 打 NPU 补丁 + 软链权重
cd "$P/minimax-h3-int8"
bash scripts/setup_comfyui.sh

# 4) 启动（1 NPU 时加上 export ASCEND_RT_VISIBLE_DEVICES=0）
export COMFY_PORT=8188
export COMFY_OUTPUT_DIR="$P/h3-output"
bash scripts/start-comfyui-dual-npu.sh start
curl -s http://127.0.0.1:8188/system_stats
```

> 方式 B 里 `export ASCEND_HOME_PATH` 那一步**不能省**：上游 `start-comfyui-dual-npu.sh` 默认硬编码 `/usr/local/Ascend/cann-8.5.1`，HiDevLab 镜像的 CANN 路径/版本多半不同。

---

## 5. Step 4 · 环境预检（必跑）

```bash
bash h3_hidevlab.sh doctor
```

它会打印并校验：

- 架构、可见 NPU 数、`npu-smi` 芯片信息
- 自动定位到的 CANN `set_env.sh` 路径
- 带 `torch_npu` 的 Python 解释器与 torch / torch_npu 版本
- 挂载目录可用空间（**< 60GB 直接报错**，53G 权重 + venv）
- `/shared_assets` 是否存在
- Python 是否 3.11

看到 `预检通过` 再往下。任何一项 `ERROR` 都先按提示修，别硬跑 `install`。

---

## 6. Step 5 · 一键安装

```bash
bash h3_hidevlab.sh install
```

脚本依次做 6 件事：

| 阶段 | 动作 |
|---|---|
| 0 | 预检 + 补齐 `jq` / `uv`（无 root 时自动生成 jq 兼容层） |
| 1 | `curl` 上游 `bootstrap.sh`，以 `INSTALL_DIR=<挂载目录> SKIP_WEIGHTS=1` 拉代码 + ComfyUI submodule |
| 2 | 扫描 `/shared_assets`，命中同名且大小一致的权重就软链复用（下载脚本会用 SHA-256 复核，不合格自动重下） |
| 3 | `download_weights_curl.sh` 下载 5 个 INT8 权重（53GB，GitCode CDN 分片并行，断点续传） |
| 4 | `setup_comfyui.sh`：uv venv（`--system-site-packages` 复用系统 torch_npu）→ 装依赖 → 打 3 个 NPU 补丁 → 软链权重 |
| 5 | 写 `h3-env.sh`（记录 CANN 路径、NPU 数、工作流、端口） |
| 6 | 建输出目录，打印下一步 |

### 5 个权重（合计 53GB）

| 文件 | 大小 | 设备 |
|---|---|---|
| `minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 21.0 GB | npu:0，扩散主干 |
| `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` | 27.1 GB | npu:1，文本编码器 |
| `minimax_h3_video_vae_fp16.safetensors` | 5.2 GB | npu:0 |
| `minimax_h3_audio_vae_fp32.safetensors` | 605 MB | npu:0 |
| `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` | 1.9 GB | Turbo 8 步 LoRA |

> **中断了怎么办**：直接重跑 `bash h3_hidevlab.sh install`。全流程幂等——代码 `git pull`、权重按大小+SHA-256 跳过已完整文件、补丁有 dry-run 跳过逻辑。

---

## 7. Step 6 · 启动服务 + 端口转发

```bash
bash h3_hidevlab.sh start
bash h3_hidevlab.sh status
```

`start` 会：
- 导出 `ASCEND_HOME_PATH`（自动探测值）与 `COMFY_OUTPUT_DIR`
- **≥2 NPU**：不限制可见设备，用 `api_t2v_int8_turbo.json`
- **1 NPU**：设 `ASCEND_RT_VISIBLE_DEVICES=0`，用 `api_t2v_int8_single.json`（文本编码器走 CPU）
- 启动 ComfyUI `0.0.0.0:8188 --preview-method none --cache-ram 2 6`，轮询 `/system_stats` 直到就绪

`status` 正常应看到 `"type": "npu"`。

### 打开 Web UI

WebIDE 底部 **「端口 / PORTS」** 面板 → 「转发端口」填 `8188` → 点生成的 `localhost:8188` 链接，浏览器里就是 ComfyUI。HiDevLab 的 WebIDE 自带端口映射，**不需要上游那套 FRP + Nginx**。

---

## 8. Step 7 · 出片

### 最常用：一条命令带自己的提示词

```bash
bash h3_hidevlab.sh gen "A chef lifts a bowl of beef noodles, steam rising, slow push in, warm kitchen light, 24fps"
```

脚本会读 API 工作流 → 替换第一个 `text` 节点 → POST `/prompt` → 轮询 `/history` → 打印产物文件名。超时 15 分钟。

### 验收测试（不改提示词）

```bash
bash h3_hidevlab.sh test
```

### 在 Web UI 里手动跑（注意）

上游仓库的 `workflows/api_*.json` 是 **API 格式**（节点字典），**不能直接拖进 ComfyUI 画布**。要在 UI 里操作，请用 ComfyUI 官方 H3 工作流模板，或把 API JSON 用「工作流 → 导出(API)」的反向流程处理。日常出片直接用 `gen` 最省事。

### 输出位置

```
<挂载目录>/h3-output/       # H.264 视频轨 + AAC 原生音轨的 MP4
```

H3 是**音画联合生成**，音频不是后期叠的。

---

## 9. Step 8 · 验收清单

| 检查项 | 期望 |
|---|---|
| `bash h3_hidevlab.sh status` | `running pid=... port=8188` + HTTP 200 |
| `/system_stats` | 含 `"type": "npu"`、`comfyui_version` |
| 权重软链 | `third_party/ComfyUI/models/{diffusion_models,text_encoders,vae,loras}/` 下各有 `.safetensors` |
| `bash h3_hidevlab.sh test` | 打印「完成 ✓」与产物文件名 |
| MP4 | 用 `ffprobe` 应看到 1 路 video + 1 路 audio |
| 耗时 | 双卡 Turbo 8 步 ≈ 76s；单卡 CPU 编码 ≈ 548s |
| 输出参数 | 736×416 / 124 帧 / 24fps（上游默认 0.3MP 档） |

---

## 10. Step 9 · 省卡时、关机与恢复

```bash
bash h3_hidevlab.sh stop     # 停服务
# 回控制台点【关机】——卡时立刻停扣
```

- **不用就关机**：2 NPU 每小时 2 卡时，挂着聊天两小时就是 4 卡时。
- **1 小时无操作会自动关机**，下载/出片时别长时间离开。
- **连续运行 >8 小时可能被回收**；停机超 2 周环境会被删除，重要视频及时下载到本地。
- 关机/开机后：挂载目录数据还在，直接

```bash
cd /workspace/user_data
bash h3_hidevlab.sh resume    # install(幂等) + start
```

- 若环境真被重建（非挂载目录被清空），重跑 `install` 即可，权重在挂载目录里不会重下。

---

## 11. 故障排查

| 现象 | 根因 | 处理 |
|---|---|---|
| `找不到 CANN 的 set_env.sh` | CANN 装在 conda 或非标准路径 | `export ASCEND_HOME_PATH=$(dirname $(find / -name set_env.sh 2>/dev/null \| head -1))` 后重跑 |
| `系统 Python 里没有 torch_npu` | 选了纯基础镜像 | 换 PyTorch/CANN 业务镜像重建；或先 `source $ASCEND_HOME_PATH/set_env.sh` |
| `Python 不是 3.11` / `找不到 ...python3.11/site-packages/comfy_kitchen` | 上游补丁硬编码 3.11 | 选 `openeuler24.03-python3.11-base` 镜像重建 |
| 空间不足 60GB | 装到了非挂载目录（上限 30GB） | 设 `PERSIST_DIR=/workspace/user_data` 后重跑，删掉错误目录里的 `models/` |
| `需要 jq` | openEuler 默认没装 | 脚本自动 `dnf install` 或生成兼容层；也可手动 `sudo dnf install -y jq` |
| `uv: command not found` | 容器没预装 | `python3 -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple uv`，确保 `~/.local/bin` 在 PATH |
| `Float8_e4m3fn` 不兼容 | 用了 NVFP4/AWQ 文本编码器上 NPU | 本方案用 **INT8 ConvRot** 文本编码器，天然避开；单卡时走 CPU |
| `SaveVideo.execute() missing codec` | 只传了 `format` | API 工作流里 `SaveVideo` 必须同时给 `format` 和 `codec` |
| 首次任务特别慢 | 首次加载 53GB 权重建热缓存 | 属一次性成本，之后热启动明显变快 |
| OOM 后重跑仍失败 | 进程 allocator 残留 | `stop` 后 `start`，不要直接重复提交 |
| 模型下载卡住 | GitCode CDN 波动 | 中断后重跑 `install`，自动断点续传；或改 `CHUNK_N=32` |
| 补丁 dry-run 失败 | 上游 ComfyUI 版本变化 | 看 `setup_comfyui.sh` 输出，人工核对 `comfy/model_management.py` 与 `nodes.py` |

日志：`bash h3_hidevlab.sh logs`（跟踪 `third_party/ComfyUI/logs/comfyui.log`）。

---

## 12. 关键约束（别越界）

- **版本组合**：上游只在 `CANN 8.5.1 / Python 3.11.14 / torch 2.9.0+cpu / torch_npu 2.9.0.post1 / ComfyUI 0.33.1 / comfy-kitchen 0.2.33` 上验证。HiDevLab 若给 CANN 9.x，补丁可能需要人工核对——`doctor` 会把实际版本打出来供判断。
- **架构**：NPU 实例是 aarch64，别拿 x86 的 wheel 硬装。
- **INT8 是必须的**：NVFP4/AWQ 量化含 `Float8_e4m3fn`，A910 的 torch_npu 不支持。
- **ComfyUI 默认无认证**，`--listen 0.0.0.0` 只在可信内网/端口转发下用，别对公网裸奔。
- 模型遵循 MiniMax H3 社区许可，商用需按其条款标注。

---

## 13. 参考来源

| 内容 | 地址 |
|---|---|
| 上游一键仓库（本教程基础） | https://ai.gitcode.com/xujiashuai/minimax-h3-int8 |
| 上游环境变量文档 | `docs/environment-variables.md`（仓库内） |
| 官方权重仓库 | https://huggingface.co/Comfy-Org/MiniMax-H3 |
| 国内镜像 | https://www.modelscope.cn/models/Comfy-Org/MiniMax-H3 |
| ComfyUI H3 官方文档 | https://docs.comfy.org/tutorials/video/minimax/minimax-h3 |
| HiDevLab 在线开发规则 | https://hidevlab.huawei.com/online-develop-intro |
| HiDevLab 平台介绍 | https://gitcode.com/HiDevLab |
| 备选：截图里的 A910 部署仓库 | https://gitcode.com/weixin_44093752/comfyui-minimax-h3-ascend |
| 备选：官方 4 卡 A3 方案 | https://gitcode.com/Ascend-SACT/MiniMax-H3-Comfy-NPU |
