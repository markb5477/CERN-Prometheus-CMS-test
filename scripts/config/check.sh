#!/usr/bin/env bash
# Connectivity smoke test: ssh into every configured host and print its specs.
# Run this before any real DIST run to confirm the ssh sessions + hosts work.
CFG="$(cd "$(dirname "$0")" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
require_ssh "${LOAD_ARR[@]}" "${COLL_ARR[@]}"
ok=1
for h in "${LOAD_ARR[@]}" "${COLL_ARR[@]}"; do
  echo "== $h =="
  if rsh "$h" 'printf "  host=%s arch=%s cores=%s\n" "$(hostname)" "$(uname -m)" "$(nproc)"; free -h | awk "NR==2{printf \"  mem=%s avail=%s\n\", \$2, \$7}"; test -x '"$REMOTE_ROOT"'/bin/prometheus && echo "  binaries: staged" || echo "  binaries: MISSING (run config/stage.sh)"'; then :; else
    echo "  UNREACHABLE"; ok=0
  fi
done
[ "$ok" = 1 ] && echo "all hosts reachable" || { echo "some hosts unreachable"; exit 1; }
