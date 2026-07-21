#!/usr/bin/env bash
# Emit a prometheus.yml to stdout from a target list read on stdin (one "host:port" per line).
# The 1 Hz cadence is pinned here. The "server" self-scrape target follows $PROM_PORT so a
# per-shard instance measures its own process (set PROM_PORT to override).
#   gen_targets            | gen_prom_config.sh > full.yml   (twin: every collector, full set)
#   sed -n '1,40p' targets | PROM_PORT=9091 gen_prom_config.sh > shard.yml
source "$(dirname "$0")/common.sh"
mapfile -t T
{
  echo "global:"
  echo "  scrape_interval: $INTERVAL"
  echo "  scrape_timeout: $TIMEOUT"
  echo "  scrape_protocols: [$PROTO]"
  echo "scrape_configs:"
  echo "  - job_name: modules"
  echo "    static_configs:"
  echo -n "      - targets: ["
  for t in "${T[@]}"; do [ -n "$t" ] && echo -n "\"$t\","; done
  echo "]"
  echo "  - job_name: server"
  echo "    static_configs: [{targets: [\"localhost:$PROM_PORT\"]}]"
}
