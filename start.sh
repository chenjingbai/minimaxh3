#!/usr/bin/env bash
# ============================================================================
# start.sh —— ComfyUI 唯一启动入口
#
# 所有脚本（h3.sh / deploy-*.sh / h3ctl.sh）都应该调用这个文件，
# 避免启动参数散落在多处、改了一处漏了另一处。
#
# 参数说明见文件末尾注释。要改参数只改这里。
# ============================================================================
set -uo pipefail

COMFY=${COMFY:-/opt/ComfyUI}
PY=${PY:-/opt/venv/bin/python}
LOG=${LOG:-/workspace/comfy.log}
PORT=${PORT:-8188}

cd "$COMFY" || { echo "找不到 $COMFY"; exit 1; }

# ---- 启动参数（改这里就够）----
ARGS=(
  --disable-pinned-memory        # H3 I2V VmPeak 66.9G，pinned 会撑爆 55GiB
  --disable-async-offload        # gfx1100 成功案例都关了
  --disable-dynamic-vram         # 规避「软链模型+动态显存每次重载」
  --reserve-vram 2               # 给 VAE 解码留余量，防部分驱逐致 NaN
)
# 注意：不要加 --cache-none
#   ComfyUI 官方说明：加上它每次运行后释放所有模型，下次重载。
#   实测 34GB 模型每次重载 73 秒，占 5 秒短片总耗时 59%。
#   去掉后由 ComfyUI 自己管，实测省 40 秒。
#
# 不要加 PYTORCH_ALLOC_CONF=expandable_segments:True
#   这套 ROCm 栈上会静默损坏显存（发白/音频NaN/同seed不重现）。

# ---- 单实例保护 ----
if pgrep -f 'venv/bin/python.*main\.py' >/dev/null 2>&1; then
  echo "已有 ComfyUI 在运行（PID $(pgrep -f 'venv/bin/python.*main\.py' | tr '\n' ' ')）"
  exit 0
fi

echo "[start] $(date '+%F %T') 启动 ComfyUI :$PORT"
echo "[start] 参数: ${ARGS[*]}"

exec "$PY" -u main.py "${ARGS[@]}"
