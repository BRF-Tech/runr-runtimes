#!/usr/bin/env bash
# Tests the built-in runtimes of RunR's catalog (runtimes/<id>/): every directory has its manifest
# (runtime.yaml, id = the directory) and a Dockerfile, every "@file" its build.files reference is
# next to it (the API inlines them when it bundles the catalog), the manifest names the image this
# repository publishes for it (versionDiscovery of exec-<id>, or for a WebAssembly runtime the
# exec-wasm-<lang>:<version> its versions list, the tag ci.sh wasm builds), and every WebAssembly
# build image pins one and the same Spin CLI, whichever the pin is: the language bot moves it in all
# of them at once (ci/lang-bot.sh wasm-bump spin), and RunR's suites on the candidates (test-wasm,
# test-images) show whether RunR's Spin shim runs what it builds. The JSON Schema of the manifests
# is checked by the catalog job of the CI workflow.
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

# The Spin CLI of the WebAssembly build images: wasm-exec's pin (the toolchain image), which every
# other one has too
SPIN_VERSION="$(sed -n 's/^ARG SPIN_VERSION=//p' "$here/runtimes/wasm-exec/Dockerfile")"
[[ "$SPIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "wasm-exec: no ARG SPIN_VERSION=X.Y.Z (${SPIN_VERSION:-none})"

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
      versions="$(wasm_runtime_versions "${id#wasm-}")"
      [ -n "$versions" ] || fail "${id}: no version"
      # every version: its image is exec-<id>:<version>, its Dockerfile (the version's own directory
      # or the runtime's) pins wasm-exec's Spin CLI
      for version in $versions; do
        grep -qE "^[[:space:]]+image:[[:space:]]*\"?ghcr\.io/brf-tech/runr/exec-${id}:${version}\"?[[:space:]]*$" "$manifest" \
          || fail "${id}: version ${version} is not ghcr.io/brf-tech/runr/exec-${id}:${version}"
        vdir="$(wasm_version_dir "${id#wasm-}" "$version")"
        [ "$(grep -c '^ARG SPIN_VERSION=' "${vdir}/Dockerfile")" = 1 ] && grep -qxF "ARG SPIN_VERSION=${SPIN_VERSION}" "${vdir}/Dockerfile" \
          || fail "${id} ${version}: the Dockerfile does not pin the Spin CLI of wasm-exec (${SPIN_VERSION}): $(grep '^ARG SPIN_VERSION=' "${vdir}/Dockerfile" || echo none)"
      done
      # a directory with a Dockerfile (a version's: 4.2/) belongs to a version of the manifest
      for vdir in "$dir"/*/; do
        [ -f "${vdir}Dockerfile" ] || continue
        [[ $'\n'"${versions}"$'\n' == *$'\n'"$(basename "$vdir")"$'\n'* ]] || fail "${id}: $(basename "$vdir")/ is not a version of runtime.yaml"
      done
      ;;
    *)
      grep -qE "^[[:space:]]+repository:[[:space:]]*ghcr\.io/brf-tech/runr/exec-${id}[[:space:]]*$" "$manifest" \
        || fail "${id}: versionDiscovery does not read ghcr.io/brf-tech/runr/exec-${id}"
      ;;
  esac
  count=$((count + 1))
done
[ "$count" = 15 ] || fail "${count} runtimes in runtimes/, the catalog has 15"
echo "ok - catalog: ${count} runtimes, their files, images and one Spin CLI (${SPIN_VERSION}) in every WebAssembly image"
