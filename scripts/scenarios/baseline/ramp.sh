#!/usr/bin/env bash
# Baseline ramp: hold the real Outer Tracker base (180 boards) and bring the Inner Tracker
# online board by board. Because an IT board carries 17,500 params vs 820 for an OT board,
# the heavy IT boards drive the load as they appear - this traces where the node first
# exceeds the 1 s scrape budget.
#   range: 0 -> 70 IT boards on a fixed 180-OT base (~148k -> ~1.4M params); real IT count = 50.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

OT=${OT:-$OT_BOARDS}
read -ra IT_STEPS <<< "${IT_STEPS:-0 10 20 30 40 50 60 70}"
OUT="$DATA/ramp.csv"
echo "it_boards,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"
for IT in "${IT_STEPS[@]}"; do
  N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  echo ">> 180 OT + $IT IT = $N boards, $P params"
  bringup_mixed "$OT" "$IT"
  ROW=$(sample); echo "   $ROW"
  echo "$IT,$P,$N,$ROW" >> "$OUT"
  AV=$(echo "$ROW" | cut -d, -f5)
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
