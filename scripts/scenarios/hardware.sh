#!/usr/bin/env bash
# Real-hardware test: point Prometheus at REAL module exporters (no Avalanche) and measure
# the true 1 Hz footprint on real sensors. The exporters run on the modules' own hardware,
# so a locally-run Prometheus is already separated from the load -> its CPU/RAM is
# uncontended, just like the twin/shard collectors. Validates the synthetic curve on real data.
#
#   scripts/scenarios/hardware.sh                 # uses config/targets.real
#   HW_TARGETS=/path/to/list scripts/scenarios/hardware.sh
set -uo pipefail
CFG="$(cd "$(dirname "$0")/../config" && pwd)"
source "$CFG/common.sh"

INV=${HW_TARGETS:-$CFG/targets.real}
[ -f "$INV" ] || { echo "no inventory: cp $CFG/targets.real.example $CFG/targets.real and list the real endpoints" >&2; exit 1; }

# drop #-comments and whitespace -> clean "host:port" list
mapfile -t TARGETS < <(sed 's/#.*//; s/[[:space:]]//g' "$INV" | grep -v '^$')
N=${#TARGETS[@]}
[ "$N" -eq 0 ] && { echo "inventory $INV has no targets" >&2; exit 1; }

OUT="$DATA/hardware.csv"
mkdir -p "$NATIVE"
echo "label,targets,head_series,max_scrape_s,modules_up,memory_bytes,host_avail_gb,cpu_pct,ram_pct,cadence_s" > "$OUT"

cleanup() { fuser -k "$PROM_PORT/tcp" 2>/dev/null; pkill -x prometheus 2>/dev/null; sleep 1; }
trap cleanup EXIT

echo "hardware: $N real module(s) from $(basename "$INV"), local Prometheus on :$PROM_PORT (no generators)"
printf '%s\n' "${TARGETS[@]}"

cleanup
printf '%s\n' "${TARGETS[@]}" | "$CFG/gen_prom_config.sh" > "$NATIVE/hardware.yml"
"$SCRIPTS/prometheus/start.sh" "$NATIVE/hardware.yml" "$PROM_PORT"

# measure.sh does its own SETTLE then prints one CSV row (label first); prepend the target count
row=$("$SCRIPTS/prometheus/measure.sh" real)
echo "real,$N,${row#*,}" >> "$OUT"
echo "   real,$N,${row#*,}"
echo "-> $OUT"
