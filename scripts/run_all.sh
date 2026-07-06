#!/usr/bin/env bash
# Run every test in order. Backgroundable:  nohup ./scripts/run_all.sh > run.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."

echo "host: $(uname -m), $(nproc) cores"; free -h | awk 'NR<=2'
for t in sensors ramp sweep stress spike soak; do
  echo; echo "##### $t #####"; "scripts/$t.sh"
done
echo; echo "done; plot with: python3 scripts/plot.py"
