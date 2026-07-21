#!/usr/bin/env bash
# ON THE LAPTOP: pull the raw CSVs down from the controller for analysis.
#
# The DIST scenarios run on the controller (aethon) and write their CSVs there, but the plot
# scripts and their matplotlib live here. This is a plain scp with an interactive password -
# the laptop has no multiplexed master (that is login.sh's job on the controller), so expect
# one prompt. Nothing is stored.
#
# Existing local files are archived by mtime rather than overwritten, so re-fetching mid-run
# can never destroy an earlier download.
#
# Usage:  ./analysis/fetch_data.sh                  # everything in scripts/data
#         ./analysis/fetch_data.sh soak_dist.csv    # just one file
# CONTROLLER / SSH_USER / REMOTE_ROOT override the defaults below.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$(cd "$HERE/.." && pwd)/data"

CONTROLLER=${CONTROLLER:-aethon.cern.ch}
SSH_USER=${SSH_USER:-mbrandt}
REMOTE_ROOT=${REMOTE_ROOT:-/home/mbrandt/testingPrometheus/CERN-Prometheus-CMS-test}
PAT=${1:-'*.csv'}

mkdir -p "$DATA"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo ">> fetching $PAT from $CONTROLLER"
# -O forces the legacy scp protocol: some newer sftp-backed builds refuse remote globs.
scp -O "$SSH_USER@$CONTROLLER:$REMOTE_ROOT/scripts/data/$PAT" "$TMP/" || {
  echo "fetch failed - check CONTROLLER/SSH_USER/REMOTE_ROOT" >&2; exit 1; }

for f in "$TMP"/*.csv; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  if [ -f "$DATA/$b" ] && ! cmp -s "$f" "$DATA/$b"; then
    mv "$DATA/$b" "$DATA/${b%.csv}-local-$(date -r "$DATA/$b" +%Y%m%d-%H%M%S).csv"
    echo "   archived previous $b"
  fi
  cp "$f" "$DATA/$b"
  echo "   $b ($(wc -l < "$DATA/$b") lines)"
done
echo "-> $DATA"
