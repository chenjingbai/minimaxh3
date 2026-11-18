# W7900D + MiniMax H3 部署工具包

在 AMD Radeon PRO W7900D（gfx1100 / RDNA3，48 GB）上跑 MiniMax H3 生成音视频，附带一个挂在 ComfyUI 里的 Web 工作台。

> 所有参数、字节数、sha256 都来自实机实测。
> 踩过的坑记在 [H3-踩坑记录.md](H3-踩坑记录.md)，装之前建议先扫一眼。

环境实测：ComfyUI **0.45.0** · comfy-kitchen **0.2.41** · torch **2.9.1+rocm7.2** 与 **2.12.0+rocm7.14** 均可
本机：W7900D 48 GB · EPYC 9334 32C · 内存 cgroup **55 GiB**（`free` 看到的 503 G 是宿主机）· swap 0

---

## 快速开始

```bash
git clone https://github.com/chenjingbai/minih3.git /workspace/h3-deploy
cd /workspace/h3-deploy
chmod +x *.sh

# 一键部署（自动判断磁盘，25G 盘会走分流模式）
nohup bash deploy-h3-lite.sh > /workspace/deploy.log 2>&1 &
tail -f /workspace/deploy.log
```

部署完成后：

```bash
/workspace/tunnel.sh start     # 开隧道
# 浏览器打开 https://<域名>/dsh
```

脚本会自动处理工作台路径：从仓库目录找到 `dsh_console_h3/`，链到 `/workspace/dsh_console_h3`，再挂进 ComfyUI 的 `custom_nodes`。**不需要手动建目录或软链。**

部署流程共 9 步：环境体检 → ComfyUI → 依赖 → int8 验证 → 下载模型 → 建软链 → 节点包 → 工作台 → 隧道 → 启动自检。任何一步失败都会明确报出原因。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `deploy-h3-lite.sh` | **一键部署**（35 GB 精简版，只保留 HyperFlow 6 步链路） |
| `deploy-h3.sh` | 完整版部署（63 GB，含原生 H3 8 步引擎） |
| `h3ctl.sh` | 日常运维：start / stop / restart / tunnel / status / setup / doctor |
| `slim-models.sh` | 删掉不用的模型 + 迁移到持久盘 |
| `setup-h3-extra.sh` | 补装 HyperFlow / int8 VAE |
| `check-secrets.sh` | 推 GitHub 前扫敏感信息 |
| `dsh_console_h3/` | Web 工作台（挂 `/dsh` 路由） |

---

## 两套生成链路

### HyperFlow Flash（推荐，快）

Video Rebirth 的独立压缩模型 **13.7B**（原版 33B 的一半不到），6 步出片。

| 项 | 值 |
|---|---|
| 去噪器 | `minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot` · 16.00 GB |
| 编码器 | `qwen3vl_32b_minimax_h3_nvfp4_awq` · 15.69 GB |
| 视频 VAE | `minimax_h3_video_vae_int8_convrot` · 2.81 GB |
| 音频 VAE | `minimax_h3_audio_vae_fp32` · 0.61 GB |
| 合计 | **35.1 GB** |

参数铁律：`length` 用 **17n+5**（124 / 141 / 362）、宽高是 **32 的倍数**、`KSamplerSelect`=**euler**、CFG=**1.0**、步数在 `HyperFlowSigmas` 节点里选 4/6/8。

官方实测（RTX 4090，1344×768，124 帧，6 步）：t2v 152 s、i2v 166 s。

### 原生 H3（完整版才有）

33B + 8 步 turbo LoRA。比 HyperFlow 慢一倍，但模型更全。

额外的 21 GB：`minimax_h3_fl2va_pruned_int8_convrot` + `minimax_h3_fl2v_turbo_8step` LoRA。

---

## 关键配置

**启动参数**

```bash
/opt/venv/bin/python -u main.py \
  --disable-pinned-memory --disable-async-offload --disable-dynamic-vram \
  --reserve-vram 2
```

| 参数 | 原因 |
|---|---|
| `--disable-pinned-memory` | H3 的 I2V 有 `VmPeak=66.9 GB` 记录，pinned memory 会把 55 GiB 撑爆并卡在 0% GPU |
| `--disable-async-offload` / `--disable-dynamic-vram` | 两次 gfx1100 成功记录都关了；也规避「软链模型 + 动态显存导致每次重载」的已知 issue（Comfy-Org/ComfyUI#14276） |
| `--reserve-vram 2` | 给 VAE 解码留余量，避免「部分驱逐」把权重搞成 NaN（表现为黑帧） |
| `-u` | 不缓冲，print 立刻进日志 |

**不要加 `--cache-none`** —— ComfyUI 官方说明里明确：加上它每次运行后都会释放所有模型，下次运行重新加载。实测 34 GB 模型每次重载约 **73 秒**固定开销（占 5 秒短片总耗时的 59%）。去掉后由 ComfyUI 自己按显存/内存状况决定是否保留。

**不要加** `PYTORCH_ALLOC_CONF=expandable_segments:True` —— 这套 ROCm 栈上会静默损坏显存（输出发白 / 音频 NaN / 同 seed 不重现）。

---

## 提示词规范

H3 在一个提示词里承载镜头、运镜、对白、音效。

```
<整体场景：环境/光线/氛围>

[Shot 1] <镜头内容>
[Shot 2] At 03.500, the camera cuts to <...>

<动作> (S1) says <d>[Chinese] 台词原文</d>

overall_soundscape: <环境声 1–4 句>
non_diegetic_music: <配乐 1–3 句 或 N/A>
```

**七条硬规则**

1. `overall_soundscape` 不能空 —— 只有完全静音才写 `N/A`。**没声音通常就是这里没写。**
2. 台词写进对应 `[Shot N]` 内，别堆在末尾，否则模型会在第 0 帧就开口。
3. 时间点写单点递增（`At 03.500`），不写区间。
4. 台词放 `<d>…</d>`，说话人 ID 用 `(S1)`。
5. **不写负面内容** —— CFG=1 没有负向分支，写「不要 XX」反而会引入。
6. 想全程没人说话，要把 `overall_soundscape` 明写 `No human voice, no speaking`，光留空不够。
7. 主体用英文，台词可中文。中文描述动作有时会被当台词念出来。

工作台已内置结构化编辑器，六字段自动拼成上述格式。

---

## 存储策略

| 模式 | 触发条件 | 分配 |
|---|---|---|
| 全量 | `/workspace` ≥ 42 GB | 35 GB 全在 `/workspace/h3-models` |
| 分流 | `/workspace` < 42 GB（如 25 GB） | 19.5 GB 核心在 `/workspace`，15.7 GB 编码器在 `/opt/h3-extra` |

`/opt` 是 overlay，**实例销毁即重置**。分流模式下编码器会丢，需重下约 10 分钟。

**目录约定**

```
/workspace/h3-models/          模型（持久）
/workspace/dsh_console_h3/     工作台代码（持久）
/workspace/comfy-output/       ComfyUI 出片（持久）
/workspace/comfy-input/        上传的首帧（持久）
/workspace/comfy.log           日志
/opt/ComfyUI/                  ComfyUI 本体（overlay）
/opt/venv/                     Python 环境（overlay）
```

---

## 实测数据

| 配置 | 参数 | 结果 |
|---|---|---|
| HyperFlow int8 | 544×960 / 124 帧 / 6 步 | 采样 13:57（139 s/it 稳态） |
| 参考：7900 XT / gfx1100 | 864×480 / 124 帧 / 8 步 | 16 s/it |
| 参考：RTX 4090 | 1344×768 / 124 帧 / 6 步 | 166 s |

**已知性能问题**：本机 139 s/it 比同卡参考慢约 3 倍。已排除内存压力（`file_mapped` 仅 0.2 GB、`anon` 1.6 GB，纯页缓存）。待查 int8 kernel 实际路径与注意力后端选择。

---

## 环境要求

- ComfyUI **0.45.0**（≥0.43 才原生支持 H3）
- comfy-kitchen（提供 int8 算子）
- torch + ROCm
- 显存 **48 GB**、内存 **55 GiB**（cgroup 限制）

**验证 int8 可用（三个都要 OK）**：

```bash
/opt/venv/bin/python -c "
import comfy_kitchen as ck
caps = set((ck.list_backends().get('hip') or {}).get('capabilities') or [])
for k in ['int8_linear','convrot_w4a4_linear','w4a8_int8_linear']:
    print(('OK  ' if k in caps else 'MISSING '), k)
"
```

---

## 常见问题

| 症状 | 处理 |
|---|---|
| 出黑帧 | 加 `--disable-smart-memory` |
| 视频没声音 | 检查 `overall_soundscape` 是否为空；确认音轨存在 `python -c "import av;..."` |
| 视频播 2 秒循环 | 服务端 Range 头丢失；前端轮询重建了 `<video>` |
| 进程在但端口不通 | 等 30–60 秒；服务重启后 frpc 健康检查有延迟 |
| 内存显示 100% | 看 `anon` 和 `file_mapped`，小就无害（页缓存） |
| 慢 | 查 nvfp4 模拟路径 / 注意力后端 |

更多见 [H3-踩坑记录.md](H3-踩坑记录.md)。

---

## 许可

脚本与文档 MIT。模型权重遵循各自许可（MiniMax H3 Community License），请自行确认适用范围。
