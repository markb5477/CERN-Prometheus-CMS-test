#!/usr/bin/env bash
# Baseline -> sudden 2M -> baseline on a running server; measure the hit and recovery.
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

MODULES=${MODULES:-80}
BASELINE=${BASELINE:-400000}
SPIKE=${SPIKE:-2000000}
HOLD=${HOLD:-60}
OUT="$RESULTS/spike.csv"

write_config "$MODULES"
echo "phase,params,head_series,max_scrape_s,modules_up,memory_bytes,cpu_pct,ram_pct" > "$OUT"
stop_all; rm -rf "$DATA/tsdb"; start_prometheus   # server stays up; only the load changes

phase() {   # $1 = label, $2 = total params
  pkill -x avalanche 2>/dev/null; sleep 1
  start_modules "$MODULES" $(($2 / MODULES)); sleep "$HOLD"
  local HEAD DUR UP MEM CPU RAM
  HEAD=$(prom 'prometheus_tsdb_head_series')
  DUR=$(prom 'max(scrape_duration_seconds{job="modules"})')
  UP=$(prom 'count(up{job="modules"} == 1)')
  MEM=$(prom 'process_resident_memory_bytes{job="server"}')
  CPU=$(cpu_pct); RAM=$(ram_pct)
  echo "   [$1] $2: scrape=${DUR}s up=$UP/$MODULES mem=$MEM cpu=${CPU}% ram=${RAM}%"
  echo "$1,$2,$HEAD,$DUR,$UP,$MEM,$CPU,$RAM" >> "$OUT"
}
phase baseline_before "$BASELINE"
phase spike           "$SPIKE"
phase baseline_after  "$BASELINE"
echo "-> $OUT"
