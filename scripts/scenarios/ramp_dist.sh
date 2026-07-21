#!/usr/bin/env bash
# Distributed scaling ramp (DIST mode) - the HPC version of scenarios/baseline/pretest.sh.
# Prometheus runs ALONE on the collector node (its CPU/RAM are the true per-node footprint);
# the load is generated on separate node(s). At each scale we ramp the real OT:IT mix, start a
# fresh isolated Prometheus, and measure BOTH sides:
#   * collector (prometheus/measure.sh) - scrape health, per-node CPU/RAM, storage, bytes/sample
#   * every load node (avalanche/measure.sh) - generator CPU/RAM + host saturation
#
# Why measure the load node: on the HPC the collector is fast, so the first thing to give out is
# usually the GENERATOR. A saturated load node starves Prometheus and fakes a ceiling. So we
# label each step:
#   ok | prom_cadence_slip | prom_scrape_over | prom_targets_dropped | LOAD_SATURATED
# A prom_* status at the top (load healthy) is a REAL Prometheus ceiling. LOAD_SATURATED means
# "add load nodes (LOAD_HOSTS fan-out) and re-run" - it is NOT Prometheus's limit.
#
# Usage: fill scripts/config/secrets.env (SSHPASS + hosts), run config/stage.sh once, then:
#   SCALES="0.5 1 2 3 4" ./scenarios/ramp_dist.sh      # coarse: find the upper bound
#   SCALES="0.8 0.9 1.0 1.1 1.2" ./scenarios/ramp_dist.sh   # fine: scaling near real load
# REMOTE_TSDB=/tmp/prom-tsdb points the collector TSDB at node-local scratch (do this on the HPC;
# never Lustre/GPFS/NFS). LOAD_SAT_CPU / LOAD_SAT_GB tune the load-saturation thresholds.
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
[ -z "${SSHPASS:-}" ] && { echo "fill scripts/config/secrets.env first (SSHPASS + hosts)" >&2; exit 1; }

SCALES=${SCALES:-"0.5 1 2 3"}          # fractions of the real detector (150 OT + 50 IT = 880k)
LOAD_SAT_CPU=${LOAD_SAT_CPU:-90}       # a load host above this %CPU is saturated -> ceiling is the generator
LOAD_SAT_GB=${LOAD_SAT_GB:-2}          # ...or below this GB available
COLL=${COLL_ARR[0]}                    # single isolated Prometheus node for the ceiling test
OUT="$DATA/ramp_dist.csv"
mkdir -p "$NATIVE"

echo "scale,ot,it,targets,params,head_series,max_scrape_s,modules_up,cadence_p99_s,memory_bytes,cpu_pct,ram_pct,block_bytes,head_bytes,wal_bytes,disk_bytes,samples_appended,bytes_per_sample,load_av_cpu,load_av_rss,load_host_cpu,load_avail_gb,status" > "$OUT"

stop_fleet() {
  for h in "${LOAD_ARR[@]}"; do rsh "$h" "$REMOTE_ROOT/scripts/avalanche/stop.sh" >/dev/null 2>&1 || true; done
  rsh "$COLL" "$REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true
}
trap stop_fleet EXIT

# launch the generator fleet for <ot> OT + <it> IT boards, spread contiguously across LOAD_ARR
# in the SAME order gen_targets places them (OT boards first, then IT).
launch_load() {
  local ot=$1 it=$2 n=$((ot+it)) nh=${#LOAD_ARR[@]} per h cnt series
  { for ((i=0;i<ot;i++)); do echo "$OT_PER_BOARD"; done
    for ((i=0;i<it;i++)); do echo "$IT_PER_BOARD"; done; } > "$NATIVE/ramp-series.txt"
  per=$(( (n + nh - 1) / nh ))
  for ((h=0; h<nh; h++)); do
    cnt=$(( n - h*per )); [ "$cnt" -gt "$per" ] && cnt=$per; [ "$cnt" -le 0 ] && break
    series=$(sed -n "$((h*per+1)),$((h*per+cnt))p" "$NATIVE/ramp-series.txt" | tr '\n' ' ')
    rsh "${LOAD_ARR[$h]}" "$REMOTE_ROOT/scripts/avalanche/start.sh $BASE_PORT $series" >/dev/null
  done
}

# measure every load host; echo aggregate "sum_av_cpu,sum_av_rss,max_host_cpu,min_avail_gb"
measure_load() {
  local h row acpu=0 arss=0 hcpu=0 avail=9999 a b c d e f
  for h in "${LOAD_ARR[@]}"; do
    row=$(rsh "$h" "PROC_WIN=${PROC_WIN:-3} $REMOTE_ROOT/scripts/avalanche/measure.sh" 2>/dev/null)
    IFS=, read -r a b c d e f <<< "$row"          # av_cpu,av_rss,host_cpu,host_ram_used,avail,procs
    acpu=$(awk -v x="$acpu" -v y="${a:-0}" 'BEGIN{print x+y}')
    arss=$(( arss + ${b:-0} ))
    awk "BEGIN{exit !(${c:-0} > $hcpu)}" && hcpu=${c:-0}
    [ "${e:-9999}" -lt "$avail" ] && avail=${e:-9999}
  done
  echo "$acpu,$arss,$hcpu,$avail"
}

echo "DIST ramp: collector=$COLL  load=[${LOAD_ARR[*]}]  scales=[$SCALES]"
for S in $SCALES; do
  OT=$(awk -v b="$OT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  IT=$(awk -v b="$IT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  echo ">> scale=$S : $OT OT + $IT IT = $N targets / $P params"

  stop_fleet
  launch_load "$OT" "$IT"
  gen_targets "$N" | "$CFG/gen_prom_config.sh" > "$NATIVE/ramp.yml"
  scp_pass "$NATIVE/ramp.yml" "$SSH_USER@$COLL:$REMOTE_ROOT/.native-data/ramp.yml" >/dev/null
  rsh "$COLL" "mkdir -p $REMOTE_ROOT/.native-data; ${REMOTE_TSDB:+TSDB_ROOT=$REMOTE_TSDB} $REMOTE_ROOT/scripts/prometheus/start.sh $REMOTE_ROOT/.native-data/ramp.yml $PROM_PORT" >/dev/null

  # collector row (measure.sh sleeps SETTLE internally, then samples once)
  CROW=$(rsh "$COLL" "PROM_URL=http://localhost:$PROM_PORT $REMOTE_ROOT/scripts/prometheus/measure.sh s$S")
  IFS=, read -r _L HEAD DUR UP MEM CAV CPU RAM CAD BB HB WB DISK SA BPS <<< "$CROW"
  IFS=, read -r LCPU LRSS LHCPU LAVAIL <<< "$(measure_load)"

  STATUS=ok
  awk "BEGIN{exit !(${CAD:-0} > 1.05)}" && STATUS=prom_cadence_slip
  awk "BEGIN{exit !(${DUR:-0} > 1.0)}"  && STATUS=prom_scrape_over
  [ "${UP:-0}" -lt "$N" ] && STATUS=prom_targets_dropped
  # load-side override: a saturated generator invalidates the collector reading
  awk "BEGIN{exit !(${LHCPU:-0} > $LOAD_SAT_CPU)}" && STATUS=LOAD_SATURATED
  [ "${LAVAIL:-9999}" -lt "$LOAD_SAT_GB" ] && STATUS=LOAD_SATURATED

  echo "   coll: up=$UP/$N scrape=${DUR}s cad=${CAD}s cpu=${CPU}% ram=${RAM}% bps=${BPS} | load: av=${LCPU}%cpu host=${LHCPU}%cpu avail=${LAVAIL}g [$STATUS]"
  echo "$S,$OT,$IT,$N,$P,$HEAD,$DUR,$UP,$CAD,$MEM,$CPU,$RAM,$BB,$HB,$WB,$DISK,$SA,$BPS,$LCPU,$LRSS,$LHCPU,$LAVAIL,$STATUS" >> "$OUT"

  case "$STATUS" in
    prom_targets_dropped) echo "   PROMETHEUS CEILING (targets dropped, load healthy) - stopping"; break;;
    LOAD_SATURATED) echo "   LOAD-NODE bottleneck, not Prometheus - add load hosts to LOAD_HOSTS and re-run"; break;;
  esac
done
stop_fleet
echo "-> $OUT"
