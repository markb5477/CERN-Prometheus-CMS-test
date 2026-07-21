#!/usr/bin/env bash
# Baseline (single-node, co-located) capacity curve: scale the WHOLE real detector up and
# down, holding the true Outer:Inner board ratio (180:50). Shows how one Prometheus node's
# scrape time / CPU / RAM track the real load as it grows past the ~1M-parameter design point.
#   range: 0.25x -> 2x the real detector, i.e. ~58 -> 460 boards, ~256k -> ~2.05M params,
#          bracketing the real 1x point (230 boards, ~1.02M). Ratio kept real at each step.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

read -ra SCALES <<< "${SCALES:-0.25 0.5 0.75 1.0 1.25 1.5 2.0}"
OUT="$DATA/modules.csv"
echo "scale,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_s" > "$OUT"
for S in "${SCALES[@]}"; do
  OT=$(awk -v b="$OT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  IT=$(awk -v b="$IT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  echo ">> ${S}x detector: $OT OT + $IT IT = $N boards, $P params"
  bringup_mixed "$OT" "$IT"
  ROW=$(sample); echo "   $ROW"
  echo "$S,$P,$N,$ROW" >> "$OUT"
  AV=$(echo "$ROW" | cut -d, -f5)
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
