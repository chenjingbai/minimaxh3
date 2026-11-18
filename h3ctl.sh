#!/usr/bin/env bash
# ============================================================
# h3ctl —— MiniMax H3 环境总控
#
#   ./h3ctl.sh start     启动 ComfyUI（含工作台）
#   ./h3ctl.sh stop      停止 ComfyUI
#   ./h3ctl.sh restart   重启
#   ./h3ctl.sh tunnel    开新隧道（会换域名）
#   ./h3ctl.sh status    查看全部状态
#   ./h3ctl.sh logs      跟踪日志
#   ./h3ctl.sh setup     重建软链/节点（实例重建后跑）
#
# 放在 /workspace/h3ctl.sh，chmod +x 后使用
# ============================================================
set -uo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
LOG=/workspace/comfy.log
PIDFILE=/workspace/.comfy.pid
TUNNEL=/root/.local/bin/rc-tunnel
export PATH="/root/.local/bin:$PATH"

ARGS=(--disable-pinned-memory
      --disable-async-offload
      --disable-dynamic-vram
      --reserve-vram 2
      --cache-none)

c_g() { printf '\033[32m%s\033[0m\n' "$*"; }
c_y() { printf '\033[33m%s\033[0m\n' "$*"; }
c_r() { printf '\033[31m%s\033[0m\n' "$*"; }
c_b() { printf '\033[36m%s\033[0m\n' "$*"; }

running() {
  # 进程 cmdline 是 `/opt/venv/bin/python -u main.py ...`（相对路径），
  # 不能用 $COMFY/main.py 匹配，否则永远为假
  pgrep -f 'venv/bin/python.*main\.py' >/dev/null 2>&1 && return 0
  pgrep -f 'python.*ComfyUI/main\.py' >/dev/null 2>&1 && return 0
  if [ -f "$PIDFILE" ]; then
    local p
    p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  fi
  return 1
}

comfy_pids() {
  pgrep -f 'venv/bin/python.*main\.py' 2>/dev/null | tr '\n' ' '
}

http_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
         http://127.0.0.1:8188/system_stats 2>/dev/null || echo 000)
  [ "$code" = "200" ]
}

do_stop() {
  if running; then
    c_y "停止 ComfyUI ..."
    pkill -f 'venv/bin/python.*main\.py' 2>/dev/null
    for i in $(seq 1 20); do
      running || break
      sleep 0.5
    done
    if running; then
      c_r "优雅停止失败，强制 kill"
      pkill -9 -f 'venv/bin/python.*main\.py' 2>/dev/null
      sleep 1
    fi
  else
    c_y "ComfyUI 未运行"
  fi
  rm -f "$PIDFILE"
  c_g "已停止"
}

do_start() {
  if running; then
    c_y "ComfyUI 已在运行（PID $(comfy_pids)）"
    http_ok && c_g "  服务正常 8188 -> 200" || c_r "  进程在但端口不通，建议 restart"
    show_urls
    return 0
  fi

  if [ ! -f "$COMFY/main.py" ]; then
    c_r "找不到 $COMFY/main.py"
    return 1
  fi

  c_b "启动 ComfyUI ..."
  cd "$COMFY" || return 1
  nohup "$PY" -u main.py "${ARGS[@]}" >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"

  c_y "等待服务就绪 ..."
  for i in $(seq 1 120); do
    if http_ok; then
      c_g "就绪（${i} 秒）"
      show_urls
      return 0
    fi
    running || { c_r "进程已退出，看日志：tail -40 $LOG"; return 1; }
    sleep 1
  done
  c_r "120 秒未就绪，看日志：tail -40 $LOG"
  return 1
}

show_urls() {
  echo
  c_b "本地"
  echo "  ComfyUI   http://127.0.0.1:8188"
  echo "  工作台    http://127.0.0.1:8188/dsh"

  if [ -x "$TUNNEL" ]; then
    local out url
    out=$("$TUNNEL" status 2>&1)
    url=$(echo "$out" | grep -oE 'https://[^ ]+' | head -1)
    if [ -n "$url" ]; then
      c_b "公网（隧道 active）"
      echo "  ComfyUI   $url"
      echo "  工作台    $url/dsh"
    else
      c_y "隧道未激活，跑：./h3ctl.sh tunnel"
    fi
  fi
  echo
}

do_tunnel() {
  if [ ! -x "$TUNNEL" ]; then
    c_r "找不到 rc-tunnel"
    return 1
  fi

  local out
  out=$("$TUNNEL" status 2>&1)

  if echo "$out" | grep -q 'URL:'; then
    c_y "隧道已在使用中，不重开（重开会换域名）"
    echo "$out" | grep -E 'URL:|Status:|Local port:'
    return 0
  fi

  # 僵尸进程：frpc 在跑但 broker 无隧道
  if echo "$out" | grep -q 'broker has no active tunnel'; then
    c_y "检测到僵尸 frpc，先清理 ..."
    "$TUNNEL" stop 2>&1 || true
    sleep 2
  fi

  http_ok || { c_r "ComfyUI 没就绪，先 ./h3ctl.sh start"; return 1; }

  c_b "开新隧道 ..."
  "$TUNNEL" expose -port 8188 2>&1
  sleep 3
  echo
  "$TUNNEL" status 2>&1 | grep -E 'URL:|Status:|Local port:' || true
}

do_status() {
  echo "=== 进程 ==="
  if running; then
    ps -eo pid,etime,rss,cmd | grep 'venv/bin/python.*main\.py' | grep -v grep
  else
    c_r "ComfyUI 未运行"
  fi

  echo
  echo "=== 端口 ==="
  if http_ok; then c_g "8188 -> 200"; else c_r "8188 无响应"; fi
  local dsh
  dsh=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        http://127.0.0.1:8188/dsh 2>/dev/null || echo 000)
  [ "$dsh" = "200" ] && c_g "/dsh -> 200" || c_r "/dsh -> $dsh"

  echo
  echo "=== 显存 / 内存 ==="
  rocm-smi --showmeminfo vram 2>/dev/null | grep -E 'Total|Used' | sed 's/^/  /' || echo "  rocm-smi 不可用"
  awk '/^(anon|file) /{printf "  %-6s %6.1f GB\n",$1,$2/1073741824}' /sys/fs/cgroup/memory.stat 2>/dev/null
  echo "  上限   $(awk '{printf "%.1f GB", $1/1073741824}' /sys/fs/cgroup/memory.max 2>/dev/null)"

  echo
  echo "=== 磁盘 ==="
  df -h /workspace | tail -1 | sed 's/^/  /'

  echo
  echo "=== 隧道 ==="
  if [ -x "$TUNNEL" ]; then
    "$TUNNEL" status 2>&1 | sed 's/^/  /'
  else
    echo "  无 rc-tunnel"
  fi

  echo
  echo "=== 最近任务 ==="
  if [ -f /workspace/dsh_out/video/.keep ]; then :; fi
  ls -lht /workspace/dsh_out/video/*.mp4 2>/dev/null | head -3 | sed 's/^/  /' || echo "  暂无产出"
}

do_setup() {
  c_b "重建软链与节点 ..."

  if [ ! -f "$COMFY/main.py" ]; then
    c_r "找不到 $COMFY/main.py —— 新实例需先在平台模板里打开一次 ComfyUI"
    return 1
  fi

  # ---- 1. 模型软链 ----
  local H3=/workspace/h3-models
  local n=0
  for f in "$H3"/*/*.safetensors; do
    [ -f "$f" ] || continue
    sub=$(basename "$(dirname "$f")")
    [ "$sub" = "fl2va_int8_convrot_comfyui" ] && sub=diffusion_models
    mkdir -p "$COMFY/models/$sub"
    ln -sf "$f" "$COMFY/models/$sub/"
    n=$((n+1))
  done
  c_g "  模型软链 $n 条"

  # ---- 2. 工作台 ----
  if [ -f /workspace/dsh_console_h3/__init__.py ]; then
    ln -sfn /workspace/dsh_console_h3 "$COMFY/custom_nodes/dsh_console_h3"
    rm -rf /workspace/dsh_console_h3/__pycache__ \
           "$COMFY/custom_nodes/dsh_console_h3/__pycache__" 2>/dev/null || true
    c_g "  工作台已挂载"
    [ -f /workspace/dsh_console_h3/ui.html ] || c_y "  [警告] 缺 ui.html，/dsh 会 500"
  else
    c_y "  [跳过] /workspace/dsh_console_h3 不存在"
  fi

  # ---- 3. 节点包（/opt 重置后要重建）----
  local failed=0
  for repo in "city96/ComfyUI-GGUF" "Video-Rebirth/ComfyUI-HyperFlow-Flash"; do
    name=$(basename "$repo")
    if [ -d "$COMFY/custom_nodes/$name" ]; then
      c_g "  $name 已存在"
    else
      c_y "  clone $name ..."
      git clone --depth 1 "https://github.com/$repo" "$COMFY/custom_nodes/$name" \
        && c_g "  $name OK" || { c_r "  $name clone 失败（重试即可）"; failed=1; }
    fi
  done

  # ---- 4. Python 依赖 ----
  "$PY" -m pip install -q gguf 2>/dev/null && c_g "  gguf 依赖就绪" || c_r "  gguf 安装失败"

  # ---- 5. 输出目录持久化 ----
  # /opt 重置会清空 output。把它指向 /workspace，出片天然持久。
  local OUT_RT=/workspace/comfy-output
  if [ -d "$OUT_RT" ]; then
    if [ -L "$COMFY/output" ]; then
      c_g "  output 已是软链"
    elif [ -d "$COMFY/output" ]; then
      c_y "  迁移已有输出到 $OUT_RT ..."
      cp -an "$COMFY/output/." "$OUT_RT/" 2>/dev/null || true
      rm -rf "$COMFY/output"
      ln -sfn "$OUT_RT" "$COMFY/output"
      c_g "  output -> $OUT_RT"
    else
      ln -sfn "$OUT_RT" "$COMFY/output"
      c_g "  output -> $OUT_RT"
    fi
  fi

  # ---- 6. 输入目录持久化（首帧图别丢）----
  local IN_RT=/workspace/comfy-input
  if [ -d "$IN_RT" ]; then
    if [ -L "$COMFY/input" ]; then
      c_g "  input 已是软链"
    elif [ -d "$COMFY/input" ]; then
      cp -an "$COMFY/input/." "$IN_RT/" 2>/dev/null || true
      rm -rf "$COMFY/input"
      ln -sfn "$IN_RT" "$COMFY/input"
      c_g "  input -> $IN_RT"
    else
      ln -sfn "$IN_RT" "$COMFY/input"
      c_g "  input -> $IN_RT"
    fi
  fi

  # ---- 7. temp 目录持久化 ----
  local TMP_RT=/workspace/comfy-temp
  mkdir -p "$TMP_RT"
  if [ -L "$COMFY/temp" ]; then
    c_g "  temp 已是软链"
  elif [ -d "$COMFY/temp" ]; then
    cp -an "$COMFY/temp/." "$TMP_RT/" 2>/dev/null || true
    rm -rf "$COMFY/temp"
    ln -sfn "$TMP_RT" "$COMFY/temp"
    c_g "  temp -> $TMP_RT"
  else
    ln -sfn "$TMP_RT" "$COMFY/temp"
    c_g "  temp -> $TMP_RT"
  fi

  # ---- 8. upscale_models 目录持久化 ----
  local UP_RT=/workspace/models/upscale_models
  mkdir -p "$UP_RT"
  local upn=0
  for f in "$UP_RT"/*.pth "$UP_RT"/*.safetensors; do
    [ -f "$f" ] || continue
    ln -sf "$f" "$COMFY/models/upscale_models/"
    upn=$((upn+1))
  done
  [ "$upn" -gt 0 ] && c_g "  超分模型软链 $upn 条" || c_y "  [提示] $UP_RT 里没有超分模型"

  # ---- 9. user 目录持久化（ComfyUI 设置/工作流）----
  local USR_RT=/workspace/comfy-user
  mkdir -p "$USR_RT/default"
  if [ -L "$COMFY/user" ]; then
    c_g "  user 已是软链"
  elif [ -d "$COMFY/user" ]; then
    cp -an "$COMFY/user/." "$USR_RT/" 2>/dev/null || true
    rm -rf "$COMFY/user"
    ln -sfn "$USR_RT" "$COMFY/user"
    c_g "  user -> $USR_RT"
  else
    ln -sfn "$USR_RT" "$COMFY/user"
    c_g "  user -> $USR_RT"
  fi

  # ---- 10. 工作流 JSON 备份 ----
  local WF_RT=/workspace/workflows
  mkdir -p "$WF_RT"
  if [ -d "$COMFY/user/default/workflows" ]; then
    cp -an "$COMFY/user/default/workflows/." "$WF_RT/" 2>/dev/null || true
  fi
  c_g "  工作流备份目录 $WF_RT"

  echo
  if [ "$failed" = "0" ]; then
    c_g "setup 完成"
  else
    c_y "setup 完成，但有节点包失败，重跑本命令即可"
  fi
}

do_persist() {
  c_b "初始化 /workspace 持久目录 ..."
  mkdir -p /workspace/h3-models/{diffusion_models,text_encoders,vae,loras} \
           /workspace/h3-models/hyperflow \
           /workspace/models/upscale_models \
           /workspace/comfy-output \
           /workspace/comfy-input \
           /workspace/comfy-temp \
           /workspace/comfy-user/default/workflows \
           /workspace/workflows \
           /workspace/dsh_out/video \
           /workspace/dsh_console_h3 \
           /workspace/scripts \
           /workspace/_parked
  c_g "  目录已建"
  echo
  c_b "持久清单"
  for d in /workspace/h3-models /workspace/models /workspace/comfy-output \
           /workspace/comfy-input /workspace/comfy-user /workspace/workflows \
           /workspace/dsh_out /workspace/dsh_console_h3 /workspace/scripts; do
    [ -d "$d" ] && printf "  %-30s %s\n" "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  echo
  df -h /workspace | tail -1 | sed 's/^/  /'
  echo
  c_y "  /opt 下的东西（ComfyUI 本体 / 节点 / venv）不持久，重建后跑 ./h3ctl.sh setup"
}

do_doctor() {
  c_b "持久化体检 ..."
  echo

  echo "--- 模型（应在 /workspace，软链指向 /opt）---"
  local bad=0
  for f in "$COMFY"/models/{diffusion_models,text_encoders,vae,loras}/*.safetensors; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then
      local tgt; tgt=$(readlink -f "$f")
      if [ -f "$tgt" ] && [[ "$tgt" == /workspace/* ]]; then
        printf "  ✅ %-52s -> %s\n" "$(basename "$f")" "${tgt#/workspace/}"
      else
        printf "  ⚠️  %-52s -> %s（不在 /workspace 或断链）\n" "$(basename "$f")" "$tgt"
        bad=$((bad+1))
      fi
    else
      printf "  ❌ %-52s 是真文件，重建会丢\n" "$(basename "$f")"
      bad=$((bad+1))
    fi
  done

  echo
  echo "--- 输出 / 输入 / 临时 / 设置 目录 ---"
  for d in output input temp user; do
    if [ -L "$COMFY/$d" ]; then
      local t; t=$(readlink -f "$COMFY/$d")
      if [[ "$t" == /workspace/* ]]; then
        printf "  ✅ %-7s -> %s\n" "$d" "$t"
      else
        printf "  ⚠️  %-7s -> %s（不在 /workspace）\n" "$d" "$t"
        bad=$((bad+1))
      fi
    elif [ -d "$COMFY/$d" ]; then
      printf "  ❌ %-7s 是真实目录，重建会丢（跑 setup 迁移）\n" "$d"
      bad=$((bad+1))
    fi
  done

  echo
  echo "--- 超分模型 ---"
  local upc=0
  for f in "$COMFY"/models/upscale_models/*.pth "$COMFY"/models/upscale_models/*.safetensors; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then
      printf "  ✅ %s\n" "$(basename "$f")"; upc=$((upc+1))
    else
      printf "  ❌ %s 是真文件，重建会丢\n" "$(basename "$f")"; bad=$((bad+1))
    fi
  done
  [ "$upc" = "0" ] && printf "  ○ 没装超分模型\n"

  echo
  echo "--- 工作台 ---"
  if [ -L "$COMFY/custom_nodes/dsh_console_h3" ]; then
    printf "  ✅ 软链 -> %s\n" "$(readlink -f "$COMFY/custom_nodes/dsh_console_h3")"
  elif [ -d "$COMFY/custom_nodes/dsh_console_h3" ]; then
    printf "  ❌ 是真实目录，重建会丢\n"; bad=$((bad+1))
  fi
  for f in __init__.py ui.html; do
    [ -f "/workspace/dsh_console_h3/$f" ] && printf "  ✅ %s\n" "$f" || { printf "  ❌ 缺 %s\n" "$f"; bad=$((bad+1)); }
  done
  [ -f /workspace/dsh_console_h3/jobs.json ] && printf "  ✅ jobs.json（任务记录）\n" || printf "  ○ jobs.json 还没生成\n"

  echo
  echo "--- 节点包（/opt，不持久）---"
  for n in ComfyUI-GGUF ComfyUI-HyperFlow-Flash; do
    [ -d "$COMFY/custom_nodes/$n" ] && printf "  ○ %s 存在（重建后需 setup 恢复）\n" "$n" \
      || { printf "  ❌ %s 缺失\n" "$n"; bad=$((bad+1)); }
  done

  echo
  echo "--- 脚本 ---"
  for s in h3ctl.sh setup-h3-extra.sh scripts/dl-h3.sh; do
    [ -f "/workspace/$s" ] && printf "  ✅ %s\n" "$s" || printf "  ○ %s 不存在\n" "$s"
  done

  echo
  if [ "$bad" = "0" ]; then
    c_g "全部持久化检查通过"
  else
    c_y "有 $bad 处需要注意（见上）"
  fi
}

do_logs() {
  [ -f "$LOG" ] || { c_r "没有 $LOG"; return 1; }
  tail -n "${1:-60}" -f "$LOG"
}

case "${1:-}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 2; do_start ;;
  tunnel)  do_tunnel ;;
  status)  do_status ;;
  setup)   do_setup ;;
  persist) do_persist ;;
  doctor)  do_doctor ;;
  logs)    do_logs "${2:-60}" ;;
  *)
    cat <<'USAGE'
h3ctl —— MiniMax H3 总控

  ./h3ctl.sh start      启动 ComfyUI（后台，日志写 /workspace/comfy.log）
  ./h3ctl.sh stop       停止
  ./h3ctl.sh restart    重启
  ./h3ctl.sh tunnel     开新隧道（若已有 active 则不重开）
  ./h3ctl.sh status     进程/端口/显存/内存/磁盘/隧道/产出
  ./h3ctl.sh setup      实例重建后恢复：模型软链 + 工作台 + 节点包 + 输出/输入目录
  ./h3ctl.sh persist    初始化 /workspace 持久目录结构
  ./h3ctl.sh doctor     持久化体检（哪些东西重建会丢）
  ./h3ctl.sh logs [N]   跟踪日志（默认 60 行）
USAGE
    ;;
esac
