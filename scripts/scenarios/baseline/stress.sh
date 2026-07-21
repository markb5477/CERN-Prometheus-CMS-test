#!/usr/bin/env bash
# Baseline stress: push the real detector PAST 1x to find the single-node ceiling. Scales the
# real mix (keeping 180:50) to 1x, 1.5x, 2x, 3x. Stops at the first scrape that misses the
# 1 s budget or drops a target, and reports the last healthy multiple of the real detector.
#   range: 1x -> 3x the real detector (~1.02M -> ~3.07M params, 230 -> 690 boards).
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

read -ra SCALES <<< "${SCALES:-1.0 1.5 2.0 3.0}"
OUT="$DATA/stress.csv"
echo "scale,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,cpu_pct,ram_pct,cadence_p99_s,verdict" > "$OUT"
LAST_OK=0
for S in "${SCALES[@]}"; do
  OT=$(awk -v b="$OT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  IT=$(awk -v b="$IT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  echo ">> ${S}x detector: $OT OT + $IT IT = $N boards, $P params"
  bringup_mixed "$OT" "$IT"
  IFS=, read -r HEAD DUR UP MEM AV CPU RAM CAD <<< "$(sample)"
  if [ -n "$DUR" ] && awk "BEGIN{exit !($DUR < 1.0)}" && [ "${UP:-0}" = "$N" ]; then
    V=ok; LAST_OK=$S
  else
    V=BROKE
  fi
  echo "   scrape=${DUR}s up=$UP/$N cpu=${CPU}% ram=${RAM}% cadence=${CAD}s -> $V"
  echo "$S,$P,$N,$HEAD,$DUR,$UP,$MEM,$CPU,$RAM,$CAD,$V" >> "$OUT"
  [ "$V" = BROKE ] && break
done
echo "last healthy: ${LAST_OK}x the real detector -> $OUT"
