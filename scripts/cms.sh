#!/usr/bin/env bash
# CMS Tracker monitoring model at 1 Hz.
# Real parameter counts spread across DTC aggregators, which are the scrape targets.
#   grow: fix the DTC-aggregator topology, raise total parameters (finer sampling / detector growth).
#   agg:  fix the full parameter count, coarsen the aggregation (fewer, fatter targets).
source "$(dirname "$0")/_common.sh"
trap stop_all EXIT

# Parameter budget from the design note (Monitoring DB, section 4).
IT_CHIP=$((14088 * 35))   # IT ASIC, 35 per CROC
IT_MOD=$((4416 * 12))     # IT module level
IT_INFRA=19000            # port-card, cooling, HV, serial-power blocks
OT_MOD=$((15000 * 20))    # OT module level
OT_BOARD=$((150 * 100))   # OT board level
BASE=$((IT_CHIP + IT_MOD + IT_INFRA + OT_MOD + OT_BOARD))  # ~880k
DTCS=${DTCS:-316}         # per-DTC aggregators = scrape targets

read -ra GROW <<< "${GROW:-880000 1000000 1500000 2000000 2500000}"
read -ra AGG  <<< "${AGG:-316 158 79 40 20 8}"
LAST_AV=99

# $1 targets, $2 total series, $3 leading key, $4 output file.
measure() {
  local n=$1 pe=$(($2 / $1)) head dur up mem av
  stop_all; rm -rf "$DATA/tsdb"; write_config "$n"
  start_exporters "$n" "$pe"; start_prometheus; sleep "$SETTLE"
  head=$(prom 'prometheus_tsdb_head_series')
  dur=$(prom 'max(scrape_duration_seconds{job="client"})')
  up=$(prom 'count(up{job="client"} == 1)')
  mem=$(prom 'process_resident_memory_bytes{job="server"}')
  av=$(avail_gb)
  echo "   per_target=$pe head=$head scrape=${dur}s up=$up/$n mem=$mem avail=${av}g"
  echo "$3,$pe,$head,$dur,$up,$mem,$av" >> "$4"
  LAST_AV=${av:-99}
}

echo "model: $BASE params, $DTCS DTC aggregators, $((BASE / DTCS)) params per aggregator"

G="$RESULTS/cms_grow.csv"
echo "params,per_target,head_series,max_scrape_s,targets_up,memory_bytes,host_avail_gb" > "$G"
for T in "${GROW[@]}"; do
  echo ">> grow: $T params / $DTCS aggregators = $((T / DTCS)) per target"
  measure "$DTCS" "$T" "$T" "$G"
  [ "$LAST_AV" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done

A="$RESULTS/cms_agg.csv"
echo "targets,per_target,head_series,max_scrape_s,targets_up,memory_bytes,host_avail_gb" > "$A"
for N in "${AGG[@]}"; do
  echo ">> agg: $BASE params / $N aggregators = $((BASE / N)) per target"
  measure "$N" "$BASE" "$N" "$A"
  [ "$LAST_AV" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low, stopping"; break; }
done
echo "-> $G  $A"
