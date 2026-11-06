#!/usr/bin/env bash
# Tests the language bot's gate of the publish (LANG_GATE, lib/patch.sh) and the test build of one
# version (ci.sh build RUNTIME --version=X.Y) without Docker or a registry: docker and the registry
# are shell functions as in test/patch_test.sh, the tested versions a throwaway runtimes directory.
# Checks that under the gate a routine build of an upstream version the floating tag does not run
# is held (nothing pushed, the published patch stays) until runtimes/<runtime>/tested-versions
# lists it, that a rebuild of the version a tag runs and a patch above routine are never held, that
# without the gate nothing is held, and that --version builds that one version and refuses one
# that is not current.
#
#   bash test/gate_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip: gate_test needs jq"; exit 0; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/build.sh
source "$here/lib/build.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/patch.sh
source "$here/lib/patch.sh"
REGISTRY="ghcr.io/brf-tech/runr"
export PATCH_NOW="2026-11-07T01:00:00Z"
unset GITHUB_ACTIONS
export RUNTIMES_DIR="$tmp/runtimes"
mkdir -p "$RUNTIMES_DIR/php"
cp "$here/runtimes/php/tested-versions" "$RUNTIMES_DIR/php/tested-versions"
cp -r "$here/runtimes/php/." "$RUNTIMES_DIR/php/" 2>/dev/null || true

log="$tmp/calls"
docker() {
  echo "docker $*" >> "$log"
  local arg prev="" digest
  digest="sha256:$(printf '%064d' 1)"
  for arg in "$@"; do
    if [ "$prev" = --metadata-file ]; then printf '{"containerimage.digest": "%s"}' "$digest" > "$arg"; fi
    prev="$arg"
  done
}
ensure_buildx() { :; }
cleanup_buildx() { :; }
fake_tag=""
registry_manifest() {
  case "$1" in
    "$REGISTRY/exec-php:8.3")
      [ -n "$fake_tag" ] || return 3
      jq -n --arg t "$fake_tag" '{annotations: {"sh.runr.patch.tag": $t, "sh.runr.patch.build": "sha256:other"}}' > "$2"
      echo "sha256:$(printf '%064d' 3)" ;;
    *) return 3 ;;
  esac
}
registry_tags_checked() { echo 8.3; echo "${fake_tag}"; }
publish() { # publish FULL — patch_publish_image of exec-php:8.3 with push; output in $tmp/out
  : > "$log"
  PATCH_RESULTS="$tmp/results" PATCH_PUBLISHED=0 PATCH_UNCHANGED=0 PATCH_HELD=0 PATCH_SUMMARY=()
  patch_publish_image 1 php 8.3 "$1" "$RUNTIMES_DIR/php" --build-arg VERSION=8.3 > "$tmp/out" 2>&1
}
pushes() { grep -c -- 'push=true' "$log" || true; }

# --- the gate --------------------------------------------------------------------------------------
patch_request_reset routine
export LANG_GATE=1
fake_tag="8.3.27-r1"
publish 8.3.28 || fail "held: $(cat "$tmp/out")"
[ "$(pushes)" = 0 ] || fail "an untested upstream version was pushed: $(cat "$log")"
[ "$PATCH_HELD" = 1 ] || fail "not counted as held"
grep -qF 'held: ghcr.io/brf-tech/runr/exec-php:8.3 builds 8.3.28, which the language bot has not tested' "$tmp/out" || fail "the held message: $(cat "$tmp/out")"
grep -qF "8.3.27-r1 stays" "$tmp/out" || fail "the published patch is not named: $(cat "$tmp/out")"
publish 8.3.27 || fail "a base refresh: $(cat "$tmp/out")"
[ "$(pushes)" = 1 ] || fail "a rebuild of the version the tag runs was held: $(cat "$tmp/out")"
echo "8.3 8.3.28" >> "$RUNTIMES_DIR/php/tested-versions"
publish 8.3.28 || fail "tested: $(cat "$tmp/out")"
[ "$(pushes)" = 1 ] || fail "a tested version was held: $(cat "$tmp/out")"
# a new version: no tag yet, held until it is listed
fake_tag=""
publish 8.3.29 || fail "a new version: $(cat "$tmp/out")"
[ "$(pushes)" = 0 ] && grep -qF 'nothing published stays' "$tmp/out" || fail "a new untested version: $(cat "$tmp/out")"
fake_tag="8.3.27-r1"
# a person's patch is never held
PATCH_REQ_LEVEL=zero-day
publish 8.3.29 || fail "zero-day: $(cat "$tmp/out")"
[ "$(pushes)" = 1 ] || fail "a zero-day patch was held"
patch_request_reset routine
# without the gate nothing is held
LANG_GATE=0 publish 8.3.29 || fail "no gate: $(cat "$tmp/out")"
[ "$(pushes)" = 1 ] || fail "held without the gate"
[ "$(patch_tested php 8.3)" = 8.3.28 ] && [ -z "$(patch_tested php 8.2)" ] || fail "patch_tested"
echo "ok - the gate: an untested upstream version held, a base refresh, a tested version and a person's patch published, nothing held without it"

# --- the test build of one version -----------------------------------------------------------------
flow() {
  : > "$tmp/flow"
  (
    discover_language_versions() { declare -gA DISCOVERED=([php]=" 8.2 8.3 8.4"); }
    docker() { return 1; }  # no local image yet
    do_build() { echo "build $1" >> "$tmp/flow"; }
    runtime_smoke() { SMOKE_FULL_VERSION="$3.9"; }
    cmd_build "$@"
  ) > "$tmp/out" 2>&1
}
BUILD_REPORT="$tmp/built" flow php --version=8.3 || fail "--version: $(cat "$tmp/out")"
[ "$(cat "$tmp/flow")" = "build ${REGISTRY}/exec-php:8.3" ] || fail "--version built: $(cat "$tmp/flow")"
[ "$(cat "$tmp/built")" = "php 8.3 8.3.9" ] || fail "BUILD_REPORT: $(cat "$tmp/built")"
flow php --version=8.1 && fail "a version that is not current was built"
grep -qF 'php 8.1 is not a current version' "$tmp/out" || fail "not current: $(cat "$tmp/out")"
flow php python --version=8.3 && fail "--version with two runtimes"
flow php --version=8 && fail "--version=8"
echo "ok - ci.sh build RUNTIME --version=X.Y builds that one version, reports its full version, refuses another"
