#!/usr/bin/env bash
# Copy the prebuilt binaries + node scripts to every CERN host that needs them.
# The amd64 bin/{avalanche,prometheus} are gitignored, so they must be pushed here.
# secrets.env is deliberately NOT staged (controller-only config stays on the controller).
CFG="$(cd "$(dirname "$0")" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"
require_ssh "${LOAD_ARR[@]}" "${COLL_ARR[@]}"
[ -x "$BIN/prometheus" ] && [ -x "$BIN/avalanche" ] || { echo "local bin/ missing prometheus/avalanche" >&2; exit 1; }

# build a scrubbed copy of the scripts tree (no secrets.env) to ship
STAGE="$NATIVE/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -r "$SCRIPTS/config" "$SCRIPTS/avalanche" "$SCRIPTS/prometheus" "$STAGE/"
rm -f "$STAGE/config/secrets.env"

for h in "${LOAD_ARR[@]}" "${COLL_ARR[@]}"; do
  echo ">> staging to $h:$REMOTE_ROOT"
  rsh "$h" "mkdir -p '$REMOTE_ROOT/bin' '$REMOTE_ROOT/scripts' '$REMOTE_ROOT/.native-data'"
  scp_pass "$BIN/avalanche" "$BIN/prometheus" "$SSH_USER@$h:$REMOTE_ROOT/bin/" >/dev/null
  scp_pass -r "$STAGE/config" "$STAGE/avalanche" "$STAGE/prometheus" \
    "$SSH_USER@$h:$REMOTE_ROOT/scripts/" >/dev/null
  rsh "$h" "chmod +x '$REMOTE_ROOT'/bin/* '$REMOTE_ROOT'/scripts/*/*.sh 2>/dev/null; true"
done
rm -rf "$STAGE"
echo "staged (secrets.env withheld)."
