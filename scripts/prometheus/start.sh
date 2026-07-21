#!/usr/bin/env bash
# ON a collector node: launch Prometheus against a staged config. Prometheus is alone on
# this box, so its process CPU/RAM is the true, uncontended per-node footprint.
# $1 = config file, $2 = web/API port (default 9090), $3 = tsdb path.
set -uo pipefail
CFG=${1:?usage: start.sh <config.yml> [port] [tsdb]}
PORT=${2:-9090}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# TSDB defaults under $TSDB_ROOT when set (HPC: node-local scratch), else the repo's .native-data.
TSDB=${3:-${TSDB_ROOT:-$ROOT/.native-data}/tsdb-$PORT}
rm -rf "$TSDB"
"$ROOT/bin/prometheus" --config.file="$CFG" --storage.tsdb.path="$TSDB" \
  --web.listen-address=":$PORT" >/dev/null 2>&1 &
echo "$(hostname): prometheus up on :$PORT (tsdb=$TSDB)"
