# HiDevLab × MiniMax H3 视频生成部署

在华为 HiDevLab 昇腾云算力（A2 / 2 × NPU，免费 100 卡时）上，从零部署 MiniMax H3 视频生成模型的 ComfyUI 推理环境，输出带音轨的 MP4。

## 交付内容

| 文件 | 说明 |
|---|---|
| `HiDevLab-H3-从零部署教程.md` | 从开通算力资格到出片的完整教程：平台规则、镜像与规格选择、环境预检、安装、启动与端口转发、出片、验收、省卡时与容器恢复、故障排查 |
| `h3_hidevlab.sh` | 一键安装脚本，提供 `doctor / install / start / stop / status / logs / test / gen / resume` 子命令；幂等，支持 53 GB 权重断点续传与容器刷新后恢复 |

## 技术栈

- **硬件**：Ascend A2（910B）/ A3，2 × NPU，≥ 64 GiB HBM 每卡；抢不到双卡时自动切单卡工作流
- **软件**：CANN 8.5.1、Python 3.11、torch 2.9.0+cpu、torch_npu 2.9.0.post1、ComfyUI 0.33.1
- **模型**：MiniMax-H3 INT8 量化权重（约 53 GB），Turbo 8 步采样，双卡约 76 秒出片

## 快速开始

在 HiDevLab WebIDE 终端里：

```bash
cd /workspace/user_data          # HiDevLab 挂载目录，按环境实际值调整
bash h3_hidevlab.sh doctor       # 必跑：检查 CANN / NPU / torch_npu / 磁盘
bash h3_hidevlab.sh install      # 代码 + 权重 + venv + NPU 补丁，约 40-60 分钟
bash h3_hidevlab.sh start        # 启动 ComfyUI，WebIDE 端口面板转发 8188
bash h3_hidevlab.sh gen "A chef lifts a bowl of beef noodles, steam rising, slow push in"
```

完整步骤与参数说明见 `HiDevLab-H3-从零部署教程.md`。

## 关键约束

- **权重与全部持久数据必须放挂载目录**：HiDevLab 非挂载目录上限 30 GB，放不下 53 GB 权重；上游脚本默认写 `/data`，本项目已强制改到挂载目录。
- **文本编码器与扩散模型分卡**：双卡时扩散 + VAE 在 npu:0、文本编码器在 npu:1；单卡时文本编码器回退 CPU。
- **不使用 950 系列**：950PR/950DT 为 arch35 / CANN 9.x，与本项目基于 arch22 / CANN 8.5.1 的 NPU 补丁不兼容。
- **连续运行超 8 小时可能被回收**：装完及时 `stop` + 关机；权重在挂载目录不会丢，容器刷新后 `resume` 恢复。
- 本仓库**不含模型权重、token、密钥与内网地址**。

## 上游与致谢

- 部署基座：[xujiashuai/minimax-h3-int8](https://ai.gitcode.com/xujiashuai/minimax-h3-int8) —— INT8 权重、双卡工作流、Turbo 8 步
- 参考实现：[weixin_44093752/comfyui-minimax-h3-ascend](https://gitcode.com/weixin_44093752/comfyui-minimax-h3-ascend)、[Ascend-SACT/MiniMax-H3-Comfy-NPU](https://gitcode.com/Ascend-SACT/MiniMax-H3-Comfy-NPU)
- 平台规则：[HiDevLab 在线开发](https://hidevlab.huawei.com/online-develop-intro)

模型权重、CANN、torch_npu、ComfyUI 及上游仓库均遵循各自原有许可；本仓库仅提供部署脚本与文档。
