"""Public API for rules_tekton."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# In v0.1's pinned release (Tekton Pipelines v1.11.1), the `release.yaml`
# emits four Deployments across two namespaces:
#
#   tekton-pipelines/             tekton-pipelines-controller
#   tekton-pipelines/             tekton-pipelines-webhook
#   tekton-pipelines/             tekton-events-controller
#   tekton-pipelines-resolvers/   tekton-pipelines-remote-resolvers
#
# The wait shape only covers the three Deployments in the primary
# namespace — that's what `Task` + `TaskRun` reconciliation needs. The
# resolver controller in the second namespace is for `bundle:` /
# `git:` / `cluster:` taskRefs (remote refs), and rules_kubectl's
# wait commands are single-namespace today (a v0.3 candidate over there).
# Consumers using remote resolvers should add a separate
# `kubectl_apply_health_check` for tekton-pipelines-resolvers.
_TEKTON_DEPLOYS = [
    "tekton-pipelines-controller",
    "tekton-pipelines-webhook",
    "tekton-events-controller",
]

# CRDs the Pipelines controller registers. Listing the consumer-facing
# ones (Task + TaskRun + Pipeline + PipelineRun) gives the install wait
# enough to gate on; the others (CustomRun, StepAction, etc.) come up
# in the same reconcile cycle.
_TEKTON_CRDS = [
    "tasks.tekton.dev",
    "taskruns.tekton.dev",
    "pipelines.tekton.dev",
    "pipelineruns.tekton.dev",
]

def tekton_install(
        name,
        namespace = "tekton-pipelines",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned Tekton Pipelines release.yaml into the cluster
    and block until the controller / webhook / events-controller are
    Available before idling.

    Drops into `itest_service.exe`. Tekton's `release.yaml` is
    multi-namespace (`tekton-pipelines` for the controllers,
    `tekton-pipelines-resolvers` for the remote-ref resolver, plus
    cluster-scoped CRDs/RBAC). This macro applies it with
    `apply_namespace_flag = False` (rules_kubectl ≥ 0.2.0) so each
    resource lands in its own namespace — kubectl rejects multi-ns YAML
    when `-n` is set.

    The `namespace` attribute is still used as the default for the
    wait commands (Deployment lookups). Override is rarely useful;
    Tekton's manifest hard-codes `tekton-pipelines` and that string
    appears in dozens of cluster-scoped RBAC bindings.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_tekton//private/manifests:tekton.yaml"],
        namespace = namespace,
        apply_namespace_flag = False,  # multi-namespace YAML
        server_side = True,
        wait_for_deployments = list(_TEKTON_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_TEKTON_CRDS) + list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def tekton_health_check(
        name,
        namespace = "tekton-pipelines",
        **kwargs):
    """Readiness probe paired with `tekton_install`.

    Drops into `itest_service.health_check`. Same wait shape with
    `--timeout=0s`.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_TEKTON_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = list(_TEKTON_CRDS) + list(extra_crds),
        **kwargs
    )
