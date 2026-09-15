#!/bin/bash
# Automated A/B: each configuration relaunches HoloFrame with simulated head motion, puts the
# pointer on the canvas, lets it settle, then measures. Configurations are interleaved over
# several rounds so slow drift (heat, background jobs) lands on all of them equally.
#
# Needs the pointer helper built first (see README.md here). Results land in $OUT/results.txt.
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${APP:-$(cd "$HERE/../.." && pwd)/HoloFrame.app}
B=${B:-/tmp/holoframe-bench}
OUT=${OUT:-$B/perf}; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-2}
SETTLE=${SETTLE:-20}

declare -a NAMES=(${CONFIGS:-base nocapture cap30})
envs_for() {
  case "$1" in
    base|offcanvas|hold) echo "" ;;
    holdcap30)   echo "--env HOLOFRAME_CAPTURE_FPS=30" ;;
    holdnoskip)  echo "--env HOLOFRAME_NO_SKIP=1" ;;
    glassesgpu)  echo "--env HOLOFRAME_GPU=glasses" ;;
    # offcanvas: same as base, but the pointer is parked on the built-in screen.
    # hold*: a head holding still instead of sweeping.
    cap30)       echo "--env HOLOFRAME_CAPTURE_FPS=30" ;;
    cap20)       echo "--env HOLOFRAME_CAPTURE_FPS=20" ;;
    nocursor)    echo "--env HOLOFRAME_CAPTURE_CURSOR=0" ;;
    nocapture)   echo "--env HOLOFRAME_NO_CAPTURE=1" ;;
    *)           echo "$EXTRA_ENV" ;;
  esac
}

for round in $(seq 1 "$ROUNDS"); do
  for name in "${NAMES[@]}"; do
    pkill -f "$APP/Contents/MacOS/HoloFrame"
    for i in $(seq 1 40); do pgrep -f "$APP/Contents/MacOS/HoloFrame" >/dev/null || break; sleep 0.25; done
    sleep 2
    log="$OUT/$name-$round.log"
    # shellcheck disable=SC2046
    sim=1; [[ "$name" == hold* ]] && sim=hold
    open -a "$APP" --env HOLOFRAME_SIM=$sim --env HOLOFRAME_STATS=5 $(envs_for "$name") \
         --stdout "$log" --stderr "$log"
    for i in $(seq 1 80); do grep -q "capturing canvas\|capture disabled" "$log" 2>/dev/null && break; sleep 0.5; done
    sleep 2
    if [[ "$name" == offcanvas* ]]; then "$B/pointer" builtin >/dev/null; else "$B/pointer" >/dev/null; fi
    sleep "$SETTLE"
    {
      echo "== $name round $round"
      bash "$HERE/measure-load.sh"
      grep "stats" "$log" | tail -2
    } | tee -a "$OUT/results.txt"
  done
done
echo "done" >> "$OUT/results.txt"
