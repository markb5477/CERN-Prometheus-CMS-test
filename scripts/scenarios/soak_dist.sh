#!/usr/bin/env bash
# Distributed soak (DIST mode) - the HPC version of scenarios/baseline/soak.sh, and pilot step 3.
# Holds ONE scale (default the real 880k-param detector) at 1 Hz for DURATION and samples both
# sides on a fixed cadence. Prometheus runs ALONE on the collector, load on separate node(s).
#
# WHY THIS EXISTS - what a ramp structurally cannot measure:
#   * RAM. ramp_dist.sh reads memory $SETTLE (45s) after start, when the head block holds ~45
#     samples per series. The head accumulates for a full block period before it is cut, so the
#     ramp's RAM figure is a FLOOR, not the steady state. Only a soak walks that curve.
#   * DISK. bytes_per_sample from a ramp is (blocks+head+wal)/samples with nothing compacted
#     yet, so it is almost entirely WAL - which is why it reads ~7.0 at every scale regardless
#     of load. The trustworthy number is delta(block_bytes)/delta(samples_appended) ACROSS a
#     compaction, and a compaction only happens in a run long enough to cut a block.
#
# BLOCK DURATION - the one knob that decides what this run can answer:
#   default (no MIN_BLOCK): Prometheus cuts its first block at 2h. DURATION must exceed that
#     (use ~9000s) but you get BOTH the true head-RAM curve and a real compaction. Definitive.
#   MIN_BLOCK=15m: forces block cuts every 15 min, so compaction is exercised inside an hour.
#     Disk numbers stay representative (at 1 Hz a chunk fills every 120 samples = 2 min, so a
#     15m block still holds full, fully-compressed chunks) but RAM is NOT - the head never grows
#     past 15 minutes of data. Use this to validate the harness, not to size memory.
#
# Usage: config/login.sh + config/stage.sh first, then:
#   MIN_BLOCK=15m DURATION=3600 REMOTE_TSDB=/tmp/prom-tsdb ./scenarios/soak_dist.sh     # 1h shakeout
#   DURATION=9000 REMOTE_TSDB=/tmp/prom-tsdb ./scenarios/soak_dist.sh                   # definitive
#   SCALE=1.2 ./scenarios/soak_dist.sh          # soak above the real detector
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
require_ssh "${LOAD_ARR[@]}" "${COLL_ARR[@]}"

SCALE=${SCALE:-1}
DURATION=${DURATION:-9000}      # seconds; must exceed one block period to see a compaction
SAMPLE=${SAMPLE:-30}            # seconds between rows; >= WIN so windowed queries never overlap
MIN_BLOCK=${MIN_BLOCK:-}
RETENTION=${RETENTION:-}
READY_TIMEOUT=${READY_TIMEOUT:-300}
COLL=${COLL_ARR[0]}
OUT="$DATA/soak_dist.csv"
mkdir -p "$NATIVE"
# Archive any previous run instead of truncating it: a soak costs hours, and the disk run
# (MIN_BLOCK) and RAM run (default blocks) answer different questions - losing either to the
# next invocation would mean running it again. Timestamp comes from the old file's mtime.
[ -f "$OUT" ] && mv "$OUT" "${OUT%.csv}-$(date -r "$OUT" +%Y%m%d-%H%M%S).csv"

OT=$(awk -v b="$OT_BOARDS" -v s="$SCALE" 'BEGIN{printf "%d", b*s + 0.5}')
IT=$(awk -v b="$IT_BOARDS" -v s="$SCALE" 'BEGIN{printf "%d", b*s + 0.5}')
N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))

# --storage.tsdb.min/max-block-duration are hidden/undocumented in 3.13 (--help-long accepts
# them). Off by default; opt-in via MIN_BLOCK only.
EXTRA=""
[ -n "$MIN_BLOCK" ] && EXTRA="--storage.tsdb.min-block-duration=$MIN_BLOCK --storage.tsdb.max-block-duration=$MIN_BLOCK"
[ -n "$RETENTION" ] && EXTRA="$EXTRA --storage.tsdb.retention.time=$RETENTION"

stop_fleet() {
  for h in "${LOAD_ARR[@]}"; do rsh "$h" "$REMOTE_ROOT/scripts/avalanche/stop.sh" >/dev/null 2>&1 || true; done
  rsh "$COLL" "$REMOTE_ROOT/scripts/prometheus/stop.sh" >/dev/null 2>&1 || true
}
trap stop_fleet EXIT

# same fan-out and board ordering as ramp_dist.sh/gen_targets: OT boards first, then IT.
launch_load() {
  local ot=$1 it=$2
  local n=$((ot+it)) nh=${#LOAD_ARR[@]}
  local per h cnt series
  { for ((i=0;i<ot;i++)); do echo "$OT_PER_BOARD"; done
    for ((i=0;i<it;i++)); do echo "$IT_PER_BOARD"; done; } > "$NATIVE/soak-series.txt"
  per=$(( (n + nh - 1) / nh ))
  for ((h=0; h<nh; h++)); do
    cnt=$(( n - h*per )); [ "$cnt" -gt "$per" ] && cnt=$per; [ "$cnt" -le 0 ] && break
    series=$(sed -n "$((h*per+1)),$((h*per+cnt))p" "$NATIVE/soak-series.txt" | tr '\n' ' ')
    rsh "${LOAD_ARR[$h]}" "$REMOTE_ROOT/scripts/avalanche/start.sh $BASE_PORT $series" >/dev/null
  done
}

measure_load() {
  local h row acpu=0 arss=0 hcpu=0 avail=9999 a b c d e f
  for h in "${LOAD_ARR[@]}"; do
    row=$(rsh "$h" "PROC_WIN=${PROC_WIN:-3} $REMOTE_ROOT/scripts/avalanche/measure.sh" 2>/dev/null)
    IFS=, read -r a b c d e f <<< "$row"
    acpu=$(awk -v x="$acpu" -v y="${a:-0}" 'BEGIN{print x+y}')
    arss=$(( arss + ${b:-0} ))
    awk "BEGIN{exit !(${c:-0} > $hcpu)}" && hcpu=${c:-0}
    [ "${e:-9999}" -lt "$avail" ] && avail=${e:-9999}
  done
  echo "$acpu,$arss,$hcpu,$avail"
}

echo "DIST soak: collector=$COLL  load=[${LOAD_ARR[*]}]"
echo "  scale=$SCALE -> $OT OT + $IT IT = $N targets / $P params"
echo "  duration=${DURATION}s sample=${SAMPLE}s${MIN_BLOCK:+ min-block=$MIN_BLOCK}${RETENTION:+ retention=$RETENTION}"

stop_fleet
launch_load "$OT" "$IT"
gen_targets "$N" | "$CFG/gen_prom_config.sh" > "$NATIVE/soak.yml"
scp_pass "$NATIVE/soak.yml" "$SSH_USER@$COLL:$REMOTE_ROOT/.native-data/soak.yml" >/dev/null
rsh "$COLL" "mkdir -p $REMOTE_ROOT/.native-data; ${REMOTE_TSDB:+TSDB_ROOT=$REMOTE_TSDB} \
  ${EXTRA:+PROM_EXTRA_FLAGS='$EXTRA'} \
  $REMOTE_ROOT/scripts/prometheus/start.sh $REMOTE_ROOT/.native-data/soak.yml $PROM_PORT" >/dev/null

# Gate on the whole fleet being up before t=0, for the same reason ramp_dist.sh does: target
# discovery takes ~30s at 200 targets, and a windowed query overlapping it reports the startup
# transient as steady state. Here it also means elapsed_s is measured from a real start.
echo -n "  waiting for $N targets"
deadline=$(( SECONDS + READY_TIMEOUT ))
while [ "$SECONDS" -lt "$deadline" ]; do
  u=$(rsh "$COLL" "PROM_URL=http://localhost:$PROM_PORT $REMOTE_ROOT/scripts/prometheus/soak_sample.sh" 2>/dev/null | cut -d, -f3)
  [ "${u:-0}" -ge "$N" ] && break
  echo -n "."; sleep 5
done
echo " up=${u:-0}/$N"

echo "elapsed_s,head_series,max_scrape_s,modules_up,cadence_s,compactions,memory_bytes,cpu_pct,ram_pct,block_bytes,head_bytes,wal_bytes,disk_bytes,samples_appended,bytes_per_sample,avail_gb,load_av_cpu,load_av_rss,load_host_cpu,load_avail_gb" > "$OUT"

# Seconds per block, for the bytes/sample denominator: MIN_BLOCK when forced, else the
# TSDB default of 2h. Accepts the Go-duration forms Prometheus takes (900s, 15m, 2h).
BLOCK_SECS=$(awk -v d="${MIN_BLOCK:-2h}" 'BEGIN{
  n=d; sub(/[a-z]+$/,"",n); u=d; sub(/^[0-9.]+/,"",u)
  m=(u=="h")?3600:(u=="m")?60:1; printf "%d", n*m }')

START=$(date +%s)
PREV_BLK=""; PREV_BB=""; PREV_SA=""; NCOMP=0
while :; do
  NOW=$(($(date +%s) - START))
  CROW=$(rsh "$COLL" "PROM_URL=http://localhost:$PROM_PORT $REMOTE_ROOT/scripts/prometheus/soak_sample.sh" 2>/dev/null)
  IFS=, read -r HEAD DUR UP CAD BLK MEM CPU RAM BB HB WB DISK SA BPS CAV <<< "$CROW"
  IFS=, read -r LCPU LRSS LHCPU LAVAIL <<< "$(measure_load)"

  printf "  t=%5ds up=%s/%s scrape=%ss cad=%ss | prom %s%%cpu %s%%ram | blocks=%s disk=%sB bps=%s | load %s%%cpu avail=%sg\n" \
    "$NOW" "${UP:-?}" "$N" "${DUR:-?}" "${CAD:-?}" "${CPU:-?}" "${RAM:-?}" "${BLK:-?}" "${DISK:-?}" "${BPS:-?}" "${LHCPU:-?}" "${LAVAIL:-?}"
  echo "$NOW,$HEAD,$DUR,$UP,$CAD,$BLK,$MEM,$CPU,$RAM,$BB,$HB,$WB,$DISK,$SA,$BPS,$CAV,$LCPU,$LRSS,$LHCPU,$LAVAIL" >> "$OUT"

  # The headline number of the whole soak: when the compaction counter ticks, the growth in
  # on-disk BLOCK bytes divided by the samples that block CONTAINS is the real, WAL-free cost
  # per sample.
  #
  # The denominator must be the block's own sample count, NOT the change in
  # samples_appended_total between two rows: the block holds a whole block period of data
  # (BLOCK_SECS) while consecutive rows are only $SAMPLE apart, and dividing by the latter
  # overstates bytes/sample by BLOCK_SECS/SAMPLE (it first reported 54.7 instead of ~2).
  # Our load is exactly $P samples/s by construction, so P*BLOCK_SECS is the exact count.
  #
  # The FIRST compaction is skipped: Prometheus aligns block boundaries to wall-clock
  # multiples, so block 1 covers an arbitrary partial period (observed: cut at t=1346s for a
  # 900s block) and its span is ambiguous. Every later block spans exactly BLOCK_SECS.
  if [ -n "$PREV_BLK" ] && [ "${BLK:-0}" != "$PREV_BLK" ]; then
    NCOMP=$(( NCOMP + 1 ))
    awk -v b0="$PREV_BB" -v b1="${BB:-0}" -v p="$P" -v bs="$BLOCK_SECS" -v n="$NCOMP" 'BEGIN{
      db=b1-b0; ds=p*bs
      if (n==1) { printf "  ** COMPACTION %d: blocks -> %.0f bytes (first block, boundary-aligned: span ambiguous, skipping)\n", n, b1; exit }
      if (db>0) printf "  ** COMPACTION %d: %.0f block bytes / %.0f samples = %.3f bytes/sample (WAL-free)\n", n, db, ds, db/ds
      else      printf "  ** COMPACTION %d: blocks %.0f -> %.0f bytes (no growth)\n", n, b0, b1 }'
  fi
  PREV_BLK=${BLK:-0}; PREV_BB=${BB:-0}; PREV_SA=${SA:-0}

  [ "${CAV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "  collector RAM low (${CAV}g) - stopping"; break; }
  [ "$NOW" -ge "$DURATION" ] && break
  sleep "$SAMPLE"
done
echo "-> $OUT"
