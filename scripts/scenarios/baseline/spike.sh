#!/usr/bin/env bash
# Baseline spike: realistic section-level transients. The CMS Tracker is powered on/off in
# SECTIONS, not all at once - roughly 6 Outer-Tracker sections and 3 Inner-Tracker sections,
# each carrying a ~equal share of that subsystem's boards. So the
# real transient is a section coming online/offline while Prometheus keeps scraping, NOT a
# single all-or-nothing IT jump.
#
# This walks the detector UP one section at a time (0 -> all OT sections -> all IT sections =
# full detector) and, unless DESCEND=0, back DOWN the same way (full -> 0). Every step is one
# section-sized spike; the staircase as a whole is the real power-on / power-off sequence. At
# each level it holds $HOLD s and records the settled scrape hit, cadence and resources.
# Config is sized for the full detector up front, so a section's boards are scraped the instant
# they start.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

OT=${OT:-$OT_BOARDS}                 # total Outer-Tracker boards (spread over the OT sections)
SP_IT=${SP_IT:-$IT_BOARDS}          # total Inner-Tracker boards (spread over the IT sections)
OT_SECTIONS=${OT_SECTIONS:-6}       # how the OT is powered (~6 sections)
IT_SECTIONS=${IT_SECTIONS:-3}       # how the IT is powered (~3 sections)
HOLD=${HOLD:-60}                    # seconds held at each section level before measuring
DESCEND=${DESCEND:-1}               # 1 = also walk back down (power-off), section by section
OUT="$DATA/spike.csv"

# Cumulative boards after $1 sections of $2 total boards split into $3 ~equal sections
# ("more or less populated in the same way"): remainder front-loaded so the early sections are
# the slightly bigger ones. cum_boards 0 .. => 0; cum_boards $nsec .. => all boards.
cum_boards() {
  local s=$1 total=$2 nsec=$3 base rem extra
  base=$(( total / nsec )); rem=$(( total % nsec ))
  extra=$(( s < rem ? s : rem ))
  echo $(( base * s + extra ))
}

write_config "$(( OT + SP_IT ))"
echo "phase,params,targets,head_series,max_scrape_s,modules_up,memory_bytes,cpu_pct,ram_pct,cadence_p99_s" > "$OUT"
stop_all; rm -rf "$TSDB_ROOT/tsdb"; start_prometheus   # server stays up; only the load changes

measure() {   # $1 label, $2 ot boards online, $3 it boards online
  pkill -x avalanche 2>/dev/null; sleep 1
  start_mixed "$2" "$3"; sleep "$HOLD"
  local n=$(( $2 + $3 )) p=$(( $2 * OT_PER_BOARD + $3 * IT_PER_BOARD ))
  IFS=, read -r HEAD DUR UP MEM AV CPU RAM CAD <<< "$(sample)"
  echo "   [$1] $n boards ($2 OT + $3 IT) / $p params: scrape=${DUR}s up=$UP/$n cpu=${CPU}% ram=${RAM}% cadence=${CAD}s"
  echo "$1,$p,$n,$HEAD,$DUR,$UP,$MEM,$CPU,$RAM,$CAD" >> "$OUT"
}

# power ON: OT section by section, then IT section by section (ends at the full detector).
# label = the section that just toggled (+OT3 = 3rd OT section came online).
for ((s=1; s<=OT_SECTIONS; s++)); do
  measure "+OT$s" "$(cum_boards "$s" "$OT" "$OT_SECTIONS")" 0
done
for ((s=1; s<=IT_SECTIONS; s++)); do
  measure "+IT$s" "$OT" "$(cum_boards "$s" "$SP_IT" "$IT_SECTIONS")"
done

# power OFF: IT sections then OT sections, back to nothing (LIFO: last on, first off).
if [ "$DESCEND" = 1 ]; then
  for ((s=IT_SECTIONS; s>=1; s--)); do
    measure "-IT$s" "$OT" "$(cum_boards "$((s-1))" "$SP_IT" "$IT_SECTIONS")"
  done
  for ((s=OT_SECTIONS; s>=1; s--)); do
    measure "-OT$s" "$(cum_boards "$((s-1))" "$OT" "$OT_SECTIONS")" 0
  done
fi
echo "-> $OUT"
