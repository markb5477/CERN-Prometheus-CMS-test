#!/usr/bin/env bash
# Big jumps toward 2M; stop at the first failure and report the last healthy level.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

MODULES=${MODULES:-80}
read -ra STEPS <<< "${STEPS:-500000 1000000 1500000 2000000}"
OUT="$RESULTS/stress.csv"

write_config "$MODULES"
echo "params,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,verdict" > "$OUT"
LAST_OK=0
for TOTAL in "${STEPS[@]}"; do
  PM=$((TOTAL / MODULES))
  echo ">> $TOTAL params = $MODULES modules x $PM parameters"
  stop_all; rm -rf "$DATA/tsdb"
  start_modules "$MODULES" "$PM"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  if [ -n "$DUR" ] && awk "BEGIN{exit !($DUR < 1.0)}" && [ "${UP:-0}" = "$MODULES" ]; then
    V=ok; LAST_OK=$TOTAL
  else
    V=BROKE
  fi
  echo "   scrape=${DUR}s up=$UP/$MODULES -> $V"
  echo "$TOTAL,$PM,$HEAD,$DUR,$UP,$MEM,$V" >> "$OUT"
  [ "$V" = BROKE ] && break
done
echo "last healthy: $LAST_OK params -> $OUT"
