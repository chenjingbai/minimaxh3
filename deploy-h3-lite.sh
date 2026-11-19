#!/usr/bin/env bash
# ============================================================================
# deploy-h3-lite.sh —— 35 GB 精简版部署（只保留 HyperFlow 6 步链路）
#
# 模型清单（35.2 GB）：
#   hyperflow_flash_14b-int8   16.00 GB   去噪器
#   qwen3vl_32b_nvfp4_awq      15.69 GB   文本编码器
#   video_vae_int8_convrot      2.81 GB   视频 VAE
#   audio_vae_fp32              0.61 GB   音频 VAE
#   4x-UltraSharp               0.07 GB   超分
#
# 存储自适应：
#   /workspace ≥ 42G  → 模型全放 /workspace/h3-models（全持久）
#   /workspace 约 25G → 分流：19.4G 核心放 /workspace，15.7G 编码器放 /opt/h3-extra
#                       （/opt 是 overlay，重建会丢，但编码器可快速重下）
#
# 用法：
#   bash deploy-h3-lite.sh            装到 /workspace
#   bash deploy-h3-lite.sh --split    强制分流模式（25G 盘用）
# ============================================================================
set -uo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
LOG=/workspace/comfy.log
EXTRA=/opt/h3-extra

FORCE_SPLIT=0
[ "${1:-}" = "--split" ] && FORCE_SPLIT=1

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 计时
DEPLOY_T0=$(date +%s)
STEP_T0=$DEPLOY_T0

# 秒数转 "1h23m45s" / "3m45s" / "45s"
fmt_dur() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s/60)) $((s%60))
  else
    printf '%ds' "$s"
  fi
}

step() {
  local now elapsed
  now=$(date +%s)
  # 非第一步时，汇报上一步耗时
  if [ "$STEP_T0" != "$DEPLOY_T0" ]; then
    elapsed=$((now-STEP_T0))
    printf '  \033[2m（上一步 %s）\033[0m\n' "$(fmt_dur "$elapsed")"
  fi
  STEP_T0=$now
  echo
  c_b "==== $* ===="
  printf '  \033[2m累计 %s\033[0m\n' "$(fmt_dur $((now-DEPLOY_T0)))"
}

# ---------------------------------------------------------------- 存储决策
step "0/9 环境与存储决策"
echo "  主机: $(hostname)"
"$PY" - <<'EOF' 2>/dev/null || echo "  torch 不可用"
import torch
p = torch.cuda.get_device_properties(0)
print("  GPU :", torch.cuda.get_device_name(0), p.total_memory//1024//1024, "MB", getattr(p,"gcnArchName","?"))
print("  torch:", torch.__version__, "| hip", torch.version.hip)
EOF
echo "  内存: $(awk '{printf "%.1f GiB", $1/1073741824}' /sys/fs/cgroup/memory.max 2>/dev/null)"
echo "  磁盘:"
df -BG /workspace /opt 2>/dev/null | sed 's/^/    /'

WS_FREE=$(df -BG --output=avail /workspace 2>/dev/null | tail -1 | tr -dc '0-9')
WS_FREE=${WS_FREE:-0}
echo

if [ "$FORCE_SPLIT" = "1" ] || [ "$WS_FREE" -lt 42 ]; then
  MODE=split
  MODELS=/workspace/h3-models          # 19.4G 核心
  MODELS_BIG="$EXTRA"                  # 15.7G 编码器
  c_y "  /workspace 仅 ${WS_FREE}G → 分流模式"
  c_y "    核心模型 → $MODELS（持久）"
  c_y "    文本编码器 → $MODELS_BIG（overlay，重建需重下）"
else
  MODE=full
  MODELS=/workspace/h3-models
  MODELS_BIG="$MODELS"
  c_g "  /workspace ${WS_FREE}G → 全量模式，模型都放 $MODELS"
fi

mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,upscale_models}
[ "$MODE" = "split" ] && mkdir -p "$MODELS_BIG"/{diffusion_models,text_encoders}

# ---------------------------------------------------------------- 1 ComfyUI
step "1/9 安装 ComfyUI"
if [ -f "$COMFY/main.py" ]; then
  c_g "  已存在"
else
  cd /opt || exit 1
  for i in 1 2 3; do
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY" && break
    c_y "  第 $i 次失败"; rm -rf "$COMFY"; sleep 5
  done
  [ -f "$COMFY/main.py" ] || { c_r "  ComfyUI 拉取失败"; exit 1; }
  c_g "  已克隆"
fi

# ---------------------------------------------------------------- 2 依赖
step "2/9 Python 依赖（保护 torch）"
cd "$COMFY" || exit 1
[ -x "$PY" ] || { c_r "  缺 $PY"; exit 1; }

TORCH_BEFORE=$("$PY" -c "import torch;print(torch.__version__)" 2>/dev/null || echo none)
c_y "  当前 torch: $TORCH_BEFORE"

# 逐个装。--no-deps 整体绕过会漏 trampoline 之类的运行时依赖，
# 所以这里显式点名，且绝不列 torch / torchvision / torchaudio。
c_y "  [1/4] requirements（含 --no-deps 保护 torch）"
"$PY" -m pip install -q --no-deps -r requirements.txt 2>/dev/null || c_y "    部分失败，继续"

c_y "  [2/4] 补 requirements 漏掉但运行时必需的"
"$PY" -m pip install -q trampoline torchsde kornia spandrel 2>&1 | tail -2

c_y "  [3/4] 前端与模板包（缺了界面打不开）"
"$PY" -m pip install -q comfyui-workflow-templates comfyui-frontend-package 2>&1 | tail -2

c_y "  [4/4] comfy-kitchen + 工具"
"$PY" -m pip install -q comfy-kitchen modelscope gguf pillow numpy av 2>&1 | tail -2

TORCH_AFTER=$("$PY" -c "import torch;print(torch.__version__)" 2>/dev/null || echo none)
if [ "$TORCH_BEFORE" != "none" ] && [ "$TORCH_BEFORE" != "$TORCH_AFTER" ]; then
  c_r "  ⚠️ torch 被改动: $TORCH_BEFORE → $TORCH_AFTER"
else
  c_g "  torch 未变: $TORCH_AFTER"
fi

MSCLI="$("$PY" -c "import shutil;print(shutil.which('modelscope') or '')")"
[ -z "$MSCLI" ] && MSCLI="$(dirname "$PY")/modelscope"

# ---------------------------------------------------------------- 3 int8 验证
step "3/9 int8 能力（★ 决定能否跑）"
"$PY" - <<'EOF'
import comfy_kitchen as ck, json
bs = ck.list_backends()
hip = bs.get("hip") or {}
caps = set(hip.get("capabilities") or [])
need = ["int8_linear", "convrot_w4a4_linear", "w4a8_int8_linear",
        "dequantize_int8_convrot_weight_dtype"]
print("  hip available:", hip.get("available"))
for k in need:
    print("   ", ("✅" if k in caps else "❌"), k)
print("  nvfp4 原生:", "✅" if "dequantize_nvfp4" in caps else "❌（走 eager 模拟，正常）")
ok = all(k in caps for k in ["int8_linear", "convrot_w4a4_linear"])
print("\n  结论:", "可跑 HyperFlow int8" if ok else "⚠️ 关键算子缺失")
EOF

# ---------------------------------------------------------------- 4 下载
step "4/9 下载模型（35.2 GB）"
dl() { # repo dir includes...
  local repo="$1"; shift; local dir="$1"; shift
  [ -x "$MSCLI" ] || { c_r "  modelscope 缺失"; return 1; }
  "$MSCLI" download --model "$repo" --local_dir "$dir" --include "$@" 2>&1 | tail -2
}

c_y "  [1/5] HyperFlow 去噪器 16.00 GB → $MODELS"
mkdir -p "$MODELS/hyperflow"
dl VideoRebirthAI/hyperflow-h3-flash "$MODELS/hyperflow" \
  'fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors'

c_y "  [2/5] 文本编码器 15.69 GB → $MODELS_BIG"
dl Comfy-Org/minimax-H3 "$MODELS_BIG" \
  'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'

c_y "  [3/5] 视频 VAE int8 2.81 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'vae/minimax_h3_video_vae_int8_convrot.safetensors'

c_y "  [4/5] 音频 VAE 0.61 GB"
dl Comfy-Org/minimax-H3 "$MODELS" \
  'vae/minimax_h3_audio_vae_fp32.safetensors'

c_y "  [5/5] 超分 4x-UltraSharp 67 MB"
"$PY" - <<'EOF' 2>&1 | tail -2
try:
    from modelscope import snapshot_download
    snapshot_download('XiangZL0/4x-UltraSharp',
                      local_dir='/tmp/ups',
                      allow_file_pattern=['4x-UltraSharp.pth'])
    import shutil, os, glob
    os.makedirs('/workspace/h3-models/upscale_models', exist_ok=True)
    for f in glob.glob('/tmp/ups/**/4x-UltraSharp.pth', recursive=True):
        shutil.copy2(f, '/workspace/h3-models/upscale_models/')
        print("  超分模型 OK")
        break
except Exception as e:
    print("  超分模型失败:", e)
EOF

# 分流模式下把编码器也算进校验
c_b "──── 下载结果 ────"
du -sh "$MODELS"/* 2>/dev/null | sed 's/^/  /'
[ "$MODE" = "split" ] && du -sh "$MODELS_BIG"/text_encoders 2>/dev/null | sed 's/^/  /'

# ---------------------------------------------------------------- 5 软链
step "5/9 建软链"
link() { # src sub
  local src="$1" sub="$2"
  [ -f "$src" ] || return 0
  mkdir -p "$COMFY/models/$sub"
  ln -sf "$src" "$COMFY/models/$sub/"
  echo "  + $sub/$(basename "$src")"
}

link "$MODELS/hyperflow/fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors" diffusion_models
link "$MODELS_BIG/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" text_encoders
link "$MODELS/vae/minimax_h3_video_vae_int8_convrot.safetensors" vae
link "$MODELS/vae/minimax_h3_audio_vae_fp32.safetensors" vae
link "$MODELS/upscale_models/4x-UltraSharp.pth" upscale_models

# ---------------------------------------------------------------- 6 节点
step "6/9 节点包"
mkdir -p "$COMFY/custom_nodes"; cd "$COMFY/custom_nodes" || exit 1
for repo in "city96/ComfyUI-GGUF" "Video-Rebirth/ComfyUI-HyperFlow-Flash"; do
  name=$(basename "$repo")
  [ -d "$name" ] && { echo "  $name 已存在"; continue; }
  ok=0
  for i in 1 2 3; do
    git clone --depth 1 "https://github.com/$repo" "$name" >/dev/null 2>&1 && { ok=1; break; }
    rm -rf "$name"; sleep 4
  done
  [ "$ok" = 1 ] && c_g "  $name OK" || c_r "  $name 失败"
done

# ---------------------------------------------------------------- 7 工作台
step "7/9 工作台"

# 工作台代码可能在三个位置，按优先级找：
#   1) 脚本同级目录的 dsh_console_h3/   ← git clone 后的默认位置
#   2) /workspace/dsh_console_h3/       ← 手动上传的位置
#   3) 已经在 /opt 装过
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_SRC=""
for cand in "$SCRIPT_DIR/dsh_console_h3" /workspace/dsh_console_h3 /workspace/h3-deploy/dsh_console_h3; do
  if [ -f "$cand/__init__.py" ] && [ -f "$cand/ui.html" ]; then
    WS_SRC="$cand"; break
  fi
done

if [ -n "$WS_SRC" ]; then
  # 若源码不在 /workspace/dsh_console_h3，就链过去（保证持久 + 模板能读到）
  if [ "$WS_SRC" != "/workspace/dsh_console_h3" ]; then
    mkdir -p /workspace
    if [ -e /workspace/dsh_console_h3 ] && [ ! -L /workspace/dsh_console_h3 ]; then
      c_y "  /workspace/dsh_console_h3 已存在（非软链），就地使用"
      WS_SRC=/workspace/dsh_console_h3
    else
      ln -sfn "$WS_SRC" /workspace/dsh_console_h3
      c_g "  链接 $WS_SRC -> /workspace/dsh_console_h3"
    fi
  fi

  rm -rf /workspace/dsh_console_h3/__pycache__ "$COMFY/custom_nodes/dsh_console_h3/__pycache__" 2>/dev/null || true
  ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
  c_g "  工作台已挂载 -> $WS_SRC"
else
  mkdir -p /workspace/dsh_console_h3
  ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
  c_y "  ★ 未找到工作台源码（__init__.py + ui.html）"
  c_y "    把仓库里的 dsh_console_h3/ 放到脚本同级，或上传到 /workspace/dsh_console_h3/"
fi

# ---------------------------------------------------------------- 8 隧道
step "8/9 安装隧道工具 rc-tunnel"
export PATH="/root/.local/bin:$PATH"

if command -v rc-tunnel >/dev/null 2>&1; then
  c_g "  已安装: $(rc-tunnel version 2>&1 | head -1)"
else
  SECRET=/var/run/secrets/frp-self-service
  if [ -f "$SECRET/install" ]; then
    c_y "  从平台 Secret 安装（需要容器内置环境变量）"
    if sh "$SECRET/install" 2>&1 | tail -5; then
      export PATH="/root/.local/bin:$PATH"
      hash -r
      command -v rc-tunnel >/dev/null 2>&1 \
        && c_g "  安装成功" \
        || c_r "  安装脚本跑完但找不到 rc-tunnel"
    else
      c_r "  安装失败（FRP_BROKER_URL 等变量只在 Notebook 终端里才有）"
    fi
  else
    c_r "  没有 $SECRET/install，需要从平台控制台获取隧道工具"
  fi
fi

# 记一条便捷脚本，语法随版本可能不同
cat > /workspace/tunnel.sh <<'TUN'
#!/usr/bin/env bash
export PATH="/root/.local/bin:$PATH"
case "${1:-start}" in
  start)
    rc-tunnel expose --port 8188 2>/dev/null || rc-tunnel expose -port 8188
    sleep 3
    rc-tunnel status
    ;;
  stop)  rc-tunnel stop ;;
  status) rc-tunnel status ;;
  *) echo "用法: ./tunnel.sh {start|stop|status}" ;;
esac
TUN
chmod +x /workspace/tunnel.sh
c_g "  已生成 /workspace/tunnel.sh"

# ---------------------------------------------------------------- 9 启动
step "9/9 启动自检"
pkill -f 'venv/bin/python.*main\.py' 2>/dev/null; sleep 2

# 统一走 /workspace/start.sh
if [ -x /workspace/start.sh ]; then
  c_y "  用 /workspace/start.sh 启动"
  nohup /workspace/start.sh >> "$LOG" 2>&1 &
else
  c_y "  未找到 /workspace/start.sh，用内置参数"
  cd "$COMFY" || exit 1
  nohup "$PY" -u main.py \
    --disable-pinned-memory --disable-async-offload --disable-dynamic-vram \
    --reserve-vram 2 >> "$LOG" 2>&1 &
fi
echo $! > /opt/comfy.pid

c_y "  等待就绪..."
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8188/system_stats 2>/dev/null)
  [ "$code" = "200" ] && { c_g "  就绪（${i}s）"; break; }
  sleep 1
done

echo
c_b "──── 节点注册 ────"
curl -s http://127.0.0.1:8188/object_info 2>/dev/null | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
for k,v in [('HyperFlowLoader','HyperFlow 去噪器'),('HyperFlowSigmas','HF 步数'),
            ('MiniMaxH3ImageToVideo','H3 图生视频'),('ImageUpscaleWithModel','超分')]:
    print('  %-24s %s' % (v, '✅' if k in d else '❌'))
" 2>/dev/null || c_r "  读取失败"

echo
c_b "──── 存储分布 ────"
echo "  模式  : $MODE"
echo "  核心  : $MODELS ($(du -sh "$MODELS" 2>/dev/null | cut -f1))"
if [ "$MODE" = "split" ]; then
  echo "  编码器: $MODELS_BIG ($(du -sh "$MODELS_BIG" 2>/dev/null | cut -f1))"
  c_y "  注意：$MODELS_BIG 在 overlay 上，实例重建后会丢，需重下 15.7 GB"
fi
df -BG /workspace /opt 2>/dev/null | sed 's/^/  /'

echo
c_b "──── 隧道 ────"
export PATH="/root/.local/bin:$PATH"

TUNNEL_URL=""
if command -v rc-tunnel >/dev/null 2>&1; then
  # 已经有 active 隧道就直接复用，不重开（重开会换域名）
  EXIST=$(rc-tunnel status 2>&1 || true)
  if echo "$EXIST" | grep -q 'status:[[:space:]]*active' || echo "$EXIST" | grep -q 'Status:[[:space:]]*active'; then
    c_g "  已有活动隧道，直接复用"
    echo "$EXIST" | grep -E 'URL:|Status:|Local port:' | sed 's/^/  /'
    TUNNEL_URL=$(echo "$EXIST" | grep -oE 'https://[^ ]+' | head -1)
  else
    # 僵尸 frpc：进程在但 broker 无隧道，必须先 stop
    if echo "$EXIST" | grep -q 'broker has no active tunnel'; then
      c_y "  清理僵尸 frpc ..."
      rc-tunnel stop >/dev/null 2>&1 || true
      sleep 2
    fi
    c_y "  开隧道 ..."
    rc-tunnel expose --port 8188 2>&1 | sed 's/^/  /' || \
      rc-tunnel expose -port 8188 2>&1 | sed 's/^/  /' || true
    sleep 3
    OUT=$(rc-tunnel status 2>&1 || true)
    echo "$OUT" | grep -E 'URL:|Status:|Local port:' | sed 's/^/  /'
    TUNNEL_URL=$(echo "$OUT" | grep -oE 'https://[^ ]+' | head -1)
  fi
else
  c_r "  rc-tunnel 未安装（见 8/9 步骤）"
fi

echo
c_b "════════ 完成 ════════"
echo
if [ -n "$TUNNEL_URL" ]; then
  c_g "  工作台 : $TUNNEL_URL/dsh"
  c_g "  ComfyUI: $TUNNEL_URL"
else
  c_y "  隧道未就绪，稍后执行： /workspace/tunnel.sh start"
fi
echo
echo "  本地   : http://127.0.0.1:8188/dsh"
echo "  日志   : tail -f $LOG"
echo "  启停   : /workspace/h3ctl.sh start|stop|restart|status"
echo "  隧道   : /workspace/tunnel.sh start|stop|url"
echo

# ---------------------------------------------------------------- 总耗时
TOTAL=$(( $(date +%s) - DEPLOY_T0 ))
echo "  ────────────────────────────"
printf '  \033[1;36m总耗时 : %s\033[0m\n' "$(fmt_dur "$TOTAL")"
echo "  ────────────────────────────"
echo
# 顺手把耗时写进日志，方便以后比对
echo "[deploy] $(date '+%F %T') 完成，总耗时 $(fmt_dur "$TOTAL")（$MODE 模式）" >> "$LOG" 2>/dev/null || true

c_g "部署完成"
