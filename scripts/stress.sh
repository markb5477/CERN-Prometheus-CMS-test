#!/usr/bin/env bash
# Big jumps toward 2M; stop at the first failure and report the last healthy level.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

EXPORTERS=${EXPORTERS:-80}
read -ra STEPS <<< "${STEPS:-500000 1000000 1500000 2000000}"
OUT="$RESULTS/stress.csv"

write_config "$EXPORTERS"
echo "params,per_exporter,head_series,max_scrape_s,targets_up,memory_bytes,verdict" > "$OUT"
LAST_OK=0
for TOTAL in "${STEPS[@]}"; do
  PE=$((TOTAL / EXPORTERS))
  echo ">> $TOTAL params = $EXPORTERS x $PE"
  stop_all; rm -rf "$DATA/tsdb"
  start_exporters "$EXPORTERS" "$PE"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="client"})')
  UP=$(prom 'count(up{job="client"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  if [ -n "$DUR" ] && awk "BEGIN{exit !($DUR < 1.0)}" && [ "${UP:-0}" = "$EXPORTERS" ]; then
    V=ok; LAST_OK=$TOTAL
  else
    V=BROKE
  fi
  echo "   scrape=${DUR}s up=$UP/$EXPORTERS -> $V"
  echo "$TOTAL,$PE,$HEAD,$DUR,$UP,$MEM,$V" >> "$OUT"
  [ "$V" = BROKE ] && break
done
echo "last healthy: $LAST_OK params -> $OUT"
