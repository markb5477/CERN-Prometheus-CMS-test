# Helpers shared by the test scripts: config, launch, query, cleanup.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"; DATA="$ROOT/.native-data"; RESULTS="$ROOT/results"
BASE_PORT=9101; PROM_PORT=9090
: "${SETTLE:=45}"       # seconds to let the head block fill before measuring
: "${MIN_AVAIL_GB:=2}"  # stop before the host itself runs out of RAM
: "${INTERVAL:=1s}"     # scrape interval (1 Hz)
: "${TIMEOUT:=900ms}"   # max tolerated scrape duration (must be < INTERVAL); overrun = dropped sample
: "${PROTO:=PrometheusText0.0.4}"  # pin exposition format so every scrape parses identically
mkdir -p "$RESULTS"

# $1 = number of client targets.
write_config() {
  mkdir -p "$DATA"
  { echo "global:"
    echo "  scrape_interval: $INTERVAL"
    echo "  scrape_timeout: $TIMEOUT"
    echo "  scrape_protocols: [$PROTO]"
    echo "scrape_configs:"
    echo "  - job_name: client"
    echo "    static_configs:"
    echo -n "      - targets: ["
    for i in $(seq 0 $(($1 - 1))); do echo -n "\"localhost:$((BASE_PORT + i))\","; done
    echo "]"
    echo "  - job_name: server"
    echo "    static_configs: [{targets: [\"localhost:$PROM_PORT\"]}]"
  } > "$DATA/prom.yml"
}

# $1 = number of exporters, $2 = series each.
# value-interval=1: values tick at 1 Hz. series/metric-interval=0: cardinality never changes.
start_exporters() {
  for i in $(seq 0 $(($1 - 1))); do
    "$BIN/avalanche" --gauge-metric-count=1 --series-count="$2" --port=$((BASE_PORT + i)) \
      --value-interval=1 --series-interval=0 --metric-interval=0 >/dev/null 2>&1 &
  done
}

start_prometheus() {
  "$BIN/prometheus" --config.file="$DATA/prom.yml" --storage.tsdb.path="$DATA/tsdb" \
    --web.listen-address=:$PROM_PORT >/dev/null 2>&1 &
}

# run one instant query, print the scalar value
prom() {
  curl -s "http://localhost:$PROM_PORT/api/v1/query" --data-urlencode "query=$1" \
    | grep -oP '"value":\[[0-9.]+,"\K[0-9.e+]+' | head -1 || true
}

avail_gb() { free -g | awk 'NR==2{print $7}'; }

stop_all() {
  for p in $PROM_PORT $(seq $BASE_PORT $((BASE_PORT + 199))); do fuser -k "${p}/tcp" 2>/dev/null; done
  pkill -x avalanche 2>/dev/null; pkill -x prometheus 2>/dev/null; sleep 1
}
