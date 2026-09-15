#!/bin/bash
# Averages CPU for the processes that matter and utilization for each GPU over ~12 s.
top -l 7 -s 2 -stats pid,command,cpu 2>/dev/null | awk '
  /^PID/ {n++; next}
  n>=2 && ($2=="WindowServer" || $2=="kernel_task" || $2=="HoloFrame" || $2=="replayd") {s[$2]+=$3; c[$2]++}
  END {for (k in s) printf "  %-13s %5.1f%% CPU\n", k, s[k]/c[k]}'
for i in 1 2 3 4 5 6; do
  # One accelerator per "+-o" block; the class and the statistics can appear in either
  # order inside it, so settle each block only when the next one starts.
  ioreg -r -d 1 -w0 -c IOAccelerator 2>/dev/null | awk '
    function flush() { if (cls != "") { k = (cls ~ /Intel/ ? "Intel" : "AMD"); if (u > m[k]) m[k] = u; seen[k]=1 } cls=""; u=0 }
    /\+-o/ { flush() }
    /"IOClass" = / { match($0, /"IOClass" = "[^"]*"/); cls = substr($0, RSTART+13, RLENGTH-14) }
    /"Device Utilization %"=/ { match($0, /"Device Utilization %"=[0-9]+/); v = substr($0, RSTART+23, RLENGTH-23) + 0; if (v > u) u = v }
    END { flush(); for (k in seen) printf "%s=%d\n", k, m[k] }'
  /bin/sleep 2
done | awk -F= '{s[$1]+=$2; c[$1]++} END {for (k in s) printf "  %-13s %5.1f%% GPU\n", k, s[k]/c[k]}'
