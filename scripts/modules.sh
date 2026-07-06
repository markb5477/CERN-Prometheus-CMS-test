#!/usr/bin/env bash
# Module ramp: fixed number of modules, total parameters raised step by step.
# Records scrape time and modules up at each step.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

MODULES=${MODULES:-25}
read -ra TOTALS <<< "${TOTALS:-200000 400000 600000 700000 800000 850000 900000 950000 1000000 1050000 1100000 1150000 1200000}"
OUT="$RESULTS/modules.csv"

write_config "$MODULES"
echo "params,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb" > "$OUT"
for TOTAL in "${TOTALS[@]}"; do
  PM=$(( TOTAL / MODULES ))
  echo ">> $TOTAL params = $MODULES modules x $PM parameters"
  stop_all; rm -rf "$DATA/tsdb"
  start_modules "$MODULES" "$PM"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$MODULES mem=$MEM avail=${AV}g"
  echo "$TOTAL,$PM,$HEAD,$DUR,$UP,$MEM,$AV" >> "$OUT"
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
