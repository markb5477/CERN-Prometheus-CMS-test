#!/usr/bin/env bash
# Functional-sharding test (DIST mode). The full target set is split into K disjoint
# shards, one Prometheus per shard, with the load on separate machine(s). Sweeping K shows
# per-node series (and scrape time / CPU) falling as ~1/K, which is what lets you size
#   shards = total / (C x 0.55)   (DESIGN.md 4).
# Ideal is one shard per collector host; if K exceeds the collector count, extra shards
# run as separate instances on distinct ports of a reused host (flagged: CPU contention).
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
require_ssh "${LOAD_ARR[@]}" "${COLL_ARR[@]}"

read -ra KS <<< "${SHARD_SET:-1 2 4 8}"
NC=${#COLL_ARR[@]}
OUT="$DATA/shard.csv"
mkdir -p "$NATIVE"
echo "shards,shard_index,host,port,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"

stop_fleet() { for h in "${LOAD_ARR[@]}" "${COLL_ARR[@]}"; do
  rsh "$h" "$REMOTE_ROOT/scripts/avalanche/stop.sh; $REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true; done; }
trap stop_fleet EXIT

echo "shard sweep: $MODULES real boards (180 OT + 50 IT), $TOTAL params, K in {${KS[*]}}"
stop_fleet

# generators up once (full real mixed load, stable across the whole sweep); each load host
# gets its contiguous block of boards with the real per-board series counts (OT vs IT).
NH=${#LOAD_ARR[@]}; PER=$(( (MODULES + NH - 1) / NH ))
gen_series "$MODULES" > "$NATIVE/all-series.txt"
for ((h=0; h<NH; h++)); do
  cnt=$(( MODULES - h*PER )); [ "$cnt" -gt "$PER" ] && cnt=$PER; [ "$cnt" -le 0 ] && break
  series=$(sed -n "$((h*PER+1)),$((h*PER+cnt))p" "$NATIVE/all-series.txt" | tr '\n' ' ')
  rsh "${LOAD_ARR[$h]}" "$REMOTE_ROOT/scripts/avalanche/start.sh $BASE_PORT $series"
done
gen_targets "$MODULES" > "$NATIVE/all-targets.txt"

for K in "${KS[@]}"; do
  echo ">> shards=$K"
  [ "$K" -gt "$NC" ] && echo "   NOTE: $K shards on $NC collector host(s) -> co-locating instances (CPU contention; not a clean per-node number)"
  # reset collectors between K-steps; leave generators running
  for h in "${COLL_ARR[@]}"; do rsh "$h" "$REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true; done
  per_shard=$(( (MODULES + K - 1) / K ))
  WORK="$NATIVE/shard-work"; rm -rf "$WORK"; mkdir -p "$WORK"; pids=()
  for ((j=0; j<K; j++)); do
    start=$(( j*per_shard )); [ "$start" -ge "$MODULES" ] && break
    cnt=$(( MODULES - start )); [ "$cnt" -gt "$per_shard" ] && cnt=$per_shard
    host=${COLL_ARR[$(( j % NC ))]}; port=$(( PROM_PORT + j / NC ))
    sed -n "$((start+1)),$((start+cnt))p" "$NATIVE/all-targets.txt" \
      | PROM_PORT=$port "$CFG/gen_prom_config.sh" > "$NATIVE/shard-$K-$j.yml"
    scp_pass "$NATIVE/shard-$K-$j.yml" "$SSH_USER@$host:$REMOTE_ROOT/.native-data/shard-$K-$j.yml" >/dev/null
    rsh "$host" "mkdir -p $REMOTE_ROOT/.native-data; PROM_PORT=$port $REMOTE_ROOT/scripts/prometheus/start.sh $REMOTE_ROOT/.native-data/shard-$K-$j.yml $port"
    ( row=$(rsh "$host" "PROM_URL=http://localhost:$port $REMOTE_ROOT/scripts/prometheus/measure.sh s"); \
      echo "$K,$j,$host,$port,$cnt,${row#*,}" > "$WORK/$j" ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  for f in "$WORK"/*; do cat "$f" >> "$OUT"; echo "   $(cat "$f")"; done
done
echo "-> $OUT"
