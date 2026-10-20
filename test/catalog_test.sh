#!/usr/bin/env bash
# Tests the built-in runtimes of RunR's catalog (runtimes/<id>/): every directory has its manifest
# (runtime.yaml, id = the directory) and a Dockerfile, every "@file" its build.files reference is
# next to it (the API inlines them when it bundles the catalog), the manifest names the image this
# repository publishes for it (versionDiscovery of exec-<id>, or for a WebAssembly runtime the
# exec-wasm-<lang>:<version> its versions list, the tag ci.sh wasm builds), and every WebAssembly
# build image pins the Spin CLI of the Spin runtime RunR's shim embeds. The JSON Schema of the
# manifests is checked by the catalog job of the CI workflow.
#
#   bash test/catalog_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/build-wasm.sh
source "$here/lib/build-wasm.sh"

# The Spin CLI of the runtime RunR's shim embeds (containerd-shim-spin, BRF-Tech/runr's
# runtime/wasm-shim-spin): every WebAssembly build image ships the same one
SPIN_VERSION=4.1.0

count=0
for manifest in "$here"/runtimes/*/runtime.yaml; do
  dir="$(dirname "$manifest")"
  id="$(basename "$dir")"
  [ "$(sed -n 's/^id:[[:space:]]*//p' "$manifest")" = "$id" ] || fail "${id}: runtime.yaml has another id"
  [ -f "${dir}/Dockerfile" ] || fail "${id}: no Dockerfile"

  # "@file" references (build.files), each next to the manifest
  while IFS= read -r ref; do
    [ -f "${dir}/${ref}" ] || fail "${id}: build.files references @${ref}, which is not in runtimes/${id}"
  done < <(grep -oE '"@[^"]+"' "$manifest" | tr -d '"@')

  case "$id" in
    wasm-*)
      version="$(wasm_runtime_version "${id#wasm-}")"
      [ -n "$version" ] || fail "${id}: no version"
      grep -qE "^[[:space:]]+image:[[:space:]]*\"?ghcr\.io/brf-tech/runr/exec-${id}:${version}\"?[[:space:]]*$" "$manifest" \
        || fail "${id}: version ${version} is not ghcr.io/brf-tech/runr/exec-${id}:${version}"
      grep -qxF "ARG SPIN_VERSION=${SPIN_VERSION}" "${dir}/Dockerfile" || fail "${id}: the Dockerfile does not pin Spin ${SPIN_VERSION}"
      ;;
    *)
      grep -qE "^[[:space:]]+repository:[[:space:]]*ghcr\.io/brf-tech/runr/exec-${id}[[:space:]]*$" "$manifest" \
        || fail "${id}: versionDiscovery does not read ghcr.io/brf-tech/runr/exec-${id}"
      ;;
  esac
  count=$((count + 1))
done
[ "$count" = 11 ] || fail "${count} runtimes in runtimes/, the catalog has 11"
echo "ok - catalog: ${count} runtimes, their files, images and the Spin CLI ${SPIN_VERSION}"
