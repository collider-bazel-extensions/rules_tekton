"""Maintainer-only: pinned Tekton Pipelines releases.

Edit + run `tools/render_tekton.sh <version>` to re-render the
committed `private/manifests/tekton.yaml`.

The URL pattern is `https://github.com/tektoncd/pipeline/releases/
download/<VERSION>/release.yaml`. (The Tekton docs also point at
`storage.googleapis.com/tekton-releases/pipeline/previous/...`,
but that URL pattern returns 404 for newer releases — GitHub's
release artifacts are the authoritative source.)
"""

TEKTON_VERSIONS = {
    "v1.11.1": {
        "url": "https://github.com/tektoncd/pipeline/releases/download/v1.11.1/release.yaml",
        "sha256": "59bc95d327828a95a9e8fa550b30108886b736414e8f7e9271a4abd80d8b2adb",
    },
}
