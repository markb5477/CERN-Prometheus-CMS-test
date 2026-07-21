#!/usr/bin/env bash
# ON a collector node: print ONE CSV fragment describing the running Prometheus RIGHT NOW.
# Unlike measure.sh this does NOT wait for readiness or settle - soak_dist.sh brings the fleet
# up once and then calls this on a fixed cadence, so the caller owns the timeline and each row
# is a point on a curve rather than a settled snapshot.
#   head_series,max_scrape_s,modules_up,cadence_s,compactions,memory_bytes,cpu_pct,ram_pct,
#   block_bytes,head_bytes,wal_bytes,disk_bytes,samples_appended,bytes_per_sample,avail_gb
# compactions is cumulative: it ticks when a block is cut out of the head and compacted, which
# is the ONLY moment the disk numbers become meaningful (see soak_dist.sh).
set -uo pipefail
source "$(cd "$(dirname "$0")/../config" && pwd)/common.sh"

HEAD=$(prom 'prometheus_tsdb_head_series')
DUR=$(prom "max_over_time(max(scrape_duration_seconds{job=\"modules\"})[$WIN:1s])")
UP=$(prom 'count(up{job="modules"} == 1)')
CAD=$(prom "max(rate(prometheus_target_interval_length_seconds_sum[$WIN]) / rate(prometheus_target_interval_length_seconds_count[$WIN]))")
BLK=$(prom 'prometheus_tsdb_compactions_total{job="server"}')
MEM=$(prom 'process_resident_memory_bytes{job="server"}')
CPU=$(cpu_pct); RAM=$(ram_pct)
BB=$(prom 'prometheus_tsdb_storage_blocks_bytes{job="server"}')
HB=$(prom 'prometheus_tsdb_head_chunks_storage_size_bytes{job="server"}')
WB=$(prom 'prometheus_tsdb_wal_storage_size_bytes{job="server"}')
SA=$(prom 'sum(prometheus_tsdb_head_samples_appended_total{job="server"})')
read -r DISK BPS <<< "$(awk -v b="${BB:-0}" -v h="${HB:-0}" -v w="${WB:-0}" -v s="${SA:-0}" 'BEGIN{d=b+h+w; printf "%d %.4f", d, (s>0? d/s : 0)}')"
echo "$HEAD,$DUR,$UP,$CAD,$BLK,$MEM,$CPU,$RAM,$BB,$HB,$WB,$DISK,$SA,$BPS,$(avail_gb)"
