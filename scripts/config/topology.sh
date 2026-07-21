# Fleet + workload topology for DIST-mode (twin / shard) runs.
# Override any of these via env or scripts/config/secrets.env.
# Load hosts run the Avalanche generators; collector hosts run Prometheus. Keeping them
# on separate machines is the whole point: Prometheus is alone on its node, so its
# CPU/RAM is the true per-node footprint (uncontended by the generators).
: "${LOAD_HOSTS:=cmx-rack-sw-01.cern.ch}"        # generator node(s), space-separated
: "${COLLECTOR_HOSTS:=cmx-rack-sw-00.cern.ch}"   # prometheus node(s), space-separated
: "${REMOTE_ROOT:=/home/mbrandt/testingPrometheus/CERN-Prometheus-CMS-test}"
# Defaults are the real detector from the board model in common.sh: 150 OT + 50 IT boards
# (200 scrape targets) carrying 150*2100 + 50*11300 = 880,000 params (~0.88M). Override in
# secrets.env only to test a different scale.
: "${MODULES:=$(( OT_BOARDS + IT_BOARDS ))}"                              # total scrape targets = boards
: "${TOTAL:=$(( OT_BOARDS * OT_PER_BOARD + IT_BOARDS * IT_PER_BOARD ))}"  # total params (= series)
: "${SHARD_SET:=1 2 4 8}"   # functional-sharding fan-outs (K) to sweep

read -ra LOAD_ARR <<< "$LOAD_HOSTS"
read -ra COLL_ARR <<< "$COLLECTOR_HOSTS"

# Emit the global target list, one "host:port" per board, spread in contiguous blocks
# across the load hosts. Load host h owns ports BASE_PORT..BASE_PORT+block-1.
# $1 = number of boards (defaults to $MODULES).
gen_targets() {
  local n=${1:-$MODULES} nh=${#LOAD_ARR[@]} per i
  per=$(( (n + nh - 1) / nh ))            # ceil: boards per load host
  for ((i=0; i<n; i++)); do
    echo "${LOAD_ARR[$(( i / per ))]}:$(( BASE_PORT + i % per ))"
  done
}

# Emit the per-board parameter (series) count in the SAME board order as gen_targets:
# the first OT_BOARDS boards are Outer Tracker (2,100), the rest Inner Tracker (11,300).
# This is what makes the DIST load the real mixed detector, not a uniform average.
# $1 = number of boards (defaults to $MODULES).
gen_series() {
  local n=${1:-$MODULES} i
  for ((i=0; i<n; i++)); do
    if [ "$i" -lt "$OT_BOARDS" ]; then echo "$OT_PER_BOARD"; else echo "$IT_PER_BOARD"; fi
  done
}
