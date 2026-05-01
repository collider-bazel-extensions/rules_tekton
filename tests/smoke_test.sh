#!/usr/bin/env bash
# Tekton TaskRun reconciliation smoke.
# Strategy:
#
#   1. Apply tests/fixtures/smoke-task.yaml — Namespace + Task + TaskRun.
#   2. Wait for the TaskRun's `Succeeded` condition to be set (any
#      status). Then check the status — `True` is success, `False`
#      means the step failed.
#   3. As a belt-and-suspenders read, dump the TaskRun's
#      `.status.conditions` and the underlying Pod's logs. Failure
#      diagnostics drop straight into the test log.
#
# Proves end-to-end: webhook validates the TaskRun on admission +
# controller reconciles TaskRun → Pod + Pod runs the busybox echo
# step + Pod completion + controller updates TaskRun status +
# condition propagation.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="tekton-smoke"
TASKRUN="hello-run"

# Locate the fixture in runfiles. sh_test puts it at _main/tests/fixtures/.
FIXTURE=""
for cand in \
  "${RUNFILES_DIR:-}/_main/tests/fixtures/smoke-task.yaml" \
  "$(dirname "$0").runfiles/_main/tests/fixtures/smoke-task.yaml" \
  "tests/fixtures/smoke-task.yaml"; do
  [[ -f "$cand" ]] && { FIXTURE="$cand"; break; }
done
[[ -n "$FIXTURE" ]] || { echo "smoke_test: cannot find smoke-task.yaml in runfiles" >&2; exit 1; }

echo "smoke_test: applying fixture $FIXTURE"
"${KCTL[@]}" apply -f "$FIXTURE" >/dev/null

# Wait for the Succeeded condition to be set. `kubectl wait
# --for=condition=Succeeded` will exit 0 as soon as the condition's
# status flips off Unknown — i.e., when the TaskRun finishes, success
# OR failure. The follow-up check distinguishes.
echo "smoke_test: waiting for TaskRun/$TASKRUN to finish (up to 180s)"
if ! "${KCTL[@]}" -n "$NS" wait "taskrun/$TASKRUN" \
       --for=condition=Succeeded --timeout=180s >/dev/null 2>&1; then
  # Even if --timeout fires, fall through to the status check —
  # the condition might just still be Unknown. The status read
  # below catches that case explicitly.
  echo "smoke_test: kubectl wait exited non-zero (condition may still be Unknown)" >&2
fi

status=$("${KCTL[@]}" -n "$NS" get "taskrun/$TASKRUN" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
reason=$("${KCTL[@]}" -n "$NS" get "taskrun/$TASKRUN" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)
message=$("${KCTL[@]}" -n "$NS" get "taskrun/$TASKRUN" \
    -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' 2>/dev/null || true)

if [[ "$status" != "True" ]]; then
  echo "smoke_test: FAIL — TaskRun/$TASKRUN did not succeed" >&2
  echo "  status:  ${status:-<unset>}" >&2
  echo "  reason:  ${reason:-<unset>}" >&2
  echo "  message: ${message:-<unset>}" >&2
  echo "---- TaskRun yaml ----" >&2
  "${KCTL[@]}" -n "$NS" get "taskrun/$TASKRUN" -o yaml >&2 || true
  echo "---- Pod logs (any pod owned by TaskRun) ----" >&2
  pod=$("${KCTL[@]}" -n "$NS" get pods -l "tekton.dev/taskRun=$TASKRUN" -o name 2>/dev/null | head -1)
  if [[ -n "$pod" ]]; then
    "${KCTL[@]}" -n "$NS" logs "$pod" --all-containers --tail=200 >&2 || true
  fi
  echo "---- tekton-pipelines-controller logs (--tail=80) ----" >&2
  "${KCTL[@]}" -n tekton-pipelines logs deploy/tekton-pipelines-controller --tail=80 >&2 || true
  exit 1
fi

echo "smoke_test: OK — TaskRun/$TASKRUN Succeeded=True (reason=$reason)"
