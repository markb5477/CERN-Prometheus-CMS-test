# Shared config + helpers for the Prometheus 1 Hz test suite.
# Sourced by the baseline scenarios (LOCAL mode, avalanche + prometheus co-located) and,
# when staged on a remote node, by prometheus/measure.sh.
# A module is one scrape target; each module exposes parameters (1 parameter = 1 series).
# The 1 Hz cadence is fixed: INTERVAL=1s, TIMEOUT=900ms. Do not change.
set -uo pipefail

# scripts/config/common.sh -> repo root is two levels up
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/scripts"
BIN="$ROOT/bin"
NATIVE="$ROOT/.native-data"     # prom.yml + tsdb (gitignored, transient)
DATA="$SCRIPTS/data"            # raw CSVs
GRAPHS="$SCRIPTS/graphs"        # PNGs
mkdir -p "$DATA" "$GRAPHS"

: "${BASE_PORT:=9101}"          # first exporter port
: "${PROM_PORT:=9090}"          # prometheus web/API port
: "${SETTLE:=45}"               # seconds to let the head block fill before measuring
: "${MIN_AVAIL_GB:=10}"         # stop before the host itself runs out of RAM
: "${INTERVAL:=1s}"             # scrape interval (1 Hz)
: "${TIMEOUT:=900ms}"           # max tolerated scrape duration (< INTERVAL); overrun = dropped sample
: "${PROTO:=PrometheusText0.0.4}"          # pin exposition format so every scrape parses identically
: "${PROM_URL:=http://localhost:$PROM_PORT}"   # where prom()/measure query prometheus
: "${WIN:=30s}"                 # read window for max_over_time (MUST be <= SETTLE, else the subquery has no data)

# Where the TSDB lives. Defaults to $NATIVE, which is fine for the local suite.
# On the HPC set TSDB_ROOT to node-local scratch (/tmp or a local NVMe), never
# Lustre/GPFS/NFS: a networked FS wrecks the fsync-heavy write path and the numbers
# stop meaning anything. Not /dev/shm either - tmpfs would eat the RAM being measured.
: "${TSDB_ROOT:=$NATIVE}"

# ---- CMS Tracker parameter model (confirmed per-cycle counts, 2026-07) ----
# The metrics exposer runs ON each readout board/DTC, so 1 board = 1 Prometheus scrape target.
# Confirmed building blocks (1 param = 1 series = 1 value / 1 Hz cycle):
#   Inner Tracker  ~565,000:  14,088 chips x 35            = 493,080
#                              4,416 modules x 12           =  52,992
#                              + port-card/cooling/HV/serial-power blocks ~19,000
#   Outer Tracker  ~315,000:  13,296 modules x ~20         ~ 266,000
#                              ~150 boards x ~100           ~  15,000
#                              + further OT board/infra blocks ~34,000   [A] not yet itemised
#   Combined ~880,000 per cycle ("approaches ~1 million").
# IT carries ~64% of params (was ~86% in the old model) and an IT board is ~5.4x an OT board.
# Per-target series below = confirmed subsystem total / board count (board = scrape target):
#   OT: 315,000 / ~150 = ~2,100/board.   IT: 565,000 / ~50 = ~11,300/board.
#   ~150 OT + ~50 IT = ~200 targets ; 150*2100 + 50*11300 = 880,000 params (~0.88M).
# [D] IT_BOARDS (readout DTC count) is the unconfirmed number that sets IT per-target density
#     (the scrape wall). ~50 is derived from OT's ~89 modules/board and is not yet confirmed.
: "${OT_PER_BOARD:=2100}"
: "${IT_PER_BOARD:=11300}"
: "${OT_BOARDS:=150}"
: "${IT_BOARDS:=50}"
FULL_TARGETS=$(( OT_BOARDS + IT_BOARDS ))
FULL_PARAMS=$(( OT_BOARDS * OT_PER_BOARD + IT_BOARDS * IT_PER_BOARD ))

CORES=$(nproc)                                # CPU as a share of the whole node
MEM_TOTAL=$(free -b | awk 'NR==2{print $2}')  # total RAM in bytes, for RAM as a share of the node

# ---- query helpers (wherever prometheus is reachable at $PROM_URL) ----
# run one instant query, print the scalar value
prom() {
  curl -s "$PROM_URL/api/v1/query" --data-urlencode "query=$1" \
    | grep -oP '"value":\[[0-9.]+,"\K[0-9.e+]+' | head -1 || true
}
avail_gb() { free -g | awk 'NR==2{print $7}'; }

# Prometheus process CPU as a percentage of the whole node (100 = every core busy).
# process_cpu_seconds_total is cumulative, so we take its rate over the settle window.
cpu_pct() {
  local c; c=$(prom 'rate(process_cpu_seconds_total{job="server"}[30s])')
  [ -z "$c" ] && return
  awk -v c="$c" -v n="$CORES" 'BEGIN{ printf "%.2f", (n>0)? c/n*100 : 0 }'
}
# Prometheus resident memory as a percentage of the node's total RAM.
ram_pct() {
  local m; m=$(prom 'process_resident_memory_bytes{job="server"}')
  [ -z "$m" ] && return
  awk -v m="$m" -v t="$MEM_TOTAL" 'BEGIN{ printf "%.2f", (t>0)? m/t*100 : 0 }'
}

# ---- per-process isolation via /proc (no extra tooling) ----
# cpu_pct()/ram_pct() above already isolate the collector (job="server"). On a co-located box
# we also need the load generator (avalanche) and the whole machine separately: the host numbers
# explain why a co-located run ceils out or dies (out of cores/RAM). Same convention as cpu_pct():
# 100 = every core busy, so prom + avalanche + host are comparable and roughly additive.
_cpu_total_idle() { awk '/^cpu /{t=0; for(i=2;i<=NF;i++)t+=$i; print t, $5+$6; exit}' /proc/stat; }
_sum_jiffies() {   # $@ = pids -> sum of utime+stime (fields 14+15; comm has no spaces here)
  [ "$#" -eq 0 ] && { echo 0; return; }
  local paths="" p; for p in "$@"; do paths+=" /proc/$p/stat"; done
  awk '{s+=$14+$15} END{print s+0}' $paths 2>/dev/null || echo 0
}
_sum_rss() {       # $@ = pids -> sum resident bytes (statm field 2 x page size)
  [ "$#" -eq 0 ] && { echo 0; return; }
  local paths="" p; for p in "$@"; do paths+=" /proc/$p/statm"; done
  awk -v pg="$(getconf PAGESIZE)" '{s+=$2} END{print (s+0)*pg}' $paths 2>/dev/null || echo 0
}
# One consistent snapshot over $1 s (default 1). Prints, as one CSV fragment:
#   host_cpu_pct,host_ram_used_bytes,av_cpu_pct,av_rss_bytes,prom_cpu_pct,prom_rss_bytes
# host_ram_used = MemTotal-MemAvailable; prom_* here are /proc-derived (a cross-check on the
# metric-based cpu_pct/ram_pct, sampled over the SAME window as avalanche/host).
proc_sample() {
  local iv=${1:-1} avp promp t0 i0 a0 p0 t1 i1 a1 p1
  avp=$(pgrep -x avalanche | tr '\n' ' '); promp=$(pgrep -x prometheus | tr '\n' ' ')
  read -r t0 i0 < <(_cpu_total_idle); a0=$(_sum_jiffies $avp); p0=$(_sum_jiffies $promp)
  sleep "$iv"
  read -r t1 i1 < <(_cpu_total_idle); a1=$(_sum_jiffies $avp); p1=$(_sum_jiffies $promp)
  local avrss promrss used
  avrss=$(_sum_rss $avp); promrss=$(_sum_rss $promp)
  used=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print (t-a)*1024}' /proc/meminfo)
  awk -v dt="$((t1-t0))" -v di="$((i1-i0))" -v da="$((a1-a0))" -v dp="$((p1-p0))" \
      -v avrss="$avrss" -v promrss="$promrss" -v used="$used" 'BEGIN{
    printf "%.2f,%d,%.2f,%d,%.2f,%d",
      (dt>0?(dt-di)/dt*100:0), used, (dt>0?da/dt*100:0), avrss, (dt>0?dp/dt*100:0), promrss }'
}

# Warn (once per launch) if TSDB_ROOT sits on a networked filesystem - the TSDB's fsync-heavy
# write path degrades badly on nfs/lustre/gpfs/fuse and the measured footprint stops meaning
# anything. Best-effort: silent if stat can't read the path (dir created just after).
warn_if_network_fs() {
  local t; t=$(stat -f -c %T "$TSDB_ROOT" 2>/dev/null) || return 0
  case "$t" in
    nfs*|lustre*|gpfs*|fuse*)
      echo "WARNING: TSDB_ROOT=$TSDB_ROOT is on a '$t' filesystem - use node-local scratch (/tmp, local NVMe); network FS invalidates the numbers." >&2 ;;
  esac
}

# ---- LOCAL-mode launch/teardown (baseline scenarios; everything on localhost) ----
# $1 = number of modules (localhost targets)
write_config() {
  mkdir -p "$NATIVE"
  { echo "global:"
    echo "  scrape_interval: $INTERVAL"
    echo "  scrape_timeout: $TIMEOUT"
    echo "  scrape_protocols: [$PROTO]"
    echo "scrape_configs:"
    echo "  - job_name: modules"
    echo "    static_configs:"
    echo -n "      - targets: ["
    for i in $(seq 0 $(($1 - 1))); do echo -n "\"localhost:$((BASE_PORT + i))\","; done
    echo "]"
    echo "  - job_name: server"
    echo "    static_configs: [{targets: [\"localhost:$PROM_PORT\"]}]"
  } > "$NATIVE/prom.yml"
}

# $1 = number of modules, $2 = parameters each.
# value-interval=1: values tick at 1 Hz. series/metric-interval=0: parameter count never changes.
start_modules() {
  for i in $(seq 0 $(($1 - 1))); do
    "$BIN/avalanche" --gauge-metric-count=1 --series-count="$2" --port=$((BASE_PORT + i)) \
      --value-interval=1 --series-interval=0 --metric-interval=0 >/dev/null 2>&1 &
  done
}

# PROM_EXTRA_FLAGS (optional, space-separated) is appended verbatim - used by push.sh to enable
# the remote-write receiver and by soak.sh to force short block durations.
start_prometheus() {
  warn_if_network_fs
  "$BIN/prometheus" --config.file="$NATIVE/prom.yml" --storage.tsdb.path="$TSDB_ROOT/tsdb" \
    --web.listen-address=:$PROM_PORT ${PROM_EXTRA_FLAGS:-} >/dev/null 2>&1 &
}

# start <count> exporters, each serving <series> parameters, from <base_port> upward.
start_boards() {
  local n=$1 series=$2 base=${3:-$BASE_PORT} i
  for ((i=0; i<n; i++)); do
    "$BIN/avalanche" --gauge-metric-count=1 --series-count="$series" --port=$((base + i)) \
      --value-interval=1 --series-interval=0 --metric-interval=0 >/dev/null 2>&1 &
  done
}

# start a real mixed fleet: <ot> Outer-Tracker boards (820 each) then <it> Inner-Tracker
# boards (17,500 each), on contiguous ports (OT first). Total targets = ot + it.
start_mixed() {
  local ot=$1 it=$2
  [ "$ot" -gt 0 ] && start_boards "$ot" "$OT_PER_BOARD" "$BASE_PORT"
  [ "$it" -gt 0 ] && start_boards "$it" "$IT_PER_BOARD" "$((BASE_PORT + ot))"
}

# start a real mixed fleet in PUSH mode: each board remote_writes its samples to Prometheus's
# remote-write receiver at 1 Hz instead of exposing /metrics to be scraped. OT boards (820
# series) first, then IT boards (17,500). Requires prometheus started with
# PROM_EXTRA_FLAGS="--web.enable-remote-write-receiver". --remote-requests-count=-1 => run
# indefinitely (the default 100 would stop mid-measurement).
start_push() {
  local ot=$1 it=$2 url="$PROM_URL/api/v1/write" i
  for ((i=0; i<ot; i++)); do
    "$BIN/avalanche" --gauge-metric-count=1 --series-count="$OT_PER_BOARD" \
      --value-interval=1 --series-interval=0 --metric-interval=0 \
      --remote-url="$url" --remote-write-interval=1s --remote-requests-count=-1 >/dev/null 2>&1 &
  done
  for ((i=0; i<it; i++)); do
    "$BIN/avalanche" --gauge-metric-count=1 --series-count="$IT_PER_BOARD" \
      --value-interval=1 --series-interval=0 --metric-interval=0 \
      --remote-url="$url" --remote-write-interval=1s --remote-requests-count=-1 >/dev/null 2>&1 &
  done
}

# tear down, configure for (ot+it) targets, launch the mixed fleet + prometheus, settle.
bringup_mixed() {
  local ot=$1 it=$2
  stop_all; rm -rf "$TSDB_ROOT/tsdb"; write_config "$(( ot + it ))"
  start_mixed "$ot" "$it"; start_prometheus; sleep "$SETTLE"
}

# one sample of the running collector as a CSV fragment:
#   head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s
# max_scrape_s is the windowed worst over the last $WIN (not a single instant), so a transient
# overrun in the settle window still shows. cadence_p99_s is the p99 actual gap between scrape
# cycles: >~1.05s means 1 Hz is slipping even when the per-scrape time still looks fine.
sample() {
  echo "$(prom 'prometheus_tsdb_head_series'),$(prom "max_over_time(max(scrape_duration_seconds{job=\"modules\"})[$WIN:1s])"),$(prom 'count(up{job="modules"} == 1)'),$(prom 'process_resident_memory_bytes{job="server"}'),$(avail_gb),$(cpu_pct),$(ram_pct),$(prom 'max(prometheus_target_interval_length_seconds{quantile="0.99"})')"
}

stop_all() {
  local p
  for p in $PROM_PORT $(seq $BASE_PORT $((BASE_PORT + 999))); do fuser -k "${p}/tcp" 2>/dev/null; done
  pkill -x avalanche 2>/dev/null; pkill -x prometheus 2>/dev/null; sleep 1
}

# ---- DIST-mode SSH wrappers (controller only; password from $SSHPASS via secrets.env) ----
# CERN hosts: no pubkey/Kerberos, only keyboard-interactive/password (see DESIGN.md 4).
SSH_OPTS=(-o GSSAPIAuthentication=no -o PubkeyAuthentication=no
          -o PreferredAuthentications=keyboard-interactive,password
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

# read secrets.env (gitignored) into the environment; SSHPASS feeds sshpass -e.
load_secrets() {
  local f="$SCRIPTS/config/secrets.env"
  if [ -f "$f" ]; then set -a; . "$f"; set +a; fi
  : "${SSH_USER:=mbrandt}"
  export SSHPASS
}
ssh_pass() { sshpass -e ssh "${SSH_OPTS[@]}" "$@"; }
scp_pass() { sshpass -e scp "${SSH_OPTS[@]}" "$@"; }
# rsh <host> '<remote command>'
rsh() { local h=$1; shift; ssh_pass "$SSH_USER@$h" "$@"; }
