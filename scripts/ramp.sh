#!/usr/bin/env bash
# Ramp total parameters up at 1 Hz; find where a scrape first exceeds the 1 s budget.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

EXPORTERS=${EXPORTERS:-80}
read -ra STEPS <<< "${STEPS:-200000 400000 600000 800000 1000000 1200000 1400000 1600000 1800000 2000000}"
OUT="$RESULTS/ramp.csv"

write_config "$EXPORTERS"
echo "params,per_exporter,head_series,max_scrape_s,targets_up,memory_bytes,host_avail_gb" > "$OUT"
for TOTAL in "${STEPS[@]}"; do
  PE=$((TOTAL / EXPORTERS))
  echo ">> $TOTAL params = $EXPORTERS x $PE"
  stop_all; rm -rf "$DATA/tsdb"
  start_exporters "$EXPORTERS" "$PE"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="client"})')
  UP=$(prom 'count(up{job="client"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$EXPORTERS mem=$MEM avail=${AV}g"
  echo "$TOTAL,$PE,$HEAD,$DUR,$UP,$MEM,$AV" >> "$OUT"
  [ "${AV:-9}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
