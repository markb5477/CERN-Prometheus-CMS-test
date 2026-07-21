#!/usr/bin/env bash
# Baseline sweep: hold the total board count at the real detector's 230 targets, but vary
# how many of them are Inner-Tracker boards. Same number of scrape targets, very different
# load, because an IT board carries 21x an OT board. This isolates the effect of the OT:IT
# MIXTURE from the effect of target count - the real detector sits at 50 IT of 230.
#   mixture: IT boards in {0, 25, 50, 115, 230} out of 230 (rest OT); 50 = the real detector.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

N=${TARGETS:-$FULL_TARGETS}   # 230 real boards, held fixed
read -ra IT_MIX <<< "${IT_MIX:-0 25 50 115 230}"
OUT="$DATA/sweep.csv"
echo "it_boards,it_frac,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"
for IT in "${IT_MIX[@]}"; do
  [ "$IT" -gt "$N" ] && IT=$N
  OT=$(( N - IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  FRAC=$(awk -v it="$IT" -v n="$N" 'BEGIN{printf "%.3f", (n>0)? it/n : 0}')
  echo ">> $OT OT + $IT IT = $N boards (IT frac $FRAC), $P params"
  bringup_mixed "$OT" "$IT"
  ROW=$(sample); echo "   $ROW"
  echo "$IT,$FRAC,$P,$N,$ROW" >> "$OUT"
  AV=$(echo "$ROW" | cut -d, -f5)
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
