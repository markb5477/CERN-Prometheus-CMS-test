#!/usr/bin/env bash
# ON a load node: launch one Avalanche exporter per series count given, starting at <base_port>.
#   start.sh <base_port> <series1> [series2 ...]
# Each exporter serves its own series count (1 param = 1 series), so a single host can host a
# mix of Outer-Tracker (820) and Inner-Tracker (17,500) boards. --port binds all interfaces so
# Prometheus on the collector scrapes over the LAN. value-interval=1 -> values tick at 1 Hz;
# series/metric-interval=0 -> the parameter count is static within a run.
set -uo pipefail
BASE=${1:?usage: start.sh <base_port> <series...>}; shift
[ "$#" -eq 0 ] && { echo "no series counts given" >&2; exit 1; }
BIN="$(cd "$(dirname "$0")/../.." && pwd)/bin/avalanche"
i=0
for S in "$@"; do
  "$BIN" --gauge-metric-count=1 --series-count="$S" --port=$((BASE + i)) \
    --value-interval=1 --series-interval=0 --metric-interval=0 >/dev/null 2>&1 &
  i=$((i + 1))
done
echo "$(hostname): started $i exporters on ports $BASE-$((BASE + i - 1))"
