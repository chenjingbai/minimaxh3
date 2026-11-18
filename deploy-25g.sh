#!/usr/bin/env bash
# ============================================================================
# deploy-25g.sh —— 25 GB 永久盘实例专用：缺什么补什么，装完直接起服务
#
# 设计原则：25G 盘重建后 /opt 全丢、/workspace 保留。
#   → 核心模型（19.5G）在 /workspace，绝不重下
#   → 文本编码器（15.7G）放 /opt/h3-extra，重建后自动重下
#   → 每步都先检测再动手，能跳过就跳过
#
# 存储布局：
#   /workspace/h3-models/         19.4 GB  持久  ← 去噪器 + 两个 VAE + 超分
#   /opt/h3-extra/                15.7 GB  overlay ← 文本编码器
#   /opt/ComfyUI/                          overlay ← 本体 + 节点
#   /opt/venv/                             overlay ← Python 环境
#
# 用法：
#   bash deploy-25g.sh          正常执行
#   bash deploy-25g.sh --check  只体检，不动手
# ============================================================================
set -uo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
LOG=/workspace/comfy.log
CORE=/workspace/h3-models        # 持久：去噪器 + VAE + 超分
BIG=/opt/h3-extra                # overlay：文本编码器

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }
ok(){ c_g "  ✅ $*"; }
no(){ c_y "  ⬜ $*"; }
ng(){ c_r "  ❌ $*"; }

DEPLOY_T0=$(date +%s)
STEP_T0=$DEPLOY_T0
fmt_dur() {
  local s=$1; [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%ds' "$s"; fi
}
step(){
  local now; now=$(date +%s)
  [ "$STEP_T0" != "$DEPLOY_T0" ] && printf '  \033[2m（上一步 %s）\033[0m\n' "$(fmt_dur $((now-STEP_T0)))"
  STEP_T0=$now
  echo; c_b "==== $* ===="
  printf '  \033[2m累计 %s\033[0m\n' "$(fmt_dur $((now-DEPLOY_T0)))"
}

# ---------------------------------------------------------------- 0 体检
step "0/7 环境体检"

echo "  主机   : $(hostname)"
if command -v nvidia-smi >/dev/null 2>&1; then
  :
fi
"$PY" - <<'PYEOF' 2>/dev/null || echo "  torch 不可用（venv 缺失或未装）"
import torch
p = torch.cuda.get_device_properties(0)
print("  GPU    : %s  %d MB  %s" % (torch.cuda.get_device_name(0),
      p.total_memory // 1024 // 1024, getattr(p, "gcnArchName", "?")))
print("  torch  : %s | hip %s" % (torch.__version__, torch.version.hip))
PYEOF
echo "  内存   : $(awk '{printf "%.1f GiB", $1/1073741824}' /sys/fs/cgroup/memory.max 2>/dev/null)"
echo "  磁盘   :"
df -BG /workspace /opt 2>/dev/null | sed 's/^/    /'

WS_FREE=$(df -BG --output=avail /workspace 2>/dev/null | tail -1 | tr -dc '0-9')
WS_FREE=${WS_FREE:-0}
echo

# ---------------------------------------------------------------- 1 现状盘点
step "1/7 盘点已有资产"

HAVE_COMFY=0; [ -f "$COMFY/main.py" ] && HAVE_COMFY=1
HAVE_VENV=0;  [ -x "$PY" ] && HAVE_VENV=1
[ "$HAVE_COMFY" = 1 ] && ok "ComfyUI 在 $COMFY" || no "ComfyUI 缺失"
[ "$HAVE_VENV" = 1 ]  && ok "venv 在 $PY"       || no "venv 缺失"

DENOISER="$CORE/diffusion_models/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors"
VVAE="$CORE/vae/minimax_h3_video_vae_int8_convrot.safetensors"
AVAE="$CORE/vae/minimax_h3_audio_vae_fp32.safetensors"
UPSCALE="$CORE/upscale_models/4x-UltraSharp.pth"
ENCODER="$BIG/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

NEED_CORE=0
for f in "$DENOISER" "$VVAE" "$AVAE"; do
  if [ -f "$f" ]; then ok "$(basename "$f")  $(du -h "$f"|cut -f1)"
  else no "$(basename "$f") 缺失"; NEED_CORE=1; fi
done
[ -f "$UPSCALE" ] && ok "4x-UltraSharp.pth  $(du -h "$UPSCALE"|cut -f1)" || no "4x-UltraSharp.pth 缺失（可选）"
[ -f "$ENCODER" ] && ok "文本编码器  $(du -h "$ENCODER"|cut -f1)" || no "文本编码器缺失（重建后正常）"

echo
CORE_SZ=$(du -sh "$CORE" 2>/dev/null | cut -f1)
echo "  核心模型占用: ${CORE_SZ:-0}"
echo "  /workspace 可用: ${WS_FREE}G"

# 空间守卫
NEED_GB=0
[ "$NEED_CORE" = 1 ] && NEED_GB=$((NEED_GB+22))
[ ! -f "$ENCODER" ] && NEED_GB=$((NEED_GB+16))
if [ "$NEED_GB" -gt 0 ]; then
  OPT_FREE=$(df -BG --output=avail /opt | tail -1 | tr -dc '0-9')
  echo "  预计还需下载: ${NEED_GB}G（/opt 可用 ${OPT_FREE}G）"
  [ "${OPT_FREE:-0}" -lt "$NEED_GB" ] && { ng "/opt 空间不足"; exit 1; }
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo; c_y "  体检模式，未做任何修改。去掉 --check 执行部署。"
  exit 0
fi

# ---------------------------------------------------------------- 2 ComfyUI
step "2/7 ComfyUI 本体"
if [ "$HAVE_COMFY" = 1 ]; then
  ok "已存在，跳过"
else
  cd /opt || exit 1
  for i in 1 2 3; do
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY" && break
    c_y "  第 $i 次失败"; rm -rf "$COMFY"; sleep 5
  done
  [ -f "$COMFY/main.py" ] || { ng "ComfyUI 拉取失败"; exit 1; }
  ok "已克隆"
fi

# ---------------------------------------------------------------- 3 依赖
step "3/7 Python 依赖"
cd "$COMFY" || exit 1

if [ "$HAVE_VENV" != 1 ]; then
  ng "找不到 $PY"
  c_y "  新实例请先在平台模板里打开一次 ComfyUI，或手动建 venv"
  exit 1
fi

TORCH_BEFORE=$("$PY" -c "import torch;print(torch.__version__)" 2>/dev/null || echo none)

# 只装真正缺的包，避免每次全量重装
need_pkg(){
  "$PY" -c "import importlib,sys; importlib.import_module('$1')" >/dev/null 2>&1
}

PIP_LIST=""
add_pkg(){ need_pkg "$2" || PIP_LIST="$PIP_LIST $1"; }

add_pkg "trampoline"                trampoline
add_pkg "torchsde"                  torchsde
add_pkg "kornia"                    kornia
add_pkg "spandrel"                  spandrel
add_pkg "comfyui_workflow_templates" comfyui_workflow_templates
add_pkg "comfyui_frontend_package"  comfyui_frontend_package
add_pkg "comfy_kitchen"             comfy_kitchen
add_pkg "modelscope"                modelscope
add_pkg "gguf"                      gguf
add_pkg "PIL"                       pillow
add_pkg "numpy"                     numpy
add_pkg "av"                        av

if [ -n "$PIP_LIST" ]; then
  c_y "  需要补装:$PIP_LIST"
  "$PY" -m pip install -q $PIP_LIST 2>&1 | tail -3
else
  ok "全部依赖已就绪"
fi

# requirements 里的基础包（不进上面的点名列表）
if [ -f requirements.txt ]; then
  "$PY" -m pip install -q --no-deps -r requirements.txt 2>/dev/null || true
fi

TORCH_AFTER=$("$PY" -c "import torch;print(torch.__version__)" 2>/dev/null || echo none)
if [ "$TORCH_BEFORE" != "none" ] && [ "$TORCH_BEFORE" != "$TORCH_AFTER" ]; then
  ng "torch 被改动: $TORCH_BEFORE → $TORCH_AFTER（需人工确认）"
else
  ok "torch 未变: $TORCH_AFTER"
fi

# int8 能力
echo
"$PY" - <<'PYEOF'
try:
    import comfy_kitchen as ck
    caps = set((ck.list_backends().get("hip") or {}).get("capabilities") or [])
    need = ["int8_linear", "convrot_w4a4_linear", "w4a8_int8_linear"]
    miss = [k for k in need if k not in caps]
    if miss:
        print("\033[31m  ❌ hip 后端缺: %s\033[0m" % ", ".join(miss))
    else:
        print("\033[32m  ✅ hip int8 能力齐全\033[0m")
except Exception as e:
    print("\033[33m  ⚠️ comfy-kitchen 不可用: %s\033[0m" % e)
PYEOF

MSCLI="$("$PY" -c "import shutil;print(shutil.which('modelscope') or '')")"
[ -z "$MSCLI" ] && MSCLI="$(dirname "$PY")/modelscope"

# ---------------------------------------------------------------- 4 模型
step "4/7 下载缺失模型"
mkdir -p "$CORE"/{diffusion_models,vae,upscale_models} "$BIG"/text_encoders

dl(){ # repo dir include...
  local repo="$1"; shift; local dir="$1"; shift
  [ -x "$MSCLI" ] || { ng "modelscope 缺失，跳过"; return 1; }
  "$MSCLI" download --model "$repo" --local_dir "$dir" --include "$@" 2>&1 | tail -2
}

if [ ! -f "$DENOISER" ]; then
  c_y "  [1/4] HyperFlow 去噪器 16.00 GB → $CORE"
  mkdir -p "$CORE/hyperflow"
  dl VideoRebirthAI/hyperflow-h3-flash "$CORE/hyperflow" \
    'fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors'
  ln -sf "$CORE/hyperflow/fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors" \
         "$DENOISER" 2>/dev/null || true
else
  ok "去噪器已有，跳过"
fi

if [ ! -f "$ENCODER" ]; then
  c_y "  [2/4] 文本编码器 15.69 GB → $BIG（overlay）"
  dl Comfy-Org/minimax-H3 "$BIG" \
    'text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors'
else
  ok "编码器已有，跳过"
fi

if [ ! -f "$VVAE" ] || [ ! -f "$AVAE" ]; then
  c_y "  [3/4] 两个 VAE"
  dl Comfy-Org/minimax-H3 "$CORE" \
    'vae/minimax_h3_video_vae_int8_convrot.safetensors' \
    'vae/minimax_h3_audio_vae_fp32.safetensors'
else
  ok "VAE 已有，跳过"
fi

if [ ! -f "$UPSCALE" ]; then
  c_y "  [4/4] 超分模型 67 MB"
  "$PY" - <<'PYPF' 2>&1 | tail -2
import os, glob, shutil
try:
    from modelscope import snapshot_download
    tmp = '/tmp/ups25'
    snapshot_download('XiangZL0/4x-UltraSharp', local_dir=tmp,
                      allow_file_pattern=['4x-UltraSharp.pth'])
    os.makedirs('/workspace/h3-models/upscale_models', exist_ok=True)
    for f in glob.glob(tmp + '/**/4x-UltraSharp.pth', recursive=True):
        shutil.copy2(f, '/workspace/h3-models/upscale_models/')
        print("  超分模型 OK"); break
except Exception as e:
    print("  超分模型失败:", e)
PYPF
else
  ok "超分模型已有，跳过"
fi

echo
c_b "  下载结果"
du -sh "$CORE"/* 2>/dev/null | sed 's/^/    /'
du -sh "$BIG"/text_encoders 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 5 软链
step "5/7 建立软链"
link(){ [ -f "$1" ] || return 0; mkdir -p "$COMFY/models/$2"; ln -sf "$1" "$COMFY/models/$2/"; echo "  + $2/$(basename "$1")"; }

link "$DENOISER" diffusion_models
link "$ENCODER"  text_encoders
link "$VVAE"     vae
link "$AVAE"     vae
link "$UPSCALE"  upscale_models

# 清断链
find "$COMFY/models" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

# ---------------------------------------------------------------- 6 节点 + 工作台
step "6/7 节点包与工作台"
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes" || exit 1

for repo in \
  "city96/ComfyUI-GGUF" \
  "Video-Rebirth/ComfyUI-HyperFlow-Flash"
do
  name=$(basename "$repo")
  if [ -d "$name" ]; then ok "$name 已存在"; continue; fi
  okk=0
  for i in 1 2 3; do
    git clone --depth 1 "https://github.com/$repo" "$name" >/dev/null 2>&1 && { okk=1; break; }
    rm -rf "$name"; sleep 4
  done
  [ "$okk" = 1 ] && ok "$name" || ng "$name 拉取失败（可稍后重试）"
done

# 工作台：脚本同级 → /workspace/dsh_console_h3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_SRC=""
for cand in "$SCRIPT_DIR/dsh_console_h3" /workspace/dsh_console_h3 /workspace/h3-deploy/dsh_console_h3; do
  if [ -f "$cand/__init__.py" ] && [ -f "$cand/ui.html" ]; then WS_SRC="$cand"; break; fi
done
if [ -n "$WS_SRC" ]; then
  [ "$WS_SRC" != "/workspace/dsh_console_h3" ] && ln -sfn "$WS_SRC" /workspace/dsh_console_h3 2>/dev/null || true
  rm -rf /workspace/dsh_console_h3/__pycache__ "$COMFY/custom_nodes/dsh_console_h3/__pycache__" 2>/dev/null || true
  ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
  ok "工作台 → $WS_SRC"
else
  mkdir -p /workspace/dsh_console_h3
  ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
  no "未找到工作台源码，需上传 __init__.py + ui.html"
fi

# ---------------------------------------------------------------- 7 启动 + 隧道
step "7/7 启动服务与隧道"
pkill -f 'venv/bin/python.*main\.py' 2>/dev/null; sleep 2
cd "$COMFY" || exit 1
nohup "$PY" -u main.py \
  --disable-pinned-memory --disable-async-offload --disable-dynamic-vram \
  --reserve-vram 2 --cache-none >> "$LOG" 2>&1 &

c_y "  等待就绪..."
READY=0
for i in $(seq 1 150); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8188/system_stats 2>/dev/null)
  [ "$code" = "200" ] && { ok "就绪（${i}s）"; READY=1; break; }
  sleep 1
done
[ "$READY" = 0 ] && ng "150 秒未就绪，看 tail -40 $LOG"

echo
c_b "  节点注册"
curl -s http://127.0.0.1:8188/dsh/api/options 2>/dev/null | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    n=d.get('nodes') or {}
    for k,v in [('HyperFlowLoader','HyperFlow'),('H3','H3 图生视频'),('Upscale','超分')]:
        print('    %-14s %s' % (v, '✅' if n.get(k) else '❌'))
    print('    unet         %s' % (d.get('unet') or []))
    print('    超分模型     %s' % (d.get('upscale_models') or []))
except Exception:
    print('    读取失败')
" 2>/dev/null || ng "工作台接口未就绪"

# 隧道
echo
c_b "  隧道"
export PATH="/root/.local/bin:$PATH"
TUNNEL_URL=""
if ! command -v rc-tunnel >/dev/null 2>&1; then
  if [ -f /var/run/secrets/frp-self-service/install ]; then
    c_y "  安装 rc-tunnel ..."
    sh /var/run/secrets/frp-self-service/install 2>&1 | tail -3
    export PATH="/root/.local/bin:$PATH"; hash -r
  fi
fi

if command -v rc-tunnel >/dev/null 2>&1; then
  EXIST=$(rc-tunnel status 2>&1 || true)
  if echo "$EXIST" | grep -qiE 'status:[[:space:]]*active'; then
    ok "已有活动隧道，复用"
    TUNNEL_URL=$(echo "$EXIST" | grep -oE 'https://[^ ]+' | head -1)
  else
    echo "$EXIST" | grep -q 'broker has no active tunnel' && { c_y "  清理僵尸 frpc"; rc-tunnel stop >/dev/null 2>&1 || true; sleep 2; }
    c_y "  开隧道 ..."
    rc-tunnel expose --port 8188 >/dev/null 2>&1 || rc-tunnel expose -port 8188 >/dev/null 2>&1 || true
    sleep 3
    OUT=$(rc-tunnel status 2>&1 || true)
    TUNNEL_URL=$(echo "$OUT" | grep -oE 'https://[^ ]+' | head -1)
  fi
  echo "$TUNNEL_URL" | grep -q http && ok "隧道: $TUNNEL_URL" || no "隧道未就绪，稍后跑 /workspace/tunnel.sh start"
else
  ng "rc-tunnel 未安装"
fi

# ---------------------------------------------------------------- 汇总
TOTAL=$(( $(date +%s) - DEPLOY_T0 ))
echo
c_b "════════ 完成 ════════"
echo
[ -n "$TUNNEL_URL" ] && { c_g "  工作台 : $TUNNEL_URL/dsh"; c_g "  ComfyUI: $TUNNEL_URL"; }
echo "  本地   : http://127.0.0.1:8188/dsh"
echo "  日志   : tail -f $LOG"
echo
echo "  核心模型: $CORE ($(du -sh "$CORE" 2>/dev/null|cut -f1))  持久"
echo "  编码器  : $BIG ($(du -sh "$BIG" 2>/dev/null|cut -f1))  overlay，下次重建会重下"
df -BG /workspace /opt 2>/dev/null | sed 's/^/  /'
echo
echo "  ────────────────────────────"
printf '  \033[1;36m总耗时 : %s\033[0m\n' "$(fmt_dur "$TOTAL")"
echo "  ────────────────────────────"
echo
echo "[deploy-25g] $(date '+%F %T') 完成，总耗时 $(fmt_dur "$TOTAL")" >> "$LOG" 2>/dev/null || true
c_g "部署完成"
