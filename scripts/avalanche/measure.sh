#!/usr/bin/env bash
# ON a load node: sample the generator fleet's footprint so the controller can tell a REAL
# Prometheus ceiling from a LOAD-side bottleneck. A saturated generator can't serve /metrics
# fast enough, which starves Prometheus and fakes a collector ceiling - so every ramp step must
# check the load node too. Prints ONE CSV fragment to stdout:
#   av_cpu,av_rss,host_cpu,host_ram_used,host_avail_gb,av_procs
# CPU% is % of ALL cores (100 = every core busy), the same convention as the collector's
# cpu_pct, so the two nodes are directly comparable. Set PROC_WIN to widen the sampling window.
set -uo pipefail
source "$(cd "$(dirname "$0")/../config" && pwd)/common.sh"
IFS=, read -r HCPU HUSED ACPU ARSS PCPU PRSS <<< "$(proc_sample "${PROC_WIN:-3}")"
echo "$ACPU,$ARSS,$HCPU,$HUSED,$(avail_gb),$(pgrep -xc avalanche 2>/dev/null || echo 0)"
