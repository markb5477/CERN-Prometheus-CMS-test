#!/usr/bin/env bash
# ON a collector node: stop every Prometheus instance and free the API ports.
set -uo pipefail
for p in $(seq 9090 9110); do fuser -k "${p}/tcp" 2>/dev/null; done
pkill -x prometheus 2>/dev/null
sleep 1
echo "$(hostname): prometheus stopped"
