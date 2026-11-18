#!/usr/bin/env bash
# W7900D + MiniMax H3 加速方案部署（int8 VAE + HyperFlow Flash）
# 幂等：重复跑不会重复下载、不会重复 clone
# /opt 是 overlay，实例重建后跑一次这个脚本即可恢复
set -euo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
MS=/opt/venv/bin/modelscope
DIR=/workspace/h3-models

echo "== 0/6 环境自检 =="
[ -f "$COMFY/main.py" ] || { echo "   [停] 找不到 $COMFY/main.py"; exit 1; }
[ -x "$PY" ]           || { echo "   [停] 找不到 $PY"; exit 1; }
echo "   ComfyUI: $COMFY"
echo "   Python : $($PY -V 2>&1)"

echo "== 1/6 检查文件/节点现状 =="
VAE_INT8="$DIR/vae/minimax_h3_video_vae_int8_convrot.safetensors"
HF_FILE_NAME=minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors
HF_DIR="$DIR/hyperflow/fl2va_int8_convrot_comfyui"
HF_FILE="$HF_DIR/$HF_FILE_NAME"

need_vae=1; [ -f "$VAE_INT8" ] && need_vae=0
need_hf=1;  [ -f "$HF_FILE" ]  && need_hf=0
need_nodes=0
[ -d "$COMFY/custom_nodes/ComfyUI-HyperFlow-Flash" ] || need_nodes=1

echo "   int8 VAE : $([ $need_vae -eq 0 ] && echo 已有 || echo 缺失)"
echo "   HyperFlow: $([ $need_hf -eq 0 ] && echo 已有 || echo 缺失)"
echo "   节点包   : $([ $need_nodes -eq 0 ] && echo 已有 || echo 缺失)"

if [ $need_vae -eq 1 ] || [ $need_hf -eq 1 ]; then
  echo "== 2/6 空间检查（需要约 20 GB）=="
  FREE=$(df -BG --output=avail /workspace | tail -1 | tr -dc '0-9')
  echo "   /workspace 剩余 ${FREE}G"
  [ "$FREE" -ge 25 ] || { echo "   [停] 空间不足 25G"; exit 1; }

  if [ ! -x "$MS" ]; then
    echo "   装 modelscope..."
    $PY -m pip install -U modelscope -q
  fi
fi

echo "== 3/6 下载 =="
if [ $need_vae -eq 1 ]; then
  echo "   [1/2] int8 视频 VAE (2.8 GB)"
  $MS download --model Comfy-Org/minimax-H3 --local_dir "$DIR" \
    --include 'vae/minimax_h3_video_vae_int8_convrot.safetensors'
fi

if [ $need_hf -eq 1 ]; then
  echo "   [2/2] HyperFlow Flash int8 (16.0 GB)"
  mkdir -p "$DIR/hyperflow"
  $MS download --model VideoRebirthAI/hyperflow-h3-flash --local_dir "$DIR/hyperflow" \
    --include "fl2va_int8_convrot_comfyui/$HF_FILE_NAME"
fi

echo "== 4/6 校验 sha256 =="
if [ -f "$VAE_INT8" ]; then
  got=$(sha256sum "$VAE_INT8" | cut -d' ' -f1)
  want=52a2c8c73583c86e4f41cdcce3a6ad0ea562987bc0bf3d60a0cef5f5c8e60c0e
  if [ "$got" = "$want" ]; then echo "   int8 VAE  OK"; else echo "   [停] int8 VAE 校验失败"; echo "   得到 $got"; exit 1; fi
fi
if [ -f "$HF_FILE" ]; then
  got=$(sha256sum "$HF_FILE" | cut -d' ' -f1)
  want=d38f0c0c46824091fa448cd8f4a68b5d3832317867d5ddc02305eaa650710604
  if [ "$got" = "$want" ]; then echo "   HyperFlow OK"; else echo "   [停] HyperFlow 校验失败"; echo "   得到 $got"; exit 1; fi
fi

echo "== 5/6 安装节点包 =="
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"

if [ ! -d ComfyUI-GGUF ]; then
  echo "   clone ComfyUI-GGUF"
  git clone --depth 1 https://github.com/city96/ComfyUI-GGUF
else
  echo "   ComfyUI-GGUF 已存在，跳过"
fi

if [ ! -d ComfyUI-HyperFlow-Flash ]; then
  echo "   clone ComfyUI-HyperFlow-Flash"
  git clone --depth 1 https://github.com/Video-Rebirth/ComfyUI-HyperFlow-Flash
else
  echo "   ComfyUI-HyperFlow-Flash 已存在，跳过"
fi

echo "   装依赖（requirements.txt 只有 gguf）"
$PY -m pip install -q -r ComfyUI-HyperFlow-Flash/requirements.txt

echo "== 6/6 建软链 =="
for f in "$VAE_INT8" "$HF_FILE"; do
  [ -f "$f" ] || continue
  sub=$(basename "$(dirname "$f")")
  [ "$sub" = "fl2va_int8_convrot_comfyui" ] && sub=diffusion_models
  mkdir -p "$COMFY/models/$sub"
  ln -sf "$f" "$COMFY/models/$sub/"
  echo "   + $sub/$(basename "$f")"
done

echo "== 7/9 挂载 DSH 工作台 =="
CONSOLE_SRC=/workspace/dsh_console_h3
CONSOLE_DST="$COMFY/custom_nodes/dsh_console_h3"
if [ -f "$CONSOLE_SRC/__init__.py" ]; then
  ln -sfn "$CONSOLE_SRC" "$CONSOLE_DST"
  rm -rf "$CONSOLE_SRC/__pycache__" "$CONSOLE_DST/__pycache__" 2>/dev/null || true
  echo "   + $CONSOLE_DST -> $CONSOLE_SRC"
  if [ -f "$CONSOLE_SRC/ui.html" ]; then
    echo "   ui.html 就位"
  else
    echo "   [警告] 缺 ui.html，/dsh 页面会 500"
  fi
else
  echo "   [跳过] $CONSOLE_SRC/__init__.py 不存在"
fi

echo "== 8/9 恢复隧道 =="
TUNNEL=/root/.local/bin/rc-tunnel
if [ -x "$TUNNEL" ]; then
  if "$TUNNEL" status 2>&1 | grep -qiE 'Status:[[:space:]]*active'; then
    "$TUNNEL" status 2>&1 | grep -E 'URL:|Status:|Local port:'
  else
    echo "   隧道未激活，执行 expose -port 8188 ..."
    "$TUNNEL" expose -port 8188 2>&1 || echo "   [警告] expose 失败"
    sleep 3
    "$TUNNEL" status 2>&1 | grep -E 'URL:|Status:|Local port:' || true
  fi
else
  echo "   [跳过] 找不到 rc-tunnel"
fi

echo "== 9/9 自检 =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8188/system_stats 2>/dev/null || echo 000)
echo "   ComfyUI /system_stats -> $CODE"
if [ "$CODE" = "200" ]; then
  D=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8188/dsh 2>/dev/null || echo 000)
  echo "   工作台 /dsh -> $D"
fi

echo
echo "== 完成 =="
ls -lL "$COMFY/models/diffusion_models/" "$COMFY/models/vae/" 2>/dev/null | grep -E 'minimax' || true
cat <<'TIP'

重启 ComfyUI：
  cd /opt/ComfyUI && /opt/venv/bin/python -u main.py \
    --disable-pinned-memory --disable-async-offload --disable-dynamic-vram \
    --reserve-vram 2 2>&1 | tee /workspace/comfy.log

工作台：<隧道域名>/dsh

用 HyperFlow：Workflow -> Browse Templates -> ComfyUI-HyperFlow-Flash -> hyperflow_i2v_int8
  length 用 17n+5（124/141/362），宽高为 32 的倍数
  KSamplerSelect=euler，CFG=1.0，步数在 HyperFlow Sigmas 里选 4/6/8

换 int8 VAE：模板里 105:11 改 minimax_h3_video_vae_int8_convrot.safetensors
  若出「有声黑视频」-> 立刻改回 minimax_h3_video_vae_fp16.safetensors

隧道：rc-tunnel status / rc-tunnel expose -port 8188
  别用 rc-tunnel stop，一停就换域名
TIP
