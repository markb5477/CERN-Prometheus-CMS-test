#!/usr/bin/env bash
# Hold a fixed load and sample over time; watch for memory creep or scrape drift.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

EXPORTERS=${EXPORTERS:-80}
TOTAL=${TOTAL:-1000000}
DURATION=${DURATION:-1800}   # seconds
SAMPLE=${SAMPLE:-30}
OUT="$RESULTS/soak.csv"
PE=$((TOTAL / EXPORTERS))

write_config "$EXPORTERS"
stop_all; rm -rf "$DATA/tsdb"
start_exporters "$EXPORTERS" "$PE"; start_prometheus
echo "holding $TOTAL params for ${DURATION}s"
echo "elapsed_s,head_series,max_scrape_s,targets_up,memory_bytes" > "$OUT"
sleep "$SETTLE"
START=$(date +%s)
while :; do
  NOW=$(($(date +%s) - START))
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="client"})')
  UP=$(prom 'count(up{job="client"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  echo "   t=${NOW}s head=$HEAD scrape=${DUR}s up=$UP mem=$MEM"
  echo "$NOW,$HEAD,$DUR,$UP,$MEM" >> "$OUT"
  [ "$NOW" -ge "$DURATION" ] && break
  sleep "$SAMPLE"
done
echo "-> $OUT"
