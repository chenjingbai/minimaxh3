#!/usr/bin/env bash
# ============================================================================
# deploy-h3.sh —— 新机器一键部署 MiniMax H3 全链路
#
# 用法：bash deploy-h3.sh
#
# 会做：
#   1. 环境体检（torch / ROCm / gfx / 内存 / 磁盘）
#   2. 装 ComfyUI 到 /opt/ComfyUI
#   3. 装 comfy-kitchen 并验证 int8 能力 ★关键
#   4. 下载 63 GB 模型到 /opt/h3-models（overlay 盘，装得下）
#   5. 建软链
#   6. 装节点包（HyperFlow / GGUF / TaoMate）
#   7. 启动 + 自检
#
# 工作台 dsh_console_h3 需单独上传，脚本会建好占位目录。
# ============================================================================
set -uo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
LOG=/opt/comfy.log
MS=""

# 模型必须放持久盘。/opt 是 overlay，实例销毁即重置。
# 优先 /workspace（持久）；若它太小或不存在，才退回 /opt 并明确警告。
pick_models_dir() {
  local cand=/workspace/h3-models
  if [ -d /workspace ]; then
    local free
    free=$(df -BG --output=avail /workspace 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$free" ] && [ "$free" -ge 80 ]; then
      echo "$cand"; return 0
    fi
    printf '\033[33m%s\033[0m\n' "  ⚠ /workspace 仅 ${free:-0}G，装不下 63G 模型"
  fi
  printf '\033[31m%s\033[0m\n' "  ⚠ 退回 /opt/h3-models —— overlay 不持久，实例销毁即丢失！"
  echo "/opt/h3-models"
}

MODELS="$(pick_models_dir)"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }
step(){ echo; c_b "==== $* ===="; }

# ---------------------------------------------------------------- 0 体检
step "0/8 环境体检"
echo "  主机名  : $(hostname)"
echo "  GPU     :"
"$PY" - <<'EOF' 2>/dev/null || echo "    torch 不可用"
import torch
p = torch.cuda.get_device_properties(0)
print("    name  :", torch.cuda.get_device_name(0))
print("    VRAM  :", p.total_memory // 1024 // 1024, "MB")
print("    arch  :", getattr(p, "gcnArchName", "?"))
print("    torch :", torch.__version__)
print("    hip   :", torch.version.hip)
EOF
echo "  内存上限: $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
echo "  磁盘    :"
df -h /opt /tmp | sed 's/^/    /'

TORCH_VER=$("$PY" -c "import torch;print(torch.__version__)" 2>/dev/null || echo "none")
c_y "  torch = $TORCH_VER（昨天能跑的是 2.12.0+rocm7.14.1，若明显更低需警惕）"

# ---------------------------------------------------------------- 1 ComfyUI
step "1/8 安装 ComfyUI"
if [ -f "$COMFY/main.py" ]; then
  c_g "  已存在，跳过"
else
  cd /opt || exit 1
  for i in 1 2 3; do
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY" && break
    c_y "  第 $i 次失败，重试..."; rm -rf "$COMFY"; sleep 5
  done
  [ -f "$COMFY/main.py" ] || { c_r "  ComfyUI 拉取失败"; exit 1; }
  c_g "  已克隆"
fi

# ---------------------------------------------------------------- 2 依赖
step "2/8 安装 Python 依赖"
cd "$COMFY" || exit 1

if [ ! -x "$PY" ]; then
  c_r "  找不到 $PY，用系统 python3"
  PY=python3
fi

# 绝不装 torch：用现有的 ROCm 版
c_y "  装基础依赖（不碰 torch）"
"$PY" -m pip install -q --no-deps -r requirements.txt 2>/dev/null || \
  c_y "  部分依赖失败，继续"

# comfy-kitchen 是 H3 int8 的核心
c_y "  装 comfy-kitchen"
"$PY" -m pip install -q comfy-kitchen 2>&1 | tail -3
"$PY" -c "import comfy_kitchen as k;print('  comfy-kitchen', getattr(k,'__version__','?'))" 2>/dev/null || \
  c_r "  comfy-kitchen 安装失败"

c_y "  装模型下载/工具依赖"
"$PY" -m pip install -q modelscope gguf pillow numpy av 2>&1 | tail -2
MS="$("$PY" -c "import shutil;print(shutil.which('modelscope') or '')")"
[ -z "$MS" ] && MS="$("$PY" -c "import sys,os;print(os.path.join(os.path.dirname(sys.executable),'modelscope'))")"

# ---------------------------------------------------------------- 3 int8 验证
step "3/8 验证 int8 能力 ★"
"$PY" - <<'EOF'
try:
    import comfy_kitchen as ck
    caps = set()
    for name in dir(ck):
        pass
    # 尝试直接从后端清单读
    import json
    found = False
    for attr in ("BACKENDS", "backend_info", "list_backends"):
        if hasattr(ck, attr):
            print("   后端清单:", attr)
            found = True
    if not found:
        print("   comfy-kitchen 已装，能力需启动后看日志确认")
    print("   → 启动后必须确认 hip 后端含 int8_linear / convrot_w4a4_linear")
except Exception as e:
    print("   comfy-kitchen 导入失败:", e)
EOF
c_y "  这项不能只靠脚本判定，第 8 步启动日志里会打出来"

# ---------------------------------------------------------------- 4 模型
step "4/8 下载模型（约 63 GB）"
mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras,upscale_models}

NEED=$((63))
FREE=$(df -BG --output=avail /opt | tail -1 | tr -dc '0-9')
echo "  /opt 剩余 ${FREE}G，需要 ${NEED}G"
[ "$FREE" -lt 70 ] && { c_r "  空间不足"; exit 1; }

dl () { # $1=repo $2=local_dir $3..=includes
  local repo="$1"; shift; local dir="$1"; shift
  if [ ! -x "$MS" ]; then
    c_r "  modelscope 不可用，跳过 $repo"; return 1
  fi
  "$MS" download --model "$repo" --local_dir "$dir" --include "$@" 2>&1 | tail -3
}

cd "$MODELS" || exit 1

c_y "  [1/6] H3 去噪器 20.97 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors'

c_y "  [2/6] 文本编码器 15.69 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'

c_y "  [3/6] 视频 VAE fp16 5.21 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'vae/minimax_h3_video_vae_fp16.safetensors'

c_y "  [4/6] 视频 VAE int8 2.81 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'vae/minimax_h3_video_vae_int8_convrot.safetensors'

c_y "  [5/6] 音频 VAE 0.61 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'vae/minimax_h3_audio_vae_fp32.safetensors'

c_y "  [6/6] 8 步 turbo LoRA 1.96 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'

c_y "  [附] HyperFlow Flash int8 16.0 GB"
mkdir -p "$MODELS/hyperflow"
dl VideoRebirthAI/hyperflow-h3-flash "$MODELS/hyperflow" \
  'fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors'

c_y "  [附] 超分模型 67 MB"
"$PY" -m pip install -q modelscope >/dev/null 2>&1
"$PY" - <<'EOF' 2>&1 | tail -2
try:
    from modelscope import snapshot_download
    snapshot_download('XiangZL0/4x-UltraSharp',
                      local_dir='/opt/h3-models/upscale_models',
                      allow_file_pattern=['4x-UltraSharp.pth'])
    print("  超分模型 OK")
except Exception as e:
    print("  超分模型失败:", e)
EOF

# ---------------------------------------------------------------- 5 软链
step "5/8 建模型软链"
cd "$MODELS" || exit 1
n=0
for f in "$MODELS"/*/*.safetensors "$MODELS"/*/*.pth; do
  [ -f "$f" ] || continue
  sub=$(basename "$(dirname "$f")")
  [ "$sub" = "fl2va_int8_convrot_comfyui" ] && sub=diffusion_models
  mkdir -p "$COMFY/models/$sub"
  ln -sf "$f" "$COMFY/models/$sub/"
  n=$((n+1))
done
c_g "  已链 $n 个文件"
ls -lL "$COMFY/models"/*/ 2>/dev/null | grep -E 'minimax|UltraSharp' | awk '{print "    ", $NF}' | head -20

# ---------------------------------------------------------------- 6 节点包
step "6/8 安装节点包"
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes" || exit 1
for repo in \
  "city96/ComfyUI-GGUF" \
  "Video-Rebirth/ComfyUI-HyperFlow-Flash" \
  "xm6018924/BSAI-ComfyUI-TaoMate"
do
  name=$(basename "$repo")
  if [ -d "$name" ]; then echo "  $name 已存在"; continue; fi
  ok=0
  for i in 1 2 3; do
    git clone --depth 1 "https://github.com/$repo" "$name" >/dev/null 2>&1 && { ok=1; break; }
    rm -rf "$name"; sleep 4
  done
  [ "$ok" = "1" ] && c_g "  $name OK" || c_r "  $name 失败（稍后手动重试）"
done

# ---------------------------------------------------------------- 7 工作台
step "7/8 工作台占位"
mkdir -p /workspace/dsh_console_h3 2>/dev/null || true
if [ -d /workspace/dsh_console_h3 ]; then
  ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
  if [ -f /workspace/dsh_console_h3/__init__.py ]; then
    c_g "  工作台就位"
  else
    c_y "  ★ 需要上传 dsh_console_h3/__init__.py 和 ui.html 到 /workspace/dsh_console_h3/"
  fi
fi

# ---------------------------------------------------------------- 8 启动
step "8/8 启动并自检"
pkill -f 'venv/bin/python.*main\.py' 2>/dev/null; sleep 2
cd "$COMFY" || exit 1
nohup "$PY" -u main.py \
  --disable-pinned-memory --disable-async-offload --disable-dynamic-vram \
  --reserve-vram 2 --cache-none >> "$LOG" 2>&1 &
echo $! > /opt/comfy.pid

c_y "  等待服务就绪..."
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8188/system_stats 2>/dev/null)
  [ "$code" = "200" ] && { c_g "  就绪（${i}s）"; break; }
  sleep 1
done

echo
c_b "──── int8 能力确认（关键）────"
grep -m2 "comfy_kitchen backend hip" "$LOG" | head -2 | while read -r l; do
  if echo "$l" | grep -q 'int8_linear'; then
    c_g "  hip 后端有 int8_linear ✅"
  else
    c_r "  hip 后端缺 int8_linear ✗ —— int8 去噪器会慢很多或报错"
  fi
  if echo "$l" | grep -q 'convrot_w4a4_linear'; then
    c_g "  hip 后端有 convrot_w4a4_linear ✅"
  else
    c_r "  hip 后端缺 convrot_w4a4_linear ✗"
  fi
done

echo
c_b "──── 节点注册 ────"
curl -s http://127.0.0.1:8188/object_info 2>/dev/null | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('  H3      :', 'MiniMaxH3ImageToVideo' in d)
    print('  HyperFlow:', 'HyperFlowLoader' in d)
    print('  TaoMate :', 'BSAITaoMateLoRALoader' in d)
    print('  超分     :', 'ImageUpscaleWithModel' in d)
    print('  工作台   :', any('dsh' in k.lower() for k in d) or '见 /dsh 页面')
except Exception as e:
    print('  读取失败', e)
"

echo
c_b "──── 环境摘要 ────"
echo "  ComfyUI : $COMFY"
echo "  模型    : $MODELS （$(du -sh "$MODELS" 2>/dev/null | cut -f1)）"
echo "  日志    : $LOG"
echo "  本地    : http://127.0.0.1:8188"
echo
c_y "  下一步："
c_y "    1) 上传工作台：/workspace/dsh_console_h3/{__init__.py,ui.html}"
c_y "    2) 开隧道：rc-tunnel expose -port 8188"
c_y "    3) 浏览器：<域名>/dsh"
echo
c_g "部署脚本结束"
