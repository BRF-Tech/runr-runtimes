#!/usr/bin/env bash
# Tests the patches of the runtime images (lib/patch.sh) without Docker or a registry: the next
# patch tag, the full version a smoke test reports, the patch request (levels, reasons, CVEs, the
# advisory, deadlines), the versions a request names, and publishing one image as a patch
# (patch_publish_image): docker is a shell function that records every call and writes the build
# digest buildx reports, the registry is a set of shell functions (the floating tag's patch and its
# annotations, the image's tags, the base image). An unchanged build publishes nothing; a changed
# one is pushed once, tagged <major.minor> and <full>-r<n>, with the patch annotations, its reason
# from what changed; a dry run pushes nothing; an existing patch tag is never overwritten.
#
#   bash test/patch_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -f -- "${tmp:?}"/*; rmdir -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "skip: patch_test needs jq"; exit 0; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/build.sh
source "$here/lib/build.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/patch.sh
source "$here/lib/patch.sh"
# shellcheck source=../lib/feed.sh
source "$here/lib/feed.sh"

REGISTRY="ghcr.io/brf-tech/runr"
export PATCH_NOW="2026-10-21T14:30:00Z"

# --- the next patch tag, the full version ----------------------------------------------------------------
[ "$(patch_next_tag 8.3.36)" = "8.3.36-r1" ] || fail "first patch: $(patch_next_tag 8.3.36)"
[ "$(patch_next_tag 8.3.36 8.3 8.3.35-r4 8.3.36-r1 8.3.36-r2)" = "8.3.36-r3" ] || fail "next patch"
[ "$(patch_next_tag 8.3.36 8.3.36-r9 8.3.36-r10 8.3.36-r2)" = "8.3.36-r11" ] || fail "r10 is above r9: $(patch_next_tag 8.3.36 8.3.36-r9 8.3.36-r10)"
[ "$(patch_next_tag 8.3.3 8.3.36-r5 18.3.3-r7 8.3.3-r1-x 8.3.3-r01)" = "8.3.3-r1" ] || fail "tags of other versions counted: $(patch_next_tag 8.3.3 8.3.36-r5 18.3.3-r7 8.3.3-r1-x 8.3.3-r01)"
for ok in "8.3 8.3.36" "22.23 22.23.3" "3.15 3.15.0rc1" "1.26 1.26.2" "3.12 3.12.13"; do
  # shellcheck disable=SC2086 # version and full version
  patch_full_version_valid $ok || fail "a release: ${ok}"
done
for bad in "8.3 8.4.1" "8.3 8.3" "3.14 3.14.0a1+" "8.3 8.3.36-dev" "1.26 v1.26.2" "8.3 18.3.1"; do
  # shellcheck disable=SC2086
  patch_full_version_valid $bad && fail "not a release of the version: ${bad}"
done
echo "ok - patch tags: <full>-r<n>, n one more than the highest of that full version"

# --- the request ----------------------------------------------------------------------------------------------
request() { # request LEVEL EN TR CVES URL HOURS AT — patch_request_check of these; its output in $tmp/req
  PATCH_REQ_LEVEL="$1" PATCH_REQ_REASON_EN="$2" PATCH_REQ_REASON_TR="$3" PATCH_REQ_CVES="$4"
  PATCH_REQ_URL="$5" PATCH_REQ_DEADLINE_HOURS="$6" PATCH_REQ_DEADLINE_AT="$7"
  patch_request_check > "$tmp/req" 2>&1
}
request zero-day "Heap overflow,  exploited
in the wild" "Heap taşması" "cve-2026-109618, CVE-2026-1234 CVE-2026-109618" "https://example.org/a" "" "" \
  || fail "a zero-day request: $(cat "$tmp/req")"
[ "$(patch_request_json)" = '{"level":"zero-day","reason":{"en":"Heap overflow, exploited in the wild","tr":"Heap taşması"},"cves":["CVE-2026-109618","CVE-2026-1234"],"url":"https://example.org/a","deadline_at":"2026-10-24T14:30:00Z"}' ] \
  || fail "zero-day request: $(patch_request_json)"
request critical "x" "y" "" "" "" "" || fail "critical: $(cat "$tmp/req")"
[ "$PATCH_REQ_DEADLINE_AT" = "2026-10-28T14:30:00Z" ] || fail "critical: 168 hours: $PATCH_REQ_DEADLINE_AT"
request zero-day "x" "y" "" "" 24 "" && [ "$PATCH_REQ_DEADLINE_AT" = "2026-10-22T14:30:00Z" ] || fail "deadline hours: $PATCH_REQ_DEADLINE_AT"
request zero-day "x" "y" "" "" 24 "2026-11-01T00:00:00Z" && [ "$PATCH_REQ_DEADLINE_AT" = "2026-11-01T00:00:00Z" ] || fail "deadline_at wins"
request security "x" "y" "" "" "" "" && [ -z "$PATCH_REQ_DEADLINE_AT" ] || fail "security: no default deadline"
request routine "" "" "" "" "" "" || fail "routine without a reason: $(cat "$tmp/req")"
[ "$(patch_request_json)" = '{"level":"routine","reason":null,"cves":[],"url":null,"deadline_at":null}' ] || fail "routine: $(patch_request_json)"
request zero-day "" "" "" "" "" "" && fail "a zero-day request without a reason passed"
request routine "only English" "" "" "" "" "" && fail "a reason without its Turkish one passed"
request urgent "x" "y" "" "" "" "" && fail "an unknown level passed"
request security "x" "y" "CVE-26-1" "" "" "" && fail "a malformed CVE passed"
grep -q "cves: 'CVE-26-1'" "$tmp/req" || fail "the CVE problem: $(cat "$tmp/req")"
request security "x" "y" "GHSA-xxxx-yyyy-zzzz" "" "" "" && fail "a malformed GHSA id passed"
request security "x" "y" "GHSA-2f9x-5v75-3qv4" "" "" "" || fail "a GHSA id: $(cat "$tmp/req")"
request security "x" "y" "" "http://example.org" "" "" && fail "an http advisory passed"
request zero-day "x" "y" "" "" "0" "" && fail "0 deadline hours passed"
request zero-day "x" "y" "" "" "" "tomorrow" && fail "a deadline that is not a time passed"
long="$(printf '%301s' '' | tr ' ' a)"
request security "$long" "y" "" "" "" "" && fail "a reason over 300 characters passed"
echo "ok - the patch request: levels, both reasons, CVE/GHSA ids, https advisories, deadlines (72 h zero-day, 168 h critical)"

# --- versions ---------------------------------------------------------------------------------------------------
patch_versions_check all php python > /dev/null || fail "all"
patch_versions_check "8.2,8.3 8.4" php > /dev/null || fail "versions of one runtime"
patch_versions_check "8.3" php python > "$tmp/out" 2>&1 && fail "plain versions with two runtimes passed"
patch_versions_check "php:8.3,python:3.12" php python > /dev/null || fail "runtime:version"
patch_versions_check "php:8.3" php python > "$tmp/out" 2>&1 && fail "a runtime without a version passed"
grep -q 'no version of python' "$tmp/out" || fail "missing runtime: $(cat "$tmp/out")"
patch_versions_check "go:1.26" php > /dev/null 2>&1 && fail "a version of a runtime not patched passed"
patch_versions_check "8.3.36" php > /dev/null 2>&1 && fail "a full version passed"
[ "$(patch_versions_for php "php:8.3,python:3.12,php:8.4")" = "8.3 8.4" ] || fail "versions for php"
[ "$(patch_versions_for php "8.2,8.3")" = "8.2 8.3" ] || fail "plain versions"
[ "$(patch_versions_for php "")" = "all" ] || fail "no versions: all"
echo "ok - versions: all, a list for one runtime, runtime:version for several"

# ci.sh patch --check: the request as JSON, nothing built
out=$(cmd_patch --check php --versions 8.3,8.4 --level zero-day --reason-en "Heap overflow" --reason-tr "Heap taşması" \
  --cves CVE-2026-109618 --url https://example.org/a 2>/dev/null) || fail "patch --check failed"
[ "$out" = '{"runtimes":["php"],"versions":"8.3,8.4","level":"zero-day","reason":{"en":"Heap overflow","tr":"Heap taşması"},"cves":["CVE-2026-109618"],"url":"https://example.org/a","deadline_at":"2026-10-24T14:30:00Z","promote_unchanged":false}' ] \
  || fail "patch --check: $out"
out=$(PATCH_RUNTIMES=all PATCH_LEVEL=critical PATCH_REASON_EN=a PATCH_REASON_TR=b PATCH_DEADLINE_HOURS=12 PATCH_PROMOTE_UNCHANGED=true \
  cmd_patch --check 2>/dev/null) || fail "patch --check from the environment"
[ "$(jq -c '[.runtimes, .versions, .deadline_at, .promote_unchanged]' <<< "$out")" = '[["python","nodejs","go","php"],"all","2026-10-22T02:30:00Z",true]' ] \
  || fail "patch --check env: $out"
[ "$(cmd_patch --check php --level security --reason-en a --reason-tr b --promote-unchanged 2>/dev/null | jq -c .promote_unchanged)" = true ] \
  || fail "--promote-unchanged"
cmd_patch --check ruby --level routine > /dev/null 2>&1 && fail "an unknown runtime passed"
cmd_patch --check php python --versions 8.3 --level routine > /dev/null 2>&1 && fail "plain versions for two runtimes passed"
cmd_patch --check --only go php python --versions php:8.3,python:3.12 --level routine > /dev/null 2>&1 && fail "--only a runtime outside the request passed"
cmd_patch --check --only python php python --versions php:8.3,python:3.12 --level routine > /dev/null 2>&1 || fail "--only a runtime of the request"
echo "ok - ci.sh patch --check: the request as JSON, from flags or the environment"

# ci.sh patch: the versions named built and smoke-tested (never skipped), then published and the
# feed updated; --only one runtime of the request (a job of the patch workflow)
flow() { # flow ARG... — cmd_patch with Docker Hub, the builds, the publish and the feed recorded in $tmp/flow
  : > "$tmp/flow"
  (
    discover_language_versions() { declare -gA DISCOVERED=([php]=" 8.2 8.3 8.4" [python]=" 3.12 3.13"); }
    do_build() { echo "build $1" >> "$tmp/flow"; }
    runtime_smoke() { echo "smoke $1" >> "$tmp/flow"; SMOKE_FULL_VERSION="$3.9"; }
    patch_push_images() { echo "publish $*" >> "$tmp/flow"; }
    feed_tools() { :; }
    feed_update() { echo "feed $*" >> "$tmp/flow"; }
    cmd_patch "$@"
  ) > "$tmp/out" 2>&1
}
flow --only php php python --versions php:8.3,python:3.12 --level zero-day --reason-en a --reason-tr b --push --no-feed \
  || fail "patch --only php: $(cat "$tmp/out")"
[ "$(grep -c '^build ' "$tmp/flow")" = 1 ] && grep -qxF "build ${REGISTRY}/exec-php:8.3" "$tmp/flow" || fail "--only php: built $(cat "$tmp/flow")"
grep -qxF "smoke ${REGISTRY}/exec-php:8.3" "$tmp/flow" || fail "--only php: not smoke-tested"
grep -qxF "publish 1 php|8.3|8.3.9|${here}/runtimes/php|--build-arg|VERSION=8.3" "$tmp/flow" || fail "--only php: publish $(grep '^publish' "$tmp/flow")"
grep -q '^feed' "$tmp/flow" && fail "--no-feed updated the feed"
flow php --versions all --level routine || fail "patch php (dry run): $(cat "$tmp/out")"
[ "$(grep -c '^build ' "$tmp/flow")" = 3 ] || fail "all versions: $(cat "$tmp/flow")"
grep -q '^publish 0 ' "$tmp/flow" || fail "a dry run published with push"
grep -q '^feed 0  .* --results ' "$tmp/flow" || fail "the dry run's feed update: $(grep '^feed' "$tmp/flow")"
flow php --versions 8.1 --level routine && fail "a version that is not current passed"
grep -q 'php 8.1 is not a current version' "$tmp/out" || fail "not current: $(cat "$tmp/out")"
echo "ok - ci.sh patch: the versions named built, smoke-tested and published, --only one runtime, the feed after"

# --- publishing an image as a patch ---------------------------------------------------------------------------
log="$tmp/calls"
fake_build="sha256:$(printf '%064d' 1)"
fake_push="sha256:$(printf '%064d' 2)"
# docker: records the call; buildx writes the digest of the build (push=false) or of the push
docker() {
  echo "docker $*" >> "$log"
  local arg prev="" digest="$fake_build"
  [[ "$*" == *"push=true"* ]] && digest="$fake_push"
  for arg in "$@"; do
    if [ "$prev" = --metadata-file ]; then printf '{"containerimage.digest": "%s"}' "$digest" > "$arg"; fi
    prev="$arg"
  done
  return 0
}
ensure_buildx() { :; }
cleanup_buildx() { :; }
# the registry: the floating tag's index ($tmp/current, none when missing), the tags, the base
fake_current="sha256:$(printf '%064d' 3)"
fake_tags="8.3"
existing=""
registry_manifest() {
  echo "manifest $1" >> "$log"
  case "$1" in
    "$REGISTRY/exec-php:8.3")
      [ -f "$tmp/current" ] || return 3
      cp "$tmp/current" "$2"
      echo "$fake_current" ;;
    "$REGISTRY/reqs/php:8.3-cli-alpine") echo '{}' > "$2"; echo "sha256:$(printf '%064d' 8)" ;;
    "$REGISTRY/exec-php:${existing:-none}") echo '{}' > "$2"; echo "sha256:$(printf '%064d' 9)" ;;
    *) return 3 ;;
  esac
}
# shellcheck disable=SC2086 # the tags, one per word
registry_tags_checked() { printf '%s\n' $fake_tags; }
# current INDEX-ANNOTATIONS-JSON — the floating tag's patch
current() { jq -n --argjson a "$1" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [], annotations: $a}' > "$tmp/current"; }
base_now="ghcr.io/brf-tech/runr/reqs/php:8.3-cli-alpine@sha256:$(printf '%064d' 8)"
published() { # published TAG BUILD BASE — the annotations of a published routine patch
  jq -cn --arg tag "$1" --arg build "$2" --arg base "$3" '{
    "sh.runr.patch.id": "php-8.3-\($tag)", "sh.runr.patch.runtime": "php", "sh.runr.patch.version": "8.3",
    "sh.runr.patch.tag": $tag, "sh.runr.patch.level": "routine", "sh.runr.patch.reason.en": "Upstream PHP",
    "sh.runr.patch.reason.tr": "PHP", "sh.runr.patch.upstream": "PHP \($tag | sub("-r[0-9]+$"; ""))",
    "sh.runr.patch.published_at": "2026-10-19T03:35:21Z", "sh.runr.patch.build": $build, "sh.runr.patch.base": $base}'
}
publish() { # publish PUSH FULL — patch_publish_image of exec-php:8.3; its output in $tmp/out, results in $tmp/results
  : > "$log"
  : > "$tmp/results"
  PATCH_RESULTS="$tmp/results" PATCH_PUBLISHED=0 PATCH_UNCHANGED=0
  patch_publish_image "$1" php 8.3 "$2" "$here/runtimes/php" --build-arg VERSION=8.3 > "$tmp/out" 2>&1
}
pushes() { grep -c -- 'push=true' "$log" || true; }

# unchanged: the floating tag's patch has the build digest
patch_request_reset routine
current "$(published 8.3.36-r1 "$fake_build" "$base_now")"
fake_tags="8.3 8.3.36-r1"
publish 1 8.3.36 || fail "unchanged: $(cat "$tmp/out")"
[ "$(pushes)" = 0 ] || fail "unchanged: pushed $(grep push=true "$log")"
grep -q '^docker buildx build .*--output type=image,push=false,oci-mediatypes=true,rewrite-timestamp=true ' "$log" || fail "no reproducible build: $(cat "$log")"
grep -q -- '--build-arg SOURCE_DATE_EPOCH=[0-9]' "$log" || fail "no SOURCE_DATE_EPOCH: $(cat "$log")"
grep -q -- '--provenance=false --sbom=false' "$log" || fail "a build with provenance or SBOM (they carry build times)"
[ "$(jq -r '[.result, .entry.id, .entry.digest] | join(" ")' "$tmp/results")" = "unchanged php-8.3-8.3.36-r1 ${fake_current}" ] \
  || fail "unchanged result: $(cat "$tmp/results")"
[ "$PATCH_UNCHANGED" = 1 ] && [ "$PATCH_PUBLISHED" = 0 ] || fail "unchanged: counts"
echo "ok - a build that is the published image publishes nothing (its build digest)"

# a new upstream version: <full>-r1, "Upstream PHP 8.3.37", pushed once with both tags and the annotations
current "$(published 8.3.36-r1 "sha256:$(printf '%064d' 4)" "$base_now")"
publish 1 8.3.37 || fail "upstream: $(cat "$tmp/out")"
[ "$(pushes)" = 1 ] || fail "upstream: not one push: $(cat "$log")"
push_call=$(grep -- 'push=true' "$log")
[[ "$push_call" == *" -t ${REGISTRY}/exec-php:8.3 -t ${REGISTRY}/exec-php:8.3.37-r1 "* ]] || fail "upstream: tags: $push_call"
for annotation in "index:sh.runr.patch.tag=8.3.37-r1" "index:sh.runr.patch.level=routine" \
  "index:sh.runr.patch.reason.en=Upstream PHP 8.3.37" "index:sh.runr.patch.reason.tr=PHP 8.3.37 sürümüne güncellendi" \
  "index:sh.runr.patch.upstream=PHP 8.3.37" "index:sh.runr.patch.build=${fake_build}" "index:sh.runr.patch.base=${base_now}" \
  "index:sh.runr.patch.published_at=2026-10-21T14:30:00Z" "index:sh.runr.patch.id=php-8.3-8.3.37-r1"; do
  [[ "$push_call" == *" --annotation ${annotation} "* ]] || fail "upstream: annotation ${annotation}: $push_call"
done
[[ "$push_call" == *"deadline_at"* ]] && fail "a routine patch got a deadline"
[[ "$push_call" == *" --build-arg VERSION=8.3 --output type=image,push=true,oci-mediatypes=true,rewrite-timestamp=true ${here}/runtimes/php" ]] \
  || fail "upstream: the push build: $push_call"
grep -q "^manifest ${REGISTRY}/exec-php:8.3.37-r1$" "$log" || fail "the patch tag was not checked before the push"
[ "$(jq -c '[.result, .entry.tag, .entry.digest, .entry.level]' "$tmp/results")" = "[\"new\",\"8.3.37-r1\",\"${fake_push}\",\"routine\"]" ] \
  || fail "upstream result: $(cat "$tmp/results")"
feed_validate_entry() { jq -c --slurpfile r "$tmp/results" '.patches = [$r[0].entry]' "$here/schema/patch-feed.example.json" > "$tmp/feed.json"; feed_validate "$tmp/feed.json" > "$tmp/valid" 2>&1; }
rc=0; feed_validate_entry || rc=$?
[ "$rc" != 1 ] || fail "the new patch's feed entry is not valid: $(cat "$tmp/valid")"
echo "ok - a new upstream version: <full>-r1 pushed once, tagged <major.minor> and the patch tag, annotated"

# the same version on a new base: r2, "Base image refresh"
current "$(published 8.3.37-r1 "sha256:$(printf '%064d' 4)" "ghcr.io/brf-tech/runr/reqs/php:8.3-cli-alpine@sha256:$(printf '%064d' 7)")"
fake_tags="8.3 8.3.36-r1 8.3.37-r1"
publish 1 8.3.37 || fail "base: $(cat "$tmp/out")"
grep -q -- "-t ${REGISTRY}/exec-php:8.3.37-r2 " "$log" || fail "base: not r2: $(grep push=true "$log")"
grep -q -- '--annotation index:sh.runr.patch.reason.en=Base image refresh ' "$log" || fail "base: reason"
# the same version and base: "Runtime update"
current "$(published 8.3.37-r2 "sha256:$(printf '%064d' 4)" "$base_now")"
fake_tags="8.3 8.3.37-r1 8.3.37-r2"
publish 1 8.3.37 || fail "runtime: $(cat "$tmp/out")"
grep -q -- "-t ${REGISTRY}/exec-php:8.3.37-r3 " "$log" || fail "runtime: not r3"
grep -q -- '--annotation index:sh.runr.patch.reason.en=Runtime update ' "$log" || fail "runtime: reason"
echo "ok - the reason of a routine patch: upstream, base image refresh, runtime update; r<n> counts up"

# a zero-day request: its reason, CVEs, advisory and deadline
request zero-day "Heap overflow" "Heap taşması" "CVE-2026-109618" "https://example.org/a" "" "" || fail "request"
publish 1 8.3.37 || fail "zero-day: $(cat "$tmp/out")"
push_call=$(grep -- 'push=true' "$log")
for annotation in "index:sh.runr.patch.level=zero-day" "index:sh.runr.patch.reason.en=Heap overflow" \
  "index:sh.runr.patch.cves=CVE-2026-109618" "index:sh.runr.patch.url=https://example.org/a" \
  "index:sh.runr.patch.deadline_at=2026-10-24T14:30:00Z"; do
  [[ "$push_call" == *" --annotation ${annotation} "* ]] || fail "zero-day: annotation ${annotation}: $push_call"
done
[ "$(jq -c '.request.level, .entry.deadline_at' "$tmp/results" | paste -sd' ' -)" = '"zero-day" "2026-10-24T14:30:00Z"' ] || fail "zero-day result: $(cat "$tmp/results")"
rc=0; feed_validate_entry || rc=$?
[ "$rc" != 1 ] || fail "the zero-day patch's feed entry is not valid: $(cat "$tmp/valid")"
# the same request on an unchanged image: nothing pushed, a warning (upstream may not have the fix
# yet); the result carries the request, promote only on the operator's word (--promote-unchanged)
current "$(published 8.3.37-r3 "$fake_build" "$base_now")"
publish 1 8.3.37 || fail "zero-day unchanged: $(cat "$tmp/out")"
[ "$(pushes)" = 0 ] || fail "zero-day unchanged: pushed"
[ "$(jq -c '[.result, .entry.tag, .request.level, .promote]' "$tmp/results")" = '["unchanged","8.3.37-r3","zero-day",false]' ] || fail "zero-day unchanged: $(cat "$tmp/results")"
grep -q 'warning: .*the build is unchanged, so no zero-day patch was published and 8.3.37-r3 keeps its level' "$tmp/out" || fail "zero-day unchanged: no warning: $(cat "$tmp/out")"
GITHUB_ACTIONS=true publish 1 8.3.37 || fail "zero-day unchanged in a workflow"
grep -q '^::warning::' "$tmp/out" || fail "zero-day unchanged: no workflow warning: $(cat "$tmp/out")"
PATCH_REQ_PROMOTE=1
publish 1 8.3.37 || fail "zero-day unchanged, promoted: $(cat "$tmp/out")"
[ "$(jq -c '.promote' "$tmp/results")" = true ] || fail "--promote-unchanged: $(cat "$tmp/results")"
grep -q 'warning' "$tmp/out" && fail "--promote-unchanged warned: $(cat "$tmp/out")"
PATCH_REQ_PROMOTE=0
echo "ok - a zero-day patch carries its reason, CVEs, advisory and deadline; an unchanged image is promoted only on request"

# a dry run pushes nothing; an existing patch tag is never overwritten; a version that is not a release
patch_request_reset routine
current "$(published 8.3.37-r3 "sha256:$(printf '%064d' 4)" "$base_now")"
fake_tags="8.3 8.3.37-r3"
publish 0 8.3.37 || fail "dry run: $(cat "$tmp/out")"
[ "$(pushes)" = 0 ] || fail "a dry run pushed"
grep -q 'dry run: would push ghcr.io/brf-tech/runr/exec-php:8.3 and ghcr.io/brf-tech/runr/exec-php:8.3.37-r4' "$tmp/out" || fail "dry run: $(cat "$tmp/out")"
[ "$(jq -r '.result' "$tmp/results")" = planned ] || fail "dry run result"
existing="8.3.37-r4"
publish 1 8.3.37 && fail "an existing patch tag was overwritten"
[ "$(pushes)" = 0 ] || fail "pushed over an existing patch tag"
existing=""
publish 1 8.4.1 && fail "a full version of another minor passed"
grep -q "'8.4.1' is not a release of 8.3" "$tmp/out" || fail "wrong full version: $(cat "$tmp/out")"
rm -f -- "$tmp/current"
fake_tags=""
publish 1 8.3.37 || fail "a new version: $(cat "$tmp/out")"
grep -q -- "-t ${REGISTRY}/exec-php:8.3.37-r1 " "$log" || fail "a version without an image: not r1"
echo "ok - dry runs push nothing, a patch tag is never overwritten, the first patch of a version is r1"

# the buildx builder: ci.sh's own (BUILDER_NAME), never the host's current one
if grep -E '^docker buildx build ' "$log" | grep -vq -- '--builder runr-multiarch '; then
  fail "a patch build outside ci.sh's builder: $(grep '^docker buildx build' "$log")"
fi
echo "ok - patch builds run in ci.sh's own builder"
