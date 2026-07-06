#!/usr/bin/env bash
# Sensor ramp: PARAMS_PER_SENSOR series per sensor, spread across EXPORTERS targets.
# Steps total parameters over TOTALS and records scrape time / targets up at each step.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

EXPORTERS=${EXPORTERS:-25}
PARAMS_PER_SENSOR=${PARAMS_PER_SENSOR:-35}
read -ra TOTALS <<< "${TOTALS:-200000 400000 600000 700000 800000 850000 900000 950000 1000000 1050000 1100000 1150000 1200000}"
OUT="$RESULTS/sensors.csv"

write_config "$EXPORTERS"
echo "params,sensors,per_exporter,head_series,max_scrape_s,targets_up,memory_bytes,host_avail_gb" > "$OUT"
for TOTAL in "${TOTALS[@]}"; do
  SENSORS=$(( TOTAL / PARAMS_PER_SENSOR ))
  PE=$(( TOTAL / EXPORTERS ))
  echo ">> $TOTAL params = $SENSORS sensors x $PARAMS_PER_SENSOR = $EXPORTERS boards x $PE series"
  stop_all; rm -rf "$DATA/tsdb"
  start_exporters "$EXPORTERS" "$PE"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="client"})')
  UP=$(prom 'count(up{job="client"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$EXPORTERS mem=$MEM avail=${AV}g"
  echo "$TOTAL,$SENSORS,$PE,$HEAD,$DUR,$UP,$MEM,$AV" >> "$OUT"
  [ "${AV:-9}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
