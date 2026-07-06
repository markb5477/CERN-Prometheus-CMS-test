#!/usr/bin/env bash
# Hold the total fixed, vary the number of modules. Shows the limit is parameters-per-module, not the total.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

TOTAL=${TOTAL:-2000000}
read -ra FANOUTS <<< "${FANOUTS:-1 2 5 10 20 40 80 160}"
OUT="$RESULTS/sweep.csv"

echo "modules,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb" > "$OUT"
for N in "${FANOUTS[@]}"; do
  PM=$((TOTAL / N))
  echo ">> $N modules x $PM parameters = $TOTAL"
  stop_all; rm -rf "$DATA/tsdb"; write_config "$N"
  start_modules "$N" "$PM"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$N mem=$MEM"
  echo "$N,$PM,$HEAD,$DUR,$UP,$MEM,$AV" >> "$OUT"
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
