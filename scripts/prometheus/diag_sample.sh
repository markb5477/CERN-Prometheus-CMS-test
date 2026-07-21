#!/usr/bin/env bash
# ON a collector node: print ONE line describing scrape health RIGHT NOW, sampled over $1 s.
# Unlike measure.sh (one settled snapshot per ramp step) this is meant to be called in a loop
# while the fleet stays up, so we can watch a degradation develop instead of racing it.
#   net        = bytes/s actually arriving on the NIC -> is the link the wall?
#   prom_cpu   = prometheus process CPU as % of the whole node (same convention as cpu_pct)
#   up         = targets currently succeeding
#   max_scrape = slowest target right now
#   over0.9    = how many targets exceed the 900ms scrape_timeout
#   appended   = samples/s actually landing in the TSDB -> real ingest rate
# $1 = sample window seconds (default 5). NIC=<iface> overrides interface autodetection.
set -uo pipefail
source "$(cd "$(dirname "$0")/../config" && pwd)/common.sh"
W=${1:-5}
# first UP physical interface, skipping loopback/container/bridge plumbing
NIC=${NIC:-$(ip -br link | awk '$2=="UP" && $1!~/^(lo|docker|veth|br-|virbr|bond)/{print $1; exit}')}
RXF="/sys/class/net/$NIC/statistics/rx_bytes"
PID=$(pgrep -x prometheus | head -1)

r1=$(cat "$RXF" 2>/dev/null || echo 0)
c1=$(awk '{print $14+$15}' "/proc/${PID:-0}/stat" 2>/dev/null || echo 0)
sleep "$W"
r2=$(cat "$RXF" 2>/dev/null || echo 0)
c2=$(awk '{print $14+$15}' "/proc/${PID:-0}/stat" 2>/dev/null || echo 0)

UP=$(prom 'count(up{job="modules"}==1)')
MAXD=$(prom 'max(scrape_duration_seconds{job="modules"})')
OVER=$(prom 'count(scrape_duration_seconds{job="modules"} > 0.9)')
SAMP=$(prom 'rate(prometheus_tsdb_head_samples_appended_total[1m])')

awk -v r1="$r1" -v r2="$r2" -v c1="$c1" -v c2="$c2" -v w="$W" -v hz="$(getconf CLK_TCK)" \
    -v n="$CORES" -v nic="$NIC" -v up="${UP:-0}" -v md="${MAXD:-0}" -v ov="${OVER:-0}" \
    -v sa="${SAMP:-0}" 'BEGIN{
  printf "%s net=%.1fMB/s prom_cpu=%.1f%% up=%d max_scrape=%.2fs over0.9=%d appended=%.0f/s\n",
    nic, (r2-r1)/w/1048576, (c2-c1)/hz/w/n*100, up, md, ov, sa }'
