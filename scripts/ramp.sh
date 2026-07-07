#!/usr/bin/env bash
# Ramp total parameters up at 1 Hz; find where a scrape first exceeds the 1 s budget.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

MODULES=${MODULES:-80}
read -ra STEPS <<< "${STEPS:-200000 400000 600000 800000 1000000 1200000 1400000 1600000 1800000 2000000}"
OUT="$RESULTS/ramp.csv"

write_config "$MODULES"
echo "params,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct" > "$OUT"
for TOTAL in "${STEPS[@]}"; do
  PM=$((TOTAL / MODULES))
  echo ">> $TOTAL params = $MODULES modules x $PM parameters"
  stop_all; rm -rf "$DATA/tsdb"
  start_modules "$MODULES" "$PM"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  CPU=$(cpu_pct); RAM=$(ram_pct)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$MODULES mem=$MEM cpu=${CPU}% ram=${RAM}% avail=${AV}g"
  echo "$TOTAL,$PM,$HEAD,$DUR,$UP,$MEM,$AV,$CPU,$RAM" >> "$OUT"
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
