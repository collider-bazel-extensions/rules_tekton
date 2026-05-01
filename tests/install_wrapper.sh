#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/tekton_install_bin.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: tekton_install_bin not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "install_wrapper: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Diagnostic dump on install failure. Same shape as rules_backstage's
# install_wrapper — when the kubectl_apply launcher times out on a
# Deployment Available wait, it logs "condition not met" forever
# without describing the pod or capturing logs. This trap pulls
# pod state + controller logs (current AND --previous, to catch
# crash-loops) so future debugging has signal to work with.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper: install_bin exited $rc — dumping cluster state =====" >&2
  for ns in tekton-pipelines tekton-pipelines-resolvers; do
    echo "---- pods/deploy/sts (-n $ns) ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n "$ns" get pods,deploy,sts -o wide >&2 || true
    echo "---- describe deployments (-n $ns) ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n "$ns" describe deployments >&2 || true
    echo "---- logs deploy/* --tail=200 (-n $ns) ----" >&2
    for d in $("$KUBECTL" --kubeconfig="$KUBECONFIG" -n "$ns" get deploy -o name 2>/dev/null); do
      echo "    -- $d --" >&2
      "$KUBECTL" --kubeconfig="$KUBECONFIG" -n "$ns" logs "$d" --all-containers --tail=200 >&2 || true
      "$KUBECTL" --kubeconfig="$KUBECONFIG" -n "$ns" logs "$d" --all-containers --previous --tail=200 >&2 || true
    done
  done
  exit "$rc"
}
trap on_install_fail ERR

# `exec` replaces this shell — the trap won't fire. Run as a child so
# the trap stays active.
"$INSTALL_BIN"
