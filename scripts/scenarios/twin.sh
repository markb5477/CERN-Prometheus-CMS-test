#!/usr/bin/env bash
# Twin-node HA test (DIST mode). Two collector nodes each scrape the FULL target set as
# independent Prometheus replicas, while the load lives on separate machine(s). Confirms
# each replica independently sustains the full load at 1 Hz with generator-free CPU/RAM
# -> validates the "1 primary + 1 hot standby" topology (DESIGN.md 4).
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
[ -z "${SSHPASS:-}" ] && { echo "fill scripts/config/secrets.env first" >&2; exit 1; }
[ "${#COLL_ARR[@]}" -lt 2 ] && echo "NOTE: <2 collector hosts configured; both replicas will share a host (CPU contention)."

OUT="$DATA/twin.csv"
mkdir -p "$NATIVE"
echo "replica,host,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"

stop_fleet() { for h in "${LOAD_ARR[@]}" "${COLL_ARR[@]}"; do
  rsh "$h" "$REMOTE_ROOT/scripts/avalanche/stop.sh; $REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true; done; }
trap stop_fleet EXIT

echo "twin: $MODULES real boards (180 OT + 50 IT), $TOTAL params, full set to each replica"
stop_fleet

# 1. generators: each load host gets its contiguous block of boards, launched with the real
#    per-board series counts (OT vs IT) for its slice.
NH=${#LOAD_ARR[@]}; PER=$(( (MODULES + NH - 1) / NH ))
gen_series "$MODULES" > "$NATIVE/twin-series.txt"
for ((h=0; h<NH; h++)); do
  cnt=$(( MODULES - h*PER )); [ "$cnt" -gt "$PER" ] && cnt=$PER; [ "$cnt" -le 0 ] && break
  series=$(sed -n "$((h*PER+1)),$((h*PER+cnt))p" "$NATIVE/twin-series.txt" | tr '\n' ' ')
  rsh "${LOAD_ARR[$h]}" "$REMOTE_ROOT/scripts/avalanche/start.sh $BASE_PORT $series"
done

# 2. full target list -> identical replicas. Regenerate per replica so the "server"
#    self-scrape target follows each instance's port (matters if replicas share a host).
gen_targets "$MODULES" > "$NATIVE/twin-targets.txt"

# choose up to 2 collectors (reuse the single host if only one is configured)
REPS=("${COLL_ARR[@]:0:2}"); [ "${#REPS[@]}" -lt 2 ] && REPS=("${COLL_ARR[0]}" "${COLL_ARR[0]}")

# 3. start each replica, then measure both concurrently (each does its own SETTLE)
WORK="$NATIVE/twin-work"; rm -rf "$WORK"; mkdir -p "$WORK"; pids=()
i=1
for h in "${REPS[@]}"; do
  port=$(( PROM_PORT + i - 1 ))   # distinct ports so two replicas can share one host
  PROM_PORT=$port "$CFG/gen_prom_config.sh" < "$NATIVE/twin-targets.txt" > "$NATIVE/twin-$i.yml"
  scp_pass "$NATIVE/twin-$i.yml" "$SSH_USER@$h:$REMOTE_ROOT/.native-data/twin-$i.yml" >/dev/null
  rsh "$h" "mkdir -p $REMOTE_ROOT/.native-data; PROM_PORT=$port $REMOTE_ROOT/scripts/prometheus/start.sh $REMOTE_ROOT/.native-data/twin-$i.yml $port"
  ( row=$(rsh "$h" "PROM_URL=http://localhost:$port $REMOTE_ROOT/scripts/prometheus/measure.sh r"); \
    echo "$i,$h,${row#*,}" > "$WORK/$i" ) &
  pids+=($!); i=$((i+1))
done
wait "${pids[@]}" 2>/dev/null || true
for f in "$WORK"/*; do cat "$f" >> "$OUT"; echo "   $(cat "$f")"; done
echo "-> $OUT"
