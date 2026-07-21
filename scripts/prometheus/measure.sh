#!/usr/bin/env bash
# ON a collector node: wait SETTLE for the head block to fill, sample the local Prometheus
# once, and print ONE CSV row to stdout (the controller captures and files it):
#   <label>,<head_series>,<max_scrape_s>,<modules_up>,<memory_bytes>,<host_avail_gb>,<cpu_pct>,
#   <ram_pct>,<cadence_s>,<block_bytes>,<head_bytes>,<wal_bytes>,<disk_bytes>,
#   <samples_appended>,<bytes_per_sample>
# $1 = label (first column). Query a specific instance with PROM_URL=http://localhost:<port>.
# max_scrape_s is the windowed worst over the last $WIN; cadence_s is the mean actual gap
# between scrape cycles over the same window (>~1.05s => 1 Hz slipping even if per-scrape
# time looks fine). The storage columns come straight from the TSDB's own metrics (no du needed, so this works
# unchanged over SSH); bytes_per_sample = disk/samples is a running aggregate incl. WAL - the
# clean compacted rate is delta(block_bytes)/delta(samples) across a compaction. cpu_pct/ram_pct
# are Prometheus's own process metrics = the TRUE per-node footprint (the box is uncontended).
set -uo pipefail
source "$(cd "$(dirname "$0")/../config" && pwd)/common.sh"
LABEL=${1:?usage: measure.sh <label>}

# Wait for the fleet to be fully up BEFORE starting the settle clock. Target discovery plus
# first scrape takes ~30s at 200 targets and scales with target count, so a fixed sleep lands
# mid-startup at larger scales. That matters because the windowed queries below look back $WIN:
# if the window overlaps startup, max_over_time reports the discovery transient (25s+ scrapes,
# a fraction of targets up) as though it were a steady-state ceiling. Set READY_N to the
# expected target count to gate on readiness; READY_N=0 keeps the old fixed-sleep behaviour.
READY_N=${READY_N:-0}
if [ "$READY_N" -gt 0 ]; then
  deadline=$(( SECONDS + ${READY_TIMEOUT:-300} ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    u=$(prom 'count(up{job="modules"}==1)')
    [ "${u:-0}" -ge "$READY_N" ] && break
    sleep 2
  done
fi
# ...then let a full settle pass, so every windowed query covers steady state only.
sleep "$SETTLE"
HEAD=$(prom 'prometheus_tsdb_head_series')
DUR=$(prom "max_over_time(max(scrape_duration_seconds{job=\"modules\"})[$WIN:1s])")
UP=$(prom 'count(up{job="modules"} == 1)')
MEM=$(prom 'process_resident_memory_bytes{job="server"}')
AV=$(avail_gb)
CPU=$(cpu_pct); RAM=$(ram_pct)
# Windowed MEAN gap between scrape cycles over the last $WIN. Do NOT use the summary's
# {quantile="0.99"} here: that quantile is cumulative over the whole process lifetime, and
# start.sh launches a fresh Prometheus per step, so at a short SETTLE the p99 is just the
# startup transient (it reported 1.7s at 51 targets / 4% CPU). rate(_sum)/rate(_count) is
# confined to $WIN, which begins well after discovery has settled.
CAD=$(prom "max(rate(prometheus_target_interval_length_seconds_sum[$WIN]) / rate(prometheus_target_interval_length_seconds_count[$WIN]))")
BB=$(prom 'prometheus_tsdb_storage_blocks_bytes{job="server"}')
HB=$(prom 'prometheus_tsdb_head_chunks_storage_size_bytes{job="server"}')
WB=$(prom 'prometheus_tsdb_wal_storage_size_bytes{job="server"}')
SA=$(prom 'sum(prometheus_tsdb_head_samples_appended_total{job="server"})')
read -r DISK BPS <<< "$(awk -v b="${BB:-0}" -v h="${HB:-0}" -v w="${WB:-0}" -v s="${SA:-0}" 'BEGIN{d=b+h+w; printf "%d %.4f", d, (s>0? d/s : 0)}')"
echo "$LABEL,$HEAD,$DUR,$UP,$MEM,$AV,$CPU,$RAM,$CAD,$BB,$HB,$WB,$DISK,$SA,$BPS"
