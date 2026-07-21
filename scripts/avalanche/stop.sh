#!/usr/bin/env bash
# ON a load node: stop all Avalanche exporters and free their ports.
set -uo pipefail
# pkill first: it catches every exporter regardless of port, so the sweep below is only a
# backstop for ports orphaned by a crashed run. The span must cover the largest scale we
# run (1 target = 1 port from BASE_PORT up) -- at 600 ports it silently capped us at scale 3.
pkill -x avalanche 2>/dev/null
for p in $(seq "${BASE_PORT:-9101}" $(( ${BASE_PORT:-9101} + ${PORT_SPAN:-1600} - 1 ))); do
  fuser -k "${p}/tcp" 2>/dev/null
done
sleep 1
echo "$(hostname): avalanche stopped"
