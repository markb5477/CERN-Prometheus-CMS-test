#!/usr/bin/env bash
# Hold ONE scale and watch both sides in real time, instead of taking a single settled
# snapshot like ramp_dist.sh. Built to answer "what is the wall?" when a ramp step degrades
# but neither node looks saturated: each tick reports collector NIC throughput, Prometheus
# CPU, live target health and real ingest rate, alongside the generator's own footprint.
#
# The fleet stays up for the whole run (no teardown race), so the picture is of the system
# actually degrading rather than of its aftermath.
#
# Usage:  ./scenarios/diag.sh [scale]           # default 1 (the real 880k-param detector)
#         SAMPLES=20 STEP=5 ./scenarios/diag.sh 1
#         KEEP=1 ./scenarios/diag.sh 1          # leave prometheus up afterwards to poke at
# NIC=<iface> overrides the collector interface if autodetection picks the wrong one.
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
require_ssh "${LOAD_ARR[@]}" "${COLL_ARR[@]}"

S=${1:-1}
SAMPLES=${SAMPLES:-12}
STEP=${STEP:-5}
COLL=${COLL_ARR[0]}

OT=$(awk -v b="$OT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
IT=$(awk -v b="$IT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))

stop_fleet() {
  for h in "${LOAD_ARR[@]}"; do rsh "$h" "$REMOTE_ROOT/scripts/avalanche/stop.sh" >/dev/null 2>&1 || true; done
  [ "${KEEP:-0}" = 1 ] || rsh "$COLL" "$REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true
}
trap stop_fleet EXIT

echo "diag: scale=$S -> $OT OT + $IT IT = $N targets / $P params"
echo "      collector=$COLL  load=[${LOAD_ARR[*]}]  ${SAMPLES}x${STEP}s"

stop_fleet
# same board ordering as gen_targets: OT boards first, then IT
{ for ((i=0;i<OT;i++)); do echo "$OT_PER_BOARD"; done
  for ((i=0;i<IT;i++)); do echo "$IT_PER_BOARD"; done; } > "$NATIVE/diag-series.txt"
nh=${#LOAD_ARR[@]}; per=$(( (N + nh - 1) / nh ))
for ((h=0; h<nh; h++)); do
  cnt=$(( N - h*per )); [ "$cnt" -gt "$per" ] && cnt=$per; [ "$cnt" -le 0 ] && break
  series=$(sed -n "$((h*per+1)),$((h*per+cnt))p" "$NATIVE/diag-series.txt" | tr '\n' ' ')
  rsh "${LOAD_ARR[$h]}" "$REMOTE_ROOT/scripts/avalanche/start.sh $BASE_PORT $series" >/dev/null
done

gen_targets "$N" | "$CFG/gen_prom_config.sh" > "$NATIVE/diag.yml"
scp_pass "$NATIVE/diag.yml" "$SSH_USER@$COLL:$REMOTE_ROOT/.native-data/diag.yml" >/dev/null
rsh "$COLL" "mkdir -p $REMOTE_ROOT/.native-data; ${REMOTE_TSDB:+TSDB_ROOT=$REMOTE_TSDB} \
  $REMOTE_ROOT/scripts/prometheus/start.sh $REMOTE_ROOT/.native-data/diag.yml $PROM_PORT" >/dev/null

echo "--- t  collector ---------------------------------------------------- | load ---"
for ((k=1; k<=SAMPLES; k++)); do
  c=$(rsh "$COLL" "${NIC:+NIC=$NIC} PROM_URL=http://localhost:$PROM_PORT \
        $REMOTE_ROOT/scripts/prometheus/diag_sample.sh $STEP" 2>/dev/null)
  l=$(rsh "${LOAD_ARR[0]}" "PROC_WIN=1 $REMOTE_ROOT/scripts/avalanche/measure.sh" 2>/dev/null)
  IFS=, read -r acpu arss hcpu _ avail procs <<< "$l"
  printf "%4ds %s | av=%s%% host=%s%% procs=%s\n" \
    "$((k*STEP))" "$c" "${acpu:-?}" "${hcpu:-?}" "${procs:-?}"
done

[ "${KEEP:-0}" = 1 ] && echo "prometheus left up on $COLL:$PROM_PORT (KEEP=1)"
