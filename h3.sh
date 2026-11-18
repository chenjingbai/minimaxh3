#!/usr/bin/env bash
# ============================================================================
# h3 — 一把梭控制台
#
#   ./h3 start          启动 ComfyUI（缺依赖/模型会自动补，然后起服务+开隧道）
#   ./h3 stop           停止 ComfyUI（不动隧道）
#   ./h3 restart        重启 ComfyUI
#   ./h3 status         全面体检：进程/端口/显存/内存/磁盘/模型/节点/隧道
#   ./h3 tunnel         清隧道并重开（会换域名）
#   ./h3 tunnel-status  只看隧道
#   ./h3 bench          测生成速度（跑一条小片，出 s/it 与耗时）
#   ./h3 fix            只做检测与补缺，不启动服务
#
# 设计要点：
#   · 所有外部命令都带超时，不会挂死
#   · 绕过 /usr/local/bin/git 的代理包装
#   · 每一步先检测再动手，能跳就跳
# ============================================================================
set -uo pipefail

COMFY=${COMFY:-/opt/ComfyUI}
PY=${PY:-/opt/venv/bin/python}
LOG=${LOG:-/workspace/comfy.log}
CORE=${CORE:-/workspace/h3-models}
BIG=${BIG:-/opt/h3-extra}
TUNNEL_BIN=/root/.local/bin/rc-tunnel
PORT=8188

export PATH="/root/.local/bin:$PATH"

# ---------------------------------------------------------------- 基础
c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }
ok(){ c_g "  ✅ $*"; }
no(){ c_y "  ⬜ $*"; }
ng(){ c_r "  ❌ $*"; }
step(){ echo; c_b "──── $* ────"; }

# 真实 git（绕过平台代理包装）
if [ -x /usr/bin/git ]; then
  GIT=/usr/bin/git
else
  GIT=$(command -v git 2>/dev/null || echo git)
fi

running(){ pgrep -f 'venv/bin/python.*main\.py' >/dev/null 2>&1; }

http_code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
             "http://127.0.0.1:$PORT$1" 2>/dev/null || echo 000; }

wait_ready(){ # $1=最多秒数
  local n=${1:-180} i
  for i in $(seq 1 "$n"); do
    [ "$(http_code /system_stats)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- 模型清单
DENOISER_REAL=$CORE/hyperflow/fl2va_int8_convrot_comfyui/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors
ENCODER=$BIG/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
VVAE=$CORE/vae/minimax_h3_video_vae_int8_convrot.safetensors
AVAE=$CORE/vae/minimax_h3_audio_vae_fp32.safetensors
UPSCALE=$CORE/upscale_models/4x-UltraSharp.pth

# ---------------------------------------------------------------- 检测
check_env(){
  step "环境"
  echo "  主机: $(hostname)"
  if [ -x "$PY" ]; then
    "$PY" - <<'PYEOF' 2>/dev/null || ng "torch 不可用"
import torch
p = torch.cuda.get_device_properties(0)
print("  GPU  : %s  %d MB  %s" % (torch.cuda.get_device_name(0),
      p.total_memory//1024//1024, getattr(p,"gcnArchName","?")))
print("  torch: %s | hip %s" % (torch.__version__, torch.version.hip))
PYEOF
  else
    ng "$PY 不存在"
  fi
  echo "  内存: $(awk '{printf "%.1f GiB", $1/1073741824}' /sys/fs/cgroup/memory.max 2>/dev/null)"
  df -BG /workspace /opt 2>/dev/null | sed 's/^/  /'
}

check_models(){
  step "模型"
  local miss=0
  chk(){ if [ -f "$2" ]; then ok "$1 $(du -h "$2" 2>/dev/null | cut -f1)"; else no "$1 缺失"; miss=1; fi; }
  chk "去噪器  " "$DENOISER_REAL"
  chk "编码器  " "$ENCODER"
  chk "视频VAE " "$VVAE"
  chk "音频VAE " "$AVAE"
  chk "超分    " "$UPSCALE"
  return $miss
}

check_links(){
  step "模型软链"
  local bad=0
  for d in diffusion_models text_encoders vae upscale_models loras; do
    local dir=$COMFY/models/$d
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      case "$f" in *.safetensors|*.pth) ;; *) continue ;; esac
      if [ -L "$f" ] && [ ! -e "$f" ]; then
        ng "断链: $d/$(basename "$f")"
        bad=$((bad+1))
      fi
    done
  done
  [ "$bad" = 0 ] && ok "无断链"
  return $bad
}

check_nodes(){
  step "节点包"
  for n in ComfyUI-GGUF ComfyUI-HyperFlow-Flash; do
    if [ -d "$COMFY/custom_nodes/$n" ]; then ok "$n"; else no "$n 缺失"; fi
  done
  if [ -f /workspace/dsh_console_h3/__init__.py ]; then
    ok "工作台源码"
  else
    no "工作台源码缺失"
  fi
  if [ -L "$COMFY/custom_nodes/dsh_console_h3" ]; then
    ok "工作台已挂载 → $(readlink -f "$COMFY/custom_nodes/dsh_console_h3")"
  else
    no "工作台未挂载"
  fi
}

check_deps(){
  step "Python 依赖"
  MISSING_DEPS=""
  for spec in "trampoline:trampoline" "torchsde:torchsde" "kornia:kornia" \
              "comfyui-workflow-templates:comfyui_workflow_templates" \
              "comfyui-frontend-package:comfyui_frontend_package" \
              "comfy-kitchen:comfy_kitchen" "modelscope:modelscope" \
              "gguf:gguf" "pillow:PIL" "av:av"; do
    pkg=${spec%%:*}; mod=${spec##*:}
    "$PY" -c "import importlib;importlib.import_module('$mod')" >/dev/null 2>&1 \
      || MISSING_DEPS="$MISSING_DEPS $pkg"
  done
  if [ -n "$MISSING_DEPS" ]; then no "缺:$MISSING_DEPS"; else ok "齐全"; fi
}

# ---------------------------------------------------------------- 补缺
fix_all(){
  local need=0

  # 依赖
  check_deps
  if [ -n "$MISSING_DEPS" ]; then
    step "补装依赖"
    for p in $MISSING_DEPS; do
      c_y "  pip install $p"
      timeout 180 "$PY" -m pip install -q "$p" 2>&1 | tail -2
    done
    need=1
  fi

  # ComfyUI
  if [ ! -f "$COMFY/main.py" ]; then
    step "安装 ComfyUI"
    need=1
    if timeout 120 "$GIT" clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY" >/dev/null 2>&1; then
      ok "git clone 成功"
    else
      c_y "  git 失败，试 tar.gz"
      if timeout 150 curl -fL -o /tmp/cu.tgz \
           "https://ghfast.top/https://github.com/comfyanonymous/ComfyUI/archive/refs/heads/master.tar.gz" 2>/dev/null; then
        tar xzf /tmp/cu.tgz -C /opt && mv /opt/ComfyUI-master "$COMFY" && ok "tar.gz 成功" || ng "解压失败"
      else
        ng "ComfyUI 拉取失败"
      fi
    fi
  fi

  # 节点包
  for repo in "city96/ComfyUI-GGUF" "Video-Rebirth/ComfyUI-HyperFlow-Flash"; do
    n=$(basename "$repo")
    [ -d "$COMFY/custom_nodes/$n" ] && continue
    step "安装 $n"
    need=1
    mkdir -p "$COMFY/custom_nodes"
    if timeout 120 "$GIT" clone --depth 1 "https://github.com/$repo" "$COMFY/custom_nodes/$n" >/dev/null 2>&1; then
      ok "$n"
    elif timeout 150 curl -fL -o "/tmp/$n.tgz" \
         "https://ghfast.top/https://github.com/$repo/archive/refs/heads/main.tar.gz" 2>/dev/null; then
      tar xzf "/tmp/$n.tgz" -C /tmp && mv "/tmp/$n-main" "$COMFY/custom_nodes/$n" && ok "$n（tar.gz）" || ng "$n 失败"
    else
      ng "$n 失败"
    fi
  done

  # 工作台软链
  if [ -f /workspace/dsh_console_h3/__init__.py ] || [ -f /workspace/h3-deploy/dsh_console_h3/__init__.py ]; then
    SRC=/workspace/dsh_console_h3
    [ -f "$SRC/__init__.py" ] || SRC=/workspace/h3-deploy/dsh_console_h3
    # 清自引用
    if [ -L "$SRC" ]; then
      cur=$(readlink "$SRC")
      [ "$cur" = "$SRC" ] && unlink "$SRC"
    fi
    if [ ! -d "$SRC" ] || [ "$(readlink -f "$SRC" 2>/dev/null)" != "$(readlink -f /workspace/dsh_console_h3 2>/dev/null)" ]; then
      ln -sfn "$SRC" /workspace/dsh_console_h3 2>/dev/null || true
    fi
    ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
    rm -rf /workspace/dsh_console_h3/__pycache__ "$COMFY/custom_nodes/dsh_console_h3/__pycache__" 2>/dev/null || true
    ok "工作台挂载"
    need=1
  fi

  # 模型软链
  link(){ [ -f "$1" ] || return 0; mkdir -p "$COMFY/models/$2"; ln -sf "$1" "$COMFY/models/$2/"; }
  link "$DENOISER_REAL" diffusion_models
  link "$ENCODER" text_encoders
  link "$VVAE" vae
  link "$AVAE" vae
  link "$UPSCALE" upscale_models

  return $need
}

# ---------------------------------------------------------------- 服务控制
do_stop(){
  step "停止服务"
  if running; then
    pkill -f 'venv/bin/python.*main\.py' 2>/dev/null
    for i in $(seq 1 20); do running || break; sleep 0.5; done
    running && { c_y "  强制结束"; pkill -9 -f 'venv/bin/python.*main\.py' 2>/dev/null; sleep 1; }
  fi
  running && ng "仍在运行" || ok "已停止"
}

do_start_svc(){
  if running; then
    [ "$(http_code /system_stats)" = "200" ] && { ok "服务已在运行"; return 0; }
    c_y "  进程在但端口不通，重启"
    do_stop
  fi

  [ -f "$COMFY/main.py" ] || { ng "ComfyUI 未安装，先跑 ./h3 fix"; return 1; }

  step "启动 ComfyUI"
  cd "$COMFY" || return 1
  nohup "$PY" -u main.py \
    --disable-pinned-memory \
    --disable-async-offload \
    --disable-dynamic-vram \
    --reserve-vram 2 \
 >> "$LOG" 2>&1 &
  echo $! > /opt/comfy.pid

  c_y "  等待就绪..."
  if wait_ready 180; then
    ok "就绪（本地 :$PORT）"
  else
    ng "180 秒未就绪"
    tail -20 "$LOG" | sed 's/^/    /'
    return 1
  fi
}

# ---------------------------------------------------------------- 隧道
do_tunnel(){
  if [ ! -x "$TUNNEL_BIN" ]; then
    step "安装 rc-tunnel"
    if [ -f /var/run/secrets/frp-self-service/install ]; then
      sh /var/run/secrets/frp-self-service/install 2>&1 | tail -3
      hash -r 2>/dev/null || true
    fi
  fi
  [ -x "$TUNNEL_BIN" ] || { ng "rc-tunnel 不可用"; return 1; }

  [ "$(http_code /system_stats)" = "200" ] || { ng "服务未就绪，先 ./h3 start"; return 1; }

  step "重启隧道"
  "$TUNNEL_BIN" stop >/dev/null 2>&1 || true
  sleep 3
  "$TUNNEL_BIN" expose --port "$PORT" >/dev/null 2>&1 \
    || "$TUNNEL_BIN" expose -port "$PORT" >/dev/null 2>&1 || true
  sleep 4

  local out url
  out=$("$TUNNEL_BIN" status 2>&1 || true)
  url=$(echo "$out" | grep -oE 'https://[^ ]+' | head -1)
  if [ -n "$url" ]; then
    ok "隧道已开"
    echo
    c_g "  工作台: $url/dsh"
    c_g "  ComfyUI: $url"
    echo
  else
    ng "隧道未就绪"
    echo "$out" | sed 's/^/    /'
  fi
}

do_tunnel_status(){
  step "隧道"
  if [ ! -x "$TUNNEL_BIN" ]; then ng "rc-tunnel 未安装"; return 1; fi
  "$TUNNEL_BIN" status 2>&1 | sed 's/^/  /'
}

# ---------------------------------------------------------------- 状态
do_status(){
  check_env

  step "服务"
  if running; then
    ps -eo pid,etime,rss,cmd | grep 'venv/bin/python.*main\.py' | grep -v grep | sed 's/^/  /'
    local c; c=$(http_code /system_stats)
    [ "$c" = "200" ] && ok "system_stats 200" || ng "system_stats $c"
    local d; d=$(http_code /dsh)
    [ "$d" = "200" ] && ok "工作台 /dsh 200" || ng "工作台 /dsh $d"
  else
    ng "未运行"
  fi

  step "显卡 / 内存"
  rocm-smi --showmeminfo vram 2>/dev/null | grep -E 'Total|Used' | sed 's/^/  /'
  awk '/^(anon|file|file_mapped) /{printf "  %-14s %6.1f GB\n",$1,$2/1073741824}' /sys/fs/cgroup/memory.stat 2>/dev/null

  check_models
  check_links
  check_nodes
  check_deps
  [ -n "$MISSING_DEPS" ] && no "需要补装:$MISSING_DEPS"

  do_tunnel_status

  step "最近任务"
  curl -s "http://127.0.0.1:$PORT/dsh/api/jobs" 2>/dev/null | \
    "$PY" -c "
import sys,json
try:
    for j in json.load(sys.stdin).get('jobs',[])[:3]:
        print('  %-10s %-14s %s' % (j.get('status'), j.get('id'),
              (j.get('prompt_preview') or '')[:26]))
except Exception: print('  读取失败')
" 2>/dev/null
}

# ---------------------------------------------------------------- 测速
do_bench(){
  [ "$(http_code /system_stats)" = "200" ] || { ng "服务未就绪，先 ./h3 start"; return 1; }

  step "测速准备"
  local img=$COMFY/input/bench_ref.png
  if [ ! -f "$img" ]; then
    "$PY" - <<'PYEOF' >/dev/null 2>&1
from PIL import Image, ImageDraw
im = Image.new("RGB", (384, 640), (30, 40, 60))
d = ImageDraw.Draw(im)
d.rectangle([110, 200, 270, 500], fill=(200, 180, 150))
d.ellipse([150, 90, 230, 180], fill=(230, 200, 170))
im.save("/opt/ComfyUI/input/bench_ref.png")
PYEOF
  fi
  [ -f "$img" ] && ok "测试图 $img" || { ng "测试图生成失败"; return 1; }

  local before; before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  local seed=$(( RANDOM + 1000 ))

  step "跑一条（384×640 / 5秒 / 6步 / seed $seed）"
  local resp; resp=$(curl -s -X POST "http://127.0.0.1:$PORT/dsh/api/submit" \
    -H 'Content-Type: application/json' -d "{
      \"engine\":\"hyperflow\",
      \"first_frame\":\"bench_ref.png\",
      \"prompt\":\"a calm portrait, static camera, soft light\",
      \"tier\":\"small\",\"orientation\":\"portrait\",
      \"seconds\":5,\"length_mode\":\"single\",
      \"steps\":6,\"seed\":$seed}" 2>/dev/null)

  if ! echo "$resp" | grep -q '"ok": true'; then
    ng "提交失败"
    echo "$resp" | head -c 300
    return 1
  fi
  ok "已提交，等待完成..."

  local i
  for i in $(seq 1 200); do
    sleep 2
    if tail -n +"$before" "$LOG" 2>/dev/null | grep -q 'Prompt executed in'; then break; fi
  done

  step "结果"
  tail -n +"$before" "$LOG" | grep -oE '[0-9]+/[0-9]+ \[[0-9:]+<[0-9:]+,\s*[0-9.]+s/it\]' | tail -6 | sed 's/^/  /'
  tail -n +"$before" "$LOG" | grep 'Prompt executed in' | tail -1 | sed 's/^/  /'
  echo
  echo "  加载次数: $(tail -n +"$before" "$LOG" | grep -c 'Requested to load' 2>/dev/null)"
  echo "  显存: $(rocm-smi --showmeminfo vram 2>/dev/null | grep Used | awk '{printf "%.1f GB", $NF/1073741824}')"
}

# ---------------------------------------------------------------- 入口
case "${1:-}" in
  start)
    check_env >/dev/null
    fix_all >/dev/null 2>&1
    do_start_svc || exit 1
    do_tunnel
    ;;
  stop)
    do_stop
    ;;
  restart)
    do_stop
    sleep 2
    do_start_svc || exit 1
    echo
    do_tunnel_status
    ;;
  status)
    do_status
    ;;
  tunnel)
    do_tunnel
    ;;
  tunnel-status)
    do_tunnel_status
    ;;
  bench)
    do_bench
    ;;
  fix)
    fix_all
    echo
    c_g "补缺完成"
    ;;
  *)
    cat <<'USAGE'
h3 — W7900D + MiniMax H3 控制台

  ./h3 start          启动服务（自动补依赖/模型/节点），完成后开隧道
  ./h3 stop           停止 ComfyUI
  ./h3 restart        重启 ComfyUI（不动隧道）
  ./h3 status         全面体检
  ./h3 tunnel         清隧道并重开（换域名）
  ./h3 tunnel-status  只看隧道
  ./h3 bench          测生成速度
  ./h3 fix            只检测+补缺，不启动

USAGE
    ;;
esac
