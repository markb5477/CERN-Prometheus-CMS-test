#!/usr/bin/env bash
# ON a load node: stop all Avalanche exporters and free their ports.
set -uo pipefail
for p in $(seq 9101 9700); do fuser -k "${p}/tcp" 2>/dev/null; done
pkill -x avalanche 2>/dev/null
sleep 1
echo "$(hostname): avalanche stopped"
