#!/usr/bin/env bash
# Hold a fixed load and sample over time; watch for memory creep or scrape drift.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

MODULES=${MODULES:-80}
TOTAL=${TOTAL:-1000000}
DURATION=${DURATION:-1800}   # seconds
SAMPLE=${SAMPLE:-30}
OUT="$RESULTS/soak.csv"
PM=$((TOTAL / MODULES))

write_config "$MODULES"
stop_all; rm -rf "$DATA/tsdb"
start_modules "$MODULES" "$PM"; start_prometheus
echo "holding $TOTAL params for ${DURATION}s"
echo "elapsed_s,head_series,max_scrape_s,modules_up,memory_bytes,cpu_pct,ram_pct" > "$OUT"
sleep "$SETTLE"
START=$(date +%s)
while :; do
  NOW=$(($(date +%s) - START))
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  CPU=$(cpu_pct); RAM=$(ram_pct)
  echo "   t=${NOW}s head=$HEAD scrape=${DUR}s up=$UP mem=$MEM cpu=${CPU}% ram=${RAM}% avail=${AV}g"
  echo "$NOW,$HEAD,$DUR,$UP,$MEM,$CPU,$RAM" >> "$OUT"
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low (${AV}g), stopping"; break; }
  [ "$NOW" -ge "$DURATION" ] && break
  sleep "$SAMPLE"
done
echo "-> $OUT"
