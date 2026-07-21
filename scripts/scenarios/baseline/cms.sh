#!/usr/bin/env bash
# The real CMS Tracker monitoring model at 1 Hz, three canonical configurations measured
# back to back on ONE node (real board numbers):
#   ot_only :  180 Outer-Tracker boards x 820    =   147,600 params  (the light subsystem)
#   it_only :   50 Inner-Tracker boards x 17,500 =   875,000 params  (the heavy subsystem)
#   full    :  180 OT + 50 IT = 230 boards        = 1,022,600 params  (the real detector)
# Why this mix: the exposer runs on the board, so 1 board = 1 scrape target. The Inner
# Tracker carries ~86% of the parameters from ~22% of the boards, so the per-node limit is
# set by IT board density; "full" is the number the design note must size for.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

OUT="$DATA/cms.csv"
echo "config,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"

measure() {   # $1 label, $2 ot boards, $3 it boards
  local n=$(( $2 + $3 )) p=$(( $2 * OT_PER_BOARD + $3 * IT_PER_BOARD )) row
  echo ">> $1: $2 OT + $3 IT = $n boards, $p params"
  bringup_mixed "$2" "$3"
  row=$(sample)
  echo "   $row"
  echo "$1,$p,$n,$row" >> "$OUT"
}

measure ot_only "$OT_BOARDS" 0
measure it_only 0 "$IT_BOARDS"
measure full    "$OT_BOARDS" "$IT_BOARDS"
echo "-> $OUT"
