#!/usr/bin/env bash
# Run every test in order. Backgroundable:  nohup ./scripts/run_all.sh > run.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."

# Refuse to start if a run is already live; concurrent runs corrupt each other.
if pgrep -x avalanche >/dev/null || pgrep -x prometheus >/dev/null || pgrep -f run_all.sh | grep -qv $$; then
  echo "a test run is already active; stop it first:" >&2
  echo "  pkill -9 -f run_all.sh; pkill -9 -x avalanche; pkill -9 -x prometheus" >&2
  exit 1
fi

echo "host: $(uname -m), $(nproc) cores"; free -h | awk 'NR<=2'
for t in sensors ramp sweep stress spike soak; do
  echo; echo "##### $t #####"; "scripts/$t.sh"
done
echo; echo "done; plot with: python3 scripts/plot.py"
