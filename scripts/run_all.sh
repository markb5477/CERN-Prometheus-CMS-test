#!/usr/bin/env bash
# Top-level driver. Runs the single-node baseline locally, then (if secrets.env is set up)
# the two-node twin + shard tests over SSH, then renders every graph.
#   Backgroundable:  nohup ./scripts/run_all.sh > run.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
S=scripts

# refuse to start if a local run is already live (concurrent runs corrupt each other)
if pgrep -x avalanche >/dev/null || pgrep -x prometheus >/dev/null || pgrep -f run_all.sh | grep -qv $$; then
  echo "a test run is already active; stop it first:" >&2
  echo "  pkill -9 -f run_all.sh; pkill -9 -x avalanche; pkill -9 -x prometheus" >&2
  exit 1
fi

echo "host: $(uname -m), $(nproc) cores"; free -h | awk 'NR<=2'

echo; echo "######## baseline (single-node, co-located) ########"
for t in modules ramp sweep stress spike soak cms; do
  echo; echo "##### $t #####"; "$S/scenarios/baseline/$t.sh"
done

# pull-vs-push diagnostic: opt-in (RUN_PUSH=1), since it's diagnostic, not part of the core sweep.
if [ "${RUN_PUSH:-0}" = 1 ]; then
  echo; echo "##### push (pull-vs-push diagnostic) #####"; "$S/scenarios/baseline/push.sh"
else
  echo; echo "(skipping push diagnostic: set RUN_PUSH=1 to enable)"
fi

if [ -f "$S/config/secrets.env" ]; then
  echo; echo "######## two-node (twin + functional sharding) ########"
  "$S/config/check.sh" && "$S/config/stage.sh" && "$S/scenarios/twin.sh" && "$S/scenarios/shard.sh"
else
  echo; echo "(skipping two-node tests: create $S/config/secrets.env to enable)"
fi

if [ -f "$S/config/targets.real" ]; then
  echo; echo "######## real hardware (no generators) ########"
  "$S/scenarios/hardware.sh"
else
  echo; echo "(skipping real-hardware test: create $S/config/targets.real to enable)"
fi

echo; echo "######## plots ########"
for p in plot_suite plot_cms plot_twin plot_shard plot_hardware plot_push; do python3 "$S/analysis/$p.py"; done
echo "done."
