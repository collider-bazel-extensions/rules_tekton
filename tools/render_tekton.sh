#!/usr/bin/env bash
# Maintainer flow:
#   1. Edit tools/versions.bzl::TEKTON_VERSIONS — add or update the
#      target version's URL + sha256 (or pass them inline).
#   2. tools/render_tekton.sh <version>
#      Verifies the upstream release.yaml's sha256 matches the pin
#      and copies it to private/manifests/tekton.yaml. Commit.
#
# This script does NOT run under bazel — it just curls the upstream
# release.yaml directly. There's no helm chart to render; Tekton ships
# a single kubectl-applyable manifest.
set -euo pipefail

VERSION="${1:?usage: tools/render_tekton.sh <version> (e.g. v1.11.1)}"

# Pull URL + sha256 out of versions.bzl. The file's a Starlark dict
# but we only need two strings — awk is fine and keeps this script
# bazel-free.
url=$(awk -v v="\"$VERSION\":" '
    $0 ~ v { in_block=1; next }
    in_block && /"url":/ { gsub(/[",]/,""); print $2; exit }
' tools/versions.bzl)
sha=$(awk -v v="\"$VERSION\":" '
    $0 ~ v { in_block=1; next }
    in_block && /"sha256":/ { gsub(/[",]/,""); print $2; exit }
' tools/versions.bzl)

[[ -n "$url" && -n "$sha" ]] || {
  echo "render_tekton: version '$VERSION' not in tools/versions.bzl" >&2
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "render_tekton: fetching $url"
curl -sLfo "$tmp" "$url"

got_sha=$(sha256sum "$tmp" | awk '{print $1}')
if [[ "$got_sha" != "$sha" ]]; then
  echo "render_tekton: sha256 mismatch" >&2
  echo "  expected: $sha" >&2
  echo "  got:      $got_sha" >&2
  echo "Update tools/versions.bzl with the new sha if the upstream changed intentionally." >&2
  exit 1
fi

dest="private/manifests/tekton.yaml"
mv "$tmp" "$dest"
trap - EXIT

lines=$(wc -l < "$dest")
echo "render_tekton: wrote $dest"
echo "  version: $VERSION"
echo "  sha256:  $got_sha"
echo "  lines:   $lines"
