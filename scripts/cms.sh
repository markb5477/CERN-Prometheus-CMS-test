#!/usr/bin/env bash
# CMS Tracker monitoring model at 1 Hz.
# Real parameter counts spread across modules (the per-DTC aggregation points Prometheus scrapes).
#   grow: fix the module topology, raise total parameters (finer sampling / detector growth).
#   agg:  fix the full parameter count, coarsen the modules (fewer, fatter).
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

# Parameter budget from the design note (Monitoring DB, section 4).
IT_CHIP=$((14088 * 35))   # IT ASIC, 35 per CROC
IT_MOD=$((4416 * 12))     # IT module level
IT_INFRA=19000            # port-card, cooling, HV, serial-power blocks
OT_MOD=$((15000 * 20))    # OT module level
OT_BOARD=$((150 * 100))   # OT board level
BASE=$((IT_CHIP + IT_MOD + IT_INFRA + OT_MOD + OT_BOARD))  # ~880k
MODULES=${MODULES:-316}   # per-DTC aggregation points = what Prometheus scrapes

read -ra GROW <<< "${GROW:-880000 1000000 1500000 2000000 2500000}"
read -ra AGG  <<< "${AGG:-316 158 79 40 20 8}"
LAST_AV=99

# $1 modules, $2 total parameters, $3 leading key, $4 output file.
measure() {
  local n=$1 pm=$(($2 / $1)) head dur up mem av cpu ram
  stop_all; rm -rf "$DATA/tsdb"; write_config "$n"
  start_modules "$n" "$pm"; start_prometheus; sleep "$SETTLE"
  head=$(prom 'prometheus_tsdb_head_series')
  dur=$(prom 'max(scrape_duration_seconds{job="modules"})')
  up=$(prom 'count(up{job="modules"} == 1)')
  mem=$(prom 'process_resident_memory_bytes{job="server"}')
  av=$(avail_gb)
  cpu=$(cpu_pct); ram=$(ram_pct)
  echo "   params_per_module=$pm head=$head scrape=${dur}s up=$up/$n mem=$mem cpu=${cpu}% ram=${ram}% avail=${av}g"
  echo "$3,$pm,$head,$dur,$up,$mem,$av,$cpu,$ram" >> "$4"
  LAST_AV=${av:-99}
}

echo "model: $BASE params, $MODULES modules, $((BASE / MODULES)) params per module"

G="$RESULTS/cms_grow.csv"
echo "params,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct" > "$G"
for T in "${GROW[@]}"; do
  echo ">> grow: $T params / $MODULES modules = $((T / MODULES)) per module"
  measure "$MODULES" "$T" "$T" "$G"
  [ "$LAST_AV" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done

A="$RESULTS/cms_agg.csv"
echo "modules,params_per_module,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct" > "$A"
for N in "${AGG[@]}"; do
  echo ">> agg: $BASE params / $N modules = $((BASE / N)) per module"
  measure "$N" "$BASE" "$N" "$A"
  [ "$LAST_AV" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $G  $A"
