#!/usr/bin/env bash
# Pull-vs-push DIAGNOSTIC (not part of the core pull sweep; opt-in via RUN_PUSH=1).
#
# It proves *what* the single-node wall is: the pull suite hits a ceiling because every scrape
# must finish inside the 1 s tick. Push (remote_write) removes that per-scrape deadline entirely
# - ingestion is decoupled from a 1 s window - so if the same synthetic load sustains its full
# sample rate here while the pull suite walled, the wall is the 1 s pull deadline, NOT the box.
#
# How it differs from the pull scenarios:
#   * config has the modules job REMOVED (write_config 0) - Prometheus only self-scrapes.
#   * Prometheus launches with --web.enable-remote-write-receiver.
#   * the real mixed fleet runs in remote-write mode (start_push), pushing at 1 Hz.
#   * there is no scrape_duration to measure; the "keeping up at 1 Hz" signal is instead
#     rate(prometheus_tsdb_head_samples_appended_total) vs the expected params/s (1 sample per
#     series per second), plus head_series / CPU / RAM.
#
# Framing (see DESIGN.md 5): this is the pull-vs-push lever. It is ranked BELOW the
# VictoriaMetrics head-to-head the design note calls the decision-changer, and it is NOT a
# deployment recommendation - boards today expose /metrics, and push is still an open [D].
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

OUT="$DATA/push.csv"
echo "label,params,expected_per_s,appended_per_s,head_series,memory_bytes,cpu_pct,ram_pct" > "$OUT"

measure_push() {   # $1 label, $2 ot boards, $3 it boards
  local n=$(( $2 + $3 )) p=$(( $2 * OT_PER_BOARD + $3 * IT_PER_BOARD )) appended head mem cpu ram
  echo ">> push $1: $2 OT + $3 IT = $n boards, $p params (expect ~$p samples/s at 1 Hz)"
  stop_all; rm -rf "$TSDB_ROOT/tsdb"; write_config 0    # server self-scrape only, no modules job
  PROM_EXTRA_FLAGS="--web.enable-remote-write-receiver" start_prometheus
  sleep 2
  start_push "$2" "$3"; sleep "$SETTLE"
  appended=$(prom "rate(prometheus_tsdb_head_samples_appended_total[$WIN])")
  head=$(prom 'prometheus_tsdb_head_series')
  mem=$(prom 'process_resident_memory_bytes{job="server"}')
  cpu=$(cpu_pct); ram=$(ram_pct)
  echo "   appended=${appended}/s (expect ~$p) head=$head mem=$mem cpu=${cpu}% ram=${ram}%"
  echo "$1,$p,$p,$appended,$head,$mem,$cpu,$ram" >> "$OUT"
}

measure_push ot_only "${OT:-$OT_BOARDS}" 0
measure_push it_only 0 "${IT:-$IT_BOARDS}"
measure_push full    "${OT:-$OT_BOARDS}" "${IT:-$IT_BOARDS}"
echo "-> $OUT"
