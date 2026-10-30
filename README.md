# rules_tekton

Hermetic [Tekton Pipelines](https://tekton.dev/) install for Bazel
test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`tekton_install` is a macro emitting a `kubectl_apply` target
pre-configured with Tekton's pinned `release.yaml` and the right
wait shape (controller + webhook + events-controller Deployments,
4 CRDs).

```python
load("@rules_tekton//:defs.bzl", "tekton_install", "tekton_health_check")

tekton_install(name = "tekton_install_bin")          # default ns: tekton-pipelines
tekton_health_check(name = "tekton_health_bin")
```

That's the whole API. Tekton is a Kubernetes-native CI/CD
framework — `Task`s define units of work as containers, `TaskRun`s
execute them, `Pipeline`s compose `Task`s into DAGs, `PipelineRun`s
execute pipelines. The smoke applies a `Task` + `TaskRun` fixture
(busybox `echo` step) and waits for the TaskRun's `Succeeded`
condition.

**Pinned versions:** Tekton Pipelines `v1.11.1`, fetched from
`github.com/tektoncd/pipeline/releases/download/v1.11.1/release.yaml`,
sha256-pinned. The render is committed as
`@rules_tekton//private/manifests:tekton.yaml`.

> **Multi-namespace install.** Tekton's `release.yaml` spans two
> namespaces (`tekton-pipelines` for the controllers,
> `tekton-pipelines-resolvers` for the remote-ref resolver) plus
> cluster-scoped CRDs/RBAC. `tekton_install` uses
> `kubectl_apply(apply_namespace_flag = False)` (rules_kubectl ≥
> 0.2.0) so each resource lands in its declared namespace —
> kubectl rejects multi-ns YAML when `-n` is set.

> **Wait shape covers `tekton-pipelines` only.** The install waits
> on the three Deployments in `tekton-pipelines`
> (`tekton-pipelines-controller`, `tekton-pipelines-webhook`,
> `tekton-events-controller`) plus the four consumer-facing CRDs.
> The `tekton-pipelines-remote-resolvers` Deployment in the second
> namespace is **not** waited on — it's only needed for `bundle:` /
> `git:` / `cluster:` taskRefs, and rules_kubectl's wait commands
> are single-namespace today. Consumers using remote resolvers
> should add a separate `kubectl_apply_health_check` for
> `tekton-pipelines-resolvers`.

**Supported platforms (v0.1):** any platform where rules_kubectl
runs. Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Macros](#macros)
- [Configuring Tekton](#configuring-tekton)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_tekton", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl)
≥ 0.2.0 (the `apply_namespace_flag` attribute that lets multi-ns
YAML apply cleanly is a v0.2.0 feature).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_tekton//:defs.bzl", "tekton_install", "tekton_health_check")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.35")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Tekton.
tekton_install(name = "tekton_install_bin")
tekton_health_check(name = "tekton_health_bin")
sh_binary(name = "tekton_install_wrapper", srcs = ["install_wrapper.sh"], data = [":tekton_install_bin"])
sh_binary(name = "tekton_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":tekton_health_bin"])

itest_service(
    name = "tekton_svc",
    exe = ":tekton_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":tekton_health_wrapper",
)

# 3. Your test workload — see `tests/` for a Task + TaskRun smoke.
```

The wrapper scripts source the kind cluster's env file (so
`KUBECONFIG` / `KUBECTL` cross the `exec` boundary) and forward to
the install / health binaries. Same shape every operator rule's
smoke test in this family uses.

---

## Macros

### `tekton_install`

```python
tekton_install(
    name = "tekton_install_bin",
    namespace = "tekton-pipelines",   # default — also where waits look
    wait_timeout = "300s",            # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_tekton//private/manifests:tekton.yaml`.
- `apply_namespace_flag = False` — multi-namespace YAML.
- `server_side = True`.
- `wait_for_deployments = ["tekton-pipelines-controller",
  "tekton-pipelines-webhook", "tekton-events-controller"]`.
- `wait_for_crds = ["tasks.tekton.dev", "taskruns.tekton.dev",
  "pipelines.tekton.dev", "pipelineruns.tekton.dev"]`.
- `wait_timeout = "300s"`.

Drops into `itest_service.exe`. Pass extra
`wait_for_deployments` / `wait_for_rollouts` / `wait_for_crds`
through; they're concatenated onto the defaults.

### `tekton_health_check`

```python
tekton_health_check(name = "tekton_health_bin", namespace = "tekton-pipelines")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Configuring Tekton

Tekton's behavior is configured via ConfigMaps in the
`tekton-pipelines` namespace. The most commonly tuned ones:

| ConfigMap | Use |
|---|---|
| `feature-flags` | Enable / disable alpha features (`enable-api-fields`, `enable-tekton-oci-bundles`, etc.). |
| `config-defaults` | Default service account, default Pod template, default timeout for TaskRuns / PipelineRuns. |
| `config-logging` | zap log level + encoding for the controller. |
| `config-leader-election-controller` | HA tuning (lease duration, renew deadline). |

Production consumers typically:

1. Apply Tekton via this rule set's `tekton_install`.
2. Apply their own ConfigMaps (or a `kustomize` overlay) **after**
   the install — patching the chart-default ConfigMaps to flip
   feature flags, raise default timeouts, etc.

For Tekton Triggers / Dashboard / Chains (separate installs from
the same project) see the [Help wanted](#help-wanted) list — those
are deferred to v0.2+ candidate rule sets.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Tekton manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_tekton.sh <version>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Tekton container images | Pulled at runtime. `gcr.io/tekton-releases/...` (controller, webhook, events-controller, remote-resolvers, plus per-step `entrypoint` + `nop` sidecars). | Future: pre-load via `kind_cluster.images`. |
| `busybox:1.36` (smoke fixture) | Pulled at runtime. | Smallest-possible step image for the smoke. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned Tekton version: edit `tools/versions.bzl`,
  run `bash tools/render_tekton.sh <new-version>`, commit the
  refreshed `private/manifests/tekton.yaml`.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- `Pipeline` + `PipelineRun` smoke (multi-task DAG, currently only
  the single-Task path is exercised)
- `Workspace` smoke (PVC-backed shared storage between Tasks)
- A separate `rules_tekton_triggers` for the Triggers project
  (EventListener + TriggerBinding + TriggerTemplate)
- A separate `rules_tekton_dashboard` for the dashboard
- A separate `rules_tekton_chains` for supply-chain attestation
- Wait on the resolver Deployment in `tekton-pipelines-resolvers`
  (blocked on rules_kubectl growing namespace-qualified wait
  syntax — already noted as a v0.3 candidate there)
