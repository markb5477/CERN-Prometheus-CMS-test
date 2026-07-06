#!/usr/bin/env bash
# Hold the total fixed, vary the number of targets. Shows the limit is series-per-target, not the total.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

TOTAL=${TOTAL:-2000000}
read -ra FANOUTS <<< "${FANOUTS:-1 2 5 10 20 40 80 160}"
OUT="$RESULTS/sweep.csv"

echo "exporters,per_exporter,head_series,max_scrape_s,targets_up,memory_bytes,host_avail_gb" > "$OUT"
for N in "${FANOUTS[@]}"; do
  PE=$((TOTAL / N))
  echo ">> $N x $PE = $TOTAL"
  stop_all; rm -rf "$DATA/tsdb"; write_config "$N"
  start_exporters "$N" "$PE"; start_prometheus; sleep "$SETTLE"
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="client"})')
  UP=$(prom 'count(up{job="client"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  AV=$(avail_gb)
  echo "   head=$HEAD scrape=${DUR}s up=$UP/$N mem=$MEM"
  echo "$N,$PE,$HEAD,$DUR,$UP,$MEM,$AV" >> "$OUT"
  [ "${AV:-9}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $OUT"
