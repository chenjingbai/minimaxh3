#!/usr/bin/env bash
# ============================================================================
# slim-models.sh —— 去重 + 迁移到 /workspace 永久盘
#
# 保留（约 35 GB）：
#   HyperFlow 6 步引擎  : hyperflow_flash_14b-int8 (16.00G)
#   共用组件            : 编码器 nvfp4_awq (15.69G)
#                         视频 VAE int8 (2.81G)
#                         音频 VAE fp32 (0.61G)
#                         超分 4x-UltraSharp (0.07G)
#
# 删除（约 28 GB）：
#   原生 H3 去噪器 fl2va_pruned_int8 (20.97G) —— 不用这个引擎
#   8 步 turbo LoRA (1.96G)                  —— 只服务原生引擎
#   视频 VAE fp16 (5.21G)                    —— 已用 int8 版
#   HyperFlow 重复副本                        —— 两个目录同一份文件
#
# 做两件事：
#   1. 删掉不需要的文件
#   2. 搬到 /workspace/h3-models（持久盘）
#
# 用法：bash slim-models.sh            # 只看，不动
#       bash slim-models.sh --apply    # 执行
# ============================================================================
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

SRC=/opt/h3-models
DST=/workspace/h3-models
COMFY=/opt/ComfyUI

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }

# 自动找模型源目录
if [ ! -d "$SRC" ] && [ -d "$DST" ]; then SRC="$DST"; fi
if [ ! -d "$SRC" ]; then c_r "找不到模型目录（/opt/h3-models 或 /workspace/h3-models）"; exit 1; fi

c_b "模型源目录: $SRC"
echo

# ---------------------------------------------------------------- 清单
KEEP=(
  # HyperFlow 6 步引擎
  "diffusion_models/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors"
  "hyperflow/fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors"
  # 共用组件
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
  "vae/minimax_h3_video_vae_int8_convrot.safetensors"
  "vae/minimax_h3_audio_vae_fp32.safetensors"
  "upscale_models/4x-UltraSharp.pth"
)

c_b "──── 保留清单 ────"
KEEP_FOUND=()
for rel in "${KEEP[@]}"; do
  f="$SRC/$rel"
  if [ -f "$f" ]; then
    sz=$(du -h "$f" | cut -f1)
    printf '  ✅ %-8s %s\n' "$sz" "$rel"
    KEEP_FOUND+=("$rel")
  fi
done
echo

# ---------------------------------------------------------------- 待删
c_b "──── 待删除 ────"
DEL=0
DEL_BYTES=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#$SRC/}"
  skip=0
  for k in "${KEEP_FOUND[@]}"; do
    [ "$rel" = "$k" ] && { skip=1; break; }
  done
  # 同一文件在两个路径下（diffusion_models 与 hyperflow）只留一份
  [ "$skip" = "1" ] && continue
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  printf '  ❌ %-8s %s\n' "$(du -h "$f" | cut -f1)" "$rel"
  DEL=$((DEL+1)); DEL_BYTES=$((DEL_BYTES+sz))
done < <(find "$SRC" -type f \( -name '*.safetensors' -o -name '*.pth' \) | sort)

echo
c_y "  共 $DEL 个文件，约 $((DEL_BYTES/1024/1024/1024)) GB"
echo

# HyperFlow 那份可能重复
HF_A="$SRC/diffusion_models/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors"
HF_B="$SRC/hyperflow/fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors"
if [ -f "$HF_A" ] && [ -f "$HF_B" ]; then
  c_y "  注：HyperFlow 文件存在两份，会保留 hyperflow/ 那份、删掉 diffusion_models/ 那份"
fi
echo

if [ "$APPLY" != "1" ]; then
  c_y "当前是预览模式，未做任何修改。"
  c_y "确认无误后执行：bash slim-models.sh --apply"
  exit 0
fi

# ---------------------------------------------------------------- 执行删除
c_b "──── 执行删除 ────"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#$SRC/}"
  keep=0
  for k in "${KEEP_FOUND[@]}"; do
    [ "$rel" = "$k" ] && { keep=1; break; }
  done
  [ "$keep" = "1" ] && continue
  rm -f "$f" && echo "  已删 $rel"
done < <(find "$SRC" -type f \( -name '*.safetensors' -o -name '*.pth' \) | sort)

# 清空目录
find "$SRC" -type d -empty -delete 2>/dev/null || true

# ---------------------------------------------------------------- 迁移
c_b "──── 迁移到 $DST ────"
if [ "$SRC" != "$DST" ]; then
  mkdir -p "$DST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --remove-source-files "$SRC"/ "$DST"/
  else
    cp -an "$SRC"/. "$DST"/ && rm -rf "$SRC"/*
  fi
  find "$SRC" -type d -empty -delete 2>/dev/null || true
  rm -rf "$SRC"
  c_g "  已迁移"
else
  c_g "  已在目标位置"
fi

# ---------------------------------------------------------------- 软链
c_b "──── 重建软链 ────"
for f in "$DST"/*/*.safetensors "$DST"/*/*/*.safetensors "$DST"/*/*.pth; do
  [ -f "$f" ] || continue
  sub=$(basename "$(dirname "$f")")
  case "$sub" in
    fl2va_int8_convrot_comfyui) sub=diffusion_models ;;
  esac
  mkdir -p "$COMFY/models/$sub"
  ln -sf "$f" "$COMFY/models/$sub/"
  echo "  + $sub/$(basename "$f")"
done

# 清掉断链
find "$COMFY/models" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

# ---------------------------------------------------------------- 结果
echo
c_b "──── 结果 ────"
du -sh "$DST"/* 2>/dev/null
echo
c_g "总计: $(du -sh "$DST" 2>/dev/null | cut -f1)"
df -h /workspace | tail -1
echo
c_b "──── 软链验证 ────"
for f in "$COMFY"/models/{diffusion_models,text_encoders,vae,upscale_models}/*; do
  [ -e "$f" ] || continue
  tgt=$(readlink -f "$f" 2>/dev/null)
  if [ -L "$f" ] && [ -f "$tgt" ]; then
    case "$tgt" in
      /workspace/*) printf '  ✅ %s\n' "$(basename "$f")" ;;
      *)            printf '  ⚠️  %s -> %s\n' "$(basename "$f")" "$tgt" ;;
    esac
  fi
done
echo
c_g "完成。重启：cd /opt/ComfyUI && pkill -f main.py; sleep 2; nohup /opt/venv/bin/python -u main.py --disable-pinned-memory --disable-async-offload --disable-dynamic-vram --reserve-vram 2 >> /workspace/comfy.log 2>&1 &"
