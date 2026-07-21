#!/usr/bin/env bash
# Baseline soak: hold the full real detector (180 OT + 50 IT = 230 boards, ~1.02M params)
# at 1 Hz for DURATION and sample over time. Watches for memory creep or scrape drift at the
# real operating point - the load a production node would actually carry.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

OT=${OT:-$OT_BOARDS}
IT=${IT:-$IT_BOARDS}
DURATION=${DURATION:-1800}   # seconds
SAMPLE=${SAMPLE:-30}
OUT="$DATA/soak.csv"
N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))

# Optional compaction exercise (opt-in). MIN_BLOCK forces Prometheus to cut + compact blocks
# on a short cadence (e.g. MIN_BLOCK=5m) so a brief soak actually exercises the compactor
# instead of holding everything in the head. RETENTION caps on-disk history.
# NOTE: --storage.tsdb.min/max-block-duration are hidden/undocumented flags in 3.13
# (--help-long still accepts them) - off by default, opt-in only.
MIN_BLOCK=${MIN_BLOCK:-}
RETENTION=${RETENTION:-}
if [ -n "$MIN_BLOCK" ]; then
  PROM_EXTRA_FLAGS="--storage.tsdb.min-block-duration=$MIN_BLOCK --storage.tsdb.max-block-duration=$MIN_BLOCK ${PROM_EXTRA_FLAGS:-}"
fi
[ -n "$RETENTION" ] && PROM_EXTRA_FLAGS="--storage.tsdb.retention.time=$RETENTION ${PROM_EXTRA_FLAGS:-}"
export PROM_EXTRA_FLAGS="${PROM_EXTRA_FLAGS:-}"

bringup_mixed "$OT" "$IT"    # stop, config, start mixed fleet + prometheus, settle
echo "holding $N boards / $P params for ${DURATION}s${MIN_BLOCK:+ (min-block=$MIN_BLOCK)}"
# Columns, grouped: scrape health | Prometheus (metric, per-node authoritative) | Prometheus
# (/proc cross-check) | avalanche isolated | whole machine (bookkeeping) | storage.
#   disk_bytes = block_bytes+head_bytes+wal_bytes ; bytes_per_sample = disk_bytes/samples_appended
#   (running aggregate incl. WAL - a conservative upper bound; the clean COMPACTED rate is the
#   delta of block_bytes / delta of samples_appended across a compaction, done in analysis).
echo "elapsed_s,head_series,max_scrape_s,modules_up,cadence_p99_s,blocks,memory_bytes,cpu_pct,ram_pct,prom_cpu_proc,prom_rss_proc,av_cpu,av_rss,host_cpu,host_ram_used,block_bytes,head_bytes,wal_bytes,disk_bytes,samples_appended,bytes_per_sample" > "$OUT"
START=$(date +%s)
while :; do
  NOW=$(($(date +%s) - START))
  IFS=, read -r HEAD DUR UP MEM AV CPU RAM CAD <<< "$(sample)"
  BLK=$(prom 'prometheus_tsdb_compactions_total{job="server"}')   # cumulative block cuts; rises when a block is compacted out of the head
  BB=$(prom 'prometheus_tsdb_storage_blocks_bytes{job="server"}')
  HB=$(prom 'prometheus_tsdb_head_chunks_storage_size_bytes{job="server"}')
  WB=$(prom 'prometheus_tsdb_wal_storage_size_bytes{job="server"}')
  SA=$(prom 'sum(prometheus_tsdb_head_samples_appended_total{job="server"})')
  IFS=, read -r HCPU HUSED ACPU ARSS PCPU PRSS <<< "$(proc_sample 1)"
  read -r DISK BPS <<< "$(awk -v b="${BB:-0}" -v h="${HB:-0}" -v w="${WB:-0}" -v s="${SA:-0}" 'BEGIN{d=b+h+w; printf "%d %.4f", d, (s>0? d/s : 0)}')"
  echo "   t=${NOW}s up=$UP/$N scrape=${DUR}s cad=${CAD}s | prom ${CPU}%cpu ${MEM}B | avln ${ACPU}%cpu ${ARSS}B | host ${HCPU}%cpu used=${HUSED}B | disk=${DISK}B bps=${BPS} blocks=${BLK} avail=${AV}g"
  echo "$NOW,$HEAD,$DUR,$UP,$CAD,$BLK,$MEM,$CPU,$RAM,$PCPU,$PRSS,$ACPU,$ARSS,$HCPU,$HUSED,$BB,$HB,$WB,$DISK,$SA,$BPS" >> "$OUT"
  [ "${AV:-99}" -lt "$MIN_AVAIL_GB" ] && { echo "host RAM low (${AV}g), stopping"; break; }
  [ "$NOW" -ge "$DURATION" ] && break
  sleep "$SAMPLE"
done
echo "-> $OUT"
