#!/usr/bin/env bash
# ============================================================================
# bench-speed.sh —— 采样速度 A/B 测试
#
# 同一份工作负载，换不同启动参数各跑一次，记录 s/it，最后出对比表。
# 目的：定位「慢」到底是哪个参数/kernel 造成的。
#
# 用法：
#   bash bench-speed.sh              跑全部变体
#   bash bench-speed.sh current      只跑当前配置（快速基线）
#   bash bench-speed.sh nodyn        只跑「开启动态显存」
#
# 每个变体单独写日志到 /workspace/bench/<name>.log
# ============================================================================
set -uo pipefail

COMFY=/opt/ComfyUI
PY=/opt/venv/bin/python
BASE_LOG=/workspace/comfy.log
OUT=/workspace/bench
mkdir -p "$OUT"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }

# 基准测试参数：小尺寸、短时长、6 步，跑得快又能反映 s/it
TEST_TIER=small
TEST_ORIENT=portrait
TEST_SECONDS=5
TEST_STEPS=6

# ---------------------------------------------------------------- 公共函数
wait_ready(){
  local i code
  for i in $(seq 1 180); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
           http://127.0.0.1:8188/system_stats 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    sleep 1
  done
  return 1
}

ensure_input_image(){
  local f=/opt/ComfyUI/input/bench_ref.png
  [ -f "$f" ] && { echo "$f"; return 0; }
  "$PY" - <<'PYEOF' >/dev/null 2>&1
from PIL import Image, ImageDraw
im = Image.new("RGB", (480, 832), (30, 40, 60))
d = ImageDraw.Draw(im)
d.rectangle([120, 200, 360, 640], fill=(200, 180, 150))
d.ellipse([180, 120, 300, 240], fill=(230, 200, 170))
im.save("/opt/ComfyUI/input/bench_ref.png")
PYEOF
  [ -f "$f" ] && echo "$f"
}

restart_with(){ # $@ = launch args
  pkill -f 'venv/bin/python.*main\.py' 2>/dev/null
  sleep 3
  cd "$COMFY" || return 1
  nohup "$PY" -u main.py "$@" >> "$BASE_LOG" 2>&1 &
  wait_ready
}

run_once(){ # $1 = 变体名
  local name="$1"
  local log="$OUT/$name.log"
  : > "$log"

  local n0
  n0=$(wc -l < "$BASE_LOG")

  # 先从 options 接口取实际模型名，避免硬编码
  local unet vae clip
  local opt
  opt=$(curl -s http://127.0.0.1:8188/dsh/api/options 2>/dev/null)
  unet=$(echo "$opt" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
l=[x for x in (d.get('unet') or []) if 'hyperflow' in x.lower()]
print(l[0] if l else '')" 2>/dev/null)
  vae=$(echo "$opt" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
l=[x for x in (d.get('vae') or []) if 'video_vae_int8' in x.lower()] or \
  [x for x in (d.get('vae') or []) if 'video_vae' in x.lower()]
print(l[0] if l else '')" 2>/dev/null)
  clip=$(echo "$opt" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
l=d.get('clip') or []
print(l[0] if l else '')" 2>/dev/null)

  echo "  unet=$unet"
  echo "  vae=$vae"
  echo "  clip=$clip"

  if [ -z "$unet" ]; then
    c_r "  没找到 hyperflow 模型，放弃"
    echo "FAIL" > "$OUT/$name.result"
    return 1
  fi

  c_y "  提交测试任务 ..."
  local resp
  resp=$(curl -s -X POST http://127.0.0.1:8188/dsh/api/submit \
    -H 'Content-Type: application/json' -d "{
      \"engine\":\"hyperflow\",
      \"first_frame\":\"bench_ref.png\",
      \"prompt\":\"a calm portrait, static camera, soft light\",
      \"tier\":\"$TEST_TIER\",
      \"orientation\":\"$TEST_ORIENT\",
      \"seconds\":$TEST_SECONDS,
      \"length_mode\":\"single\",
      \"steps\":$TEST_STEPS,
      \"seed\":1,
      \"upscale_scale\":0,
      \"unet\":\"$unet\",
      \"vae_video\":\"$vae\",
      \"clip\":\"$clip\"
    }" 2>/dev/null)

  local jid
  jid=$(echo "$resp" | "$PY" -c "import sys,json;print((json.load(sys.stdin).get('job') or {}).get('id',''))" 2>/dev/null)
  if [ -z "$jid" ]; then
    c_r "  提交失败：$(echo "$resp" | head -c 300)"
    echo "FAIL" > "$OUT/$name.result"
    return 1
  fi
  echo "  job=$jid"

  # 轮询到完成（最多 30 分钟）
  local st elapsed i
  for i in $(seq 1 1800); do
    st=$(curl -s "http://127.0.0.1:8188/dsh/api/jobs" 2>/dev/null | \
      "$PY" -c "
import sys,json
try:
    for j in json.load(sys.stdin).get('jobs',[]):
        if j.get('id')=='$jid':
            print(j.get('status'),'|',j.get('elapsed'),'|',(j.get('error') or '')[:120]); break
except Exception: pass" 2>/dev/null)

    case "$st" in
      done*|error*|cancelled*) break ;;
    esac
    sleep 2
  done

  # 记录 s/it
  {
    echo "=== $name ==="
    echo "status: $st"
    tail -n +"$n0" "$BASE_LOG" | grep -oE '[0-9]+/[0-9]+ \[[0-9:]+<[0-9:]+,\s*[0-9.]+s/it\]' | tail -6
    tail -n +"$n0" "$BASE_LOG" | grep -E 'Prompt executed in' | tail -1
    tail -n +"$n0" "$BASE_LOG" | grep -cE 'Unloaded partially' | sed 's/^/partial_unloads: /'
    tail -n +"$n0" "$BASE_LOG" | grep -cE 'loaded completely' | sed 's/^/full_loads: /'
  } > "$log"

  # 提取稳态 s/it（取最后一个）
  local sit
  sit=$(grep -oE '[0-9.]+s/it' "$log" | tail -1 | tr -d 's/it')
  echo "${sit:-0}" > "$OUT/$name.result"
  if [ -n "${sit:-}" ]; then
    c_g "  稳态 $sit s/it"
  else
    c_r "  没抓到 s/it"
  fi
}

# ---------------------------------------------------------------- 常见参数
ARGS_CUR="--disable-pinned-memory --disable-async-offload --disable-dynamic-vram --reserve-vram 2"
ARGS_NODYN="--disable-pinned-memory --reserve-vram 2"
ARGS_DYNONLY="--disable-pinned-memory --disable-async-offload --reserve-vram 2"
ARGS_SMART="$ARGS_CUR --disable-smart-memory"

# 同一变体重复次数（首次含 kernel 编译预热，不计入均值）
REPEAT=${REPEAT:-3}
WARMUP=${WARMUP:-1}

run_variant(){
  local name="$1" args="$2"
  c_b "──────── 变体: $name ────────"
  echo "  args: $args"
  echo "  预热 $WARMUP 次（不计入），正式 $REPEAT 次"

  if ! restart_with $args; then
    c_r "  启动失败"; echo "FAIL" > "$OUT/$name.result"; return
  fi
  sleep 5

  local i sit all=""
  for i in $(seq 1 $((WARMUP + REPEAT))); do
    if [ "$i" -le "$WARMUP" ]; then
      echo "  [预热 $i/$WARMUP]"
      run_once "${name}_warm$i" >/dev/null 2>&1 || true
    else
      local k=$((i - WARMUP))
      echo "  [正式 $k/$REPEAT]"
      run_once "${name}_r$k"
      local v
      v=$(cat "$OUT/${name}_r$k.result" 2>/dev/null || echo 0)
      [ "$v" != "0" ] && all="$all $v"
    fi
  done

  # 求均值与最小
  local stats
  stats=$(echo "$all" | tr ' ' '\n' | grep -v '^$' | sort -n | \
    awk 'BEGIN{n=0;s=0;mn=99999}
         {a[NR]=$1; s+=$1; n++; if($1<mn)mn=$1}
         END{
           if(n==0){print "0 0 0"; exit}
           printf "%.2f %.2f %.2f\n", s/n, mn, a[int((n+1)/2)]
         }')
  local avg min med
  avg=$(echo "$stats" | cut -d' ' -f1)
  min=$(echo "$stats" | cut -d' ' -f2)
  med=$(echo "$stats" | cut -d' ' -f3)

  echo "$avg" > "$OUT/$name.result"
  echo "$all" > "$OUT/$name.all"

  if [ "$avg" != "0.00" ]; then
    c_g "  均值 ${avg} s/it  最小 ${min}  中位 ${med}  (样本:${all})"
  else
    c_r "  没抓到有效数据"
  fi
  echo
}

# ---------------------------------------------------------------- 主流程
c_b "════ 采样速度 A/B ════"
echo
echo "测试负载: $TEST_TIER / $TEST_ORIENT / ${TEST_SECONDS}s / ${TEST_STEPS}步"
echo "输出目录: $OUT"
echo

IMG=$(ensure_input_image)
[ -n "$IMG" ] || { c_r "无法生成测试首帧图"; exit 1; }
echo "首帧图: $IMG"
echo

# 环境快照
{
  echo "=== 环境 ==="
  "$PY" -c "import torch;p=torch.cuda.get_device_properties(0);print('gpu',torch.cuda.get_device_name(0));print('vram',p.total_memory//1024//1024,'MB');print('torch',torch.__version__,'hip',torch.version.hip)" 2>/dev/null
  echo "mem_max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
  "$PY" -c "
import comfy_kitchen as ck
b=ck.list_backends().get('hip') or {}
c=set(b.get('capabilities') or [])
for k in ['int8_linear','convrot_w4a4_linear','w4a8_int8_linear','solve_attn','sol_attn','window_attention']:
    print(('OK ' if k in c else '-- '), k)
" 2>/dev/null
} | tee "$OUT/env.txt"
echo

case "${1:-all}" in
  current) run_variant current "$ARGS_CUR" ;;
  nodyn)   run_variant nodyn "$ARGS_NODYN" ;;
  dynonly) run_variant dynonly "$ARGS_DYNONLY" ;;
  smart)   run_variant smart "$ARGS_SMART" ;;
  all)
    run_variant current "$ARGS_CUR"
    run_variant nodyn   "$ARGS_NODYN"
    run_variant dynonly "$ARGS_DYNONLY"
    ;;
  *) c_r "未知变体: $1"; exit 1 ;;
esac

# ---------------------------------------------------------------- 汇总
echo
c_b "════ 结果对比 ════"
printf "  %-10s %-12s %s\n" "变体" "s/it" "说明"
for f in "$OUT"/*.result; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .result)
  v=$(cat "$f")
  case "$n" in
    current) note="当前生产参数" ;;
    nodyn)   note="开动态显存+异步卸载" ;;
    dynonly) note="只开动态显存" ;;
    smart)   note="加 disable-smart-memory" ;;
    *)       note="" ;;
  esac
  printf "  %-10s %-12s %s\n" "$n" "$v" "$note"
done
echo
c_y "完整日志: $OUT/*.log"
c_y "若 nodyn 明显更快 → 改用该参数启动"
c_y "若全部接近 → 问题在 kernel 路径，不是这些开关"
