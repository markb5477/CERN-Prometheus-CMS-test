#!/usr/bin/env bash
# Open one multiplexed master ssh connection per configured host.
# You type the password by hand, once per host; nothing is stored on disk.
# Every later rsh/scp_pass call reuses these sockets without re-authenticating.
# Sessions stay alive $SSH_PERSIST (default 12h) -- long enough for a soak run.
# Tear them down early with: scripts/config/login.sh --logout
CFG="$(cd "$(dirname "$0")" && pwd)"
source "$CFG/common.sh"; load_secrets; source "$CFG/topology.sh"

hosts=()
for h in "${LOAD_ARR[@]}" "${COLL_ARR[@]}"; do
  case " ${hosts[*]} " in *" $h "*) ;; *) hosts+=("$h") ;; esac
done

if [ "${1:-}" = "--logout" ]; then
  for h in "${hosts[@]}"; do
    ssh -O exit -o "ControlPath=$SSH_MUX" "$SSH_USER@$h" 2>/dev/null \
      && echo "closed $h" || echo "no session $h"
  done
  exit 0
fi

if [ "${1:-}" = "--status" ]; then
  for h in "${hosts[@]}"; do
    ssh_live "$h" && echo "live    $h" || echo "closed  $h"
  done
  exit 0
fi

for h in "${hosts[@]}"; do
  if ssh_live "$h"; then echo "already live: $h"; continue; fi
  echo "== opening master session to $h (enter your CERN password) =="
  # -M -N -f: become a master, run no command, drop to background once authenticated.
  ssh -M -N -f -o ControlPersist="$SSH_PERSIST" "${SSH_OPTS[@]}" "$SSH_USER@$h" \
    || { echo "FAILED to open session to $h" >&2; exit 1; }
  ssh_live "$h" && echo "  ok, session live (expires in $SSH_PERSIST)"
done
echo
echo "sessions ready. verify with: scripts/config/check.sh"
