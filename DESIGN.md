# DESIGN — rules_tekton

## Why a rule set, not a generic apply?

Tekton's `release.yaml` is multi-namespace and 27k lines. Every
consumer would otherwise duplicate (a) the right wait shape (which
Deployments / CRDs to gate on) and (b) the `apply_namespace_flag = False`
incantation. A two-macro wrapper (`tekton_install` /
`tekton_health_check`) covers both and matches the family pattern
(rules_loki, rules_grafana, rules_keda, rules_backstage).

## Why no helm chart?

Tekton ships a single `release.yaml` per release as the canonical
install path — there's no maintainer-blessed helm chart. Community
helm charts exist but they wrap the same release.yaml, so going
direct is simpler and removes one moving part.

## Why pin via curl + sha-check, not `http_file`?

The render is bazel-free intentionally. `http_file` would either
require `use_repo` plumbing for consumers (which they shouldn't
inherit — they only consume the committed manifest) or a
maintainer-only bzlmod extension. A 30-line shell script with a
sha verification covers it; the maintainer flow is `bash
tools/render_tekton.sh <version>` and that's it. Same pattern would
work for any release.yaml-based project.

## Why wait only on `tekton-pipelines` namespace Deployments?

The four Deployments split as:

```
tekton-pipelines/             tekton-pipelines-controller   ← waited
tekton-pipelines/             tekton-pipelines-webhook      ← waited
tekton-pipelines/             tekton-events-controller      ← waited
tekton-pipelines-resolvers/   tekton-pipelines-remote-resolvers ← NOT waited
```

The remote-resolvers Deployment is for `bundle:` / `git:` /
`cluster:` `taskRef`s only. The smoke uses a local `taskRef` so it
doesn't depend on the resolver. rules_kubectl's wait commands are
single-namespace today; waiting on the resolver Deployment would
require either splitting the install into two `kubectl_apply`
targets (rules_keda's pattern, already obsoleted by
`apply_namespace_flag`) or extending rules_kubectl to support
namespace-qualified waits (a v0.3 candidate). The single-namespace
wait is fine for the v0.1 smoke + most consumers.

Production consumers using remote refs should add a separate
`kubectl_apply_health_check` for `tekton-pipelines-resolvers`.

## Why a `Task` + `TaskRun` smoke instead of `Pipeline` + `PipelineRun`?

Same reasoning as rules_loki's "single log push and read instead of
multi-stream":

- **Smaller surface.** A `TaskRun` gates on the controller, the
  webhook (admission validation), Pod creation, Pod completion,
  status update, and condition propagation. That's the value-add.
- **`Pipeline` + `PipelineRun` adds DAG resolution + per-Task
  ordering** — extra surface that's a separate concern. v0.2 candidate.
- **Workspaces adds PVC mounting** — also extra surface. v0.2.

The v0.1 smoke proves Tekton works end-to-end without sprawling.

## Why busybox?

Small image (~2 MB), fast pull (typically <5s on cold CI), and the
`echo` step has no dependencies. Compare with the alternatives:

- `alpine` — also small but a bit larger; no advantage for `echo`.
- A specific Tekton catalog Task — depends on remote refs + the
  Tekton Hub, which the v0.1 smoke deliberately avoids.

## Versioning

`v1.11.1` is current as of 2026-05-01. Tekton Pipelines went 1.0 in
2024 (around v0.62 → v1.0). The v1 API is stable; v1beta1 still
served but deprecated in docs.

## Multi-namespace install

`kubectl_apply(apply_namespace_flag = False)` is the load-bearing
attribute. It's a v0.2.0 feature in rules_kubectl; rules_tekton
v0.1 takes hard dependency on rules_kubectl ≥ 0.2.0 via
`bazel_dep` + `git_override`.

The pattern this obsoletes (rules_keda's three-target split) is
documented in rules_kubectl's release notes.
