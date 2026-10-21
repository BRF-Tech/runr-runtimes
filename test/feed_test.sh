#!/usr/bin/env bash
# Tests the patch feed (lib/feed.jq, lib/feed.sh) without a registry: the patch tag order and the
# floating tag of a patch tag, retention (the newest 5 per floating tag, never a tag the feed
# lists or a floating tag), merging a feed (new patches, the registry's patches the feed lacks,
# promotions of unchanged images, platform releases, the newest 5 / 10), the feed against
# schema/patch-feed.v1.json and its rules, pulling the feed (registry API answers of curl),
# publishing it (oras and cosign are shell functions that record their calls: candidate, signed by
# digest, verified, then tagged), a whole update with retention through the GitHub Packages API,
# and ci.sh feed platform. Needs jq; the schema checks need check-jsonschema or python3 with
# jsonschema (skipped without one).
#
#   bash test/feed_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -f -- "${tmp:?}"/*; rmdir -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "skip: feed_test needs jq"; exit 0; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/patch.sh
source "$here/lib/patch.sh"
# shellcheck source=../lib/feed.sh
source "$here/lib/feed.sh"

REGISTRY="ghcr.io/brf-tech/runr"
export PATCH_NOW="2026-10-21T14:30:00Z"
validator="$(feed_schema_validator)"

# fjq FILTER [ARG...] — jq -n with lib/feed.jq included
fjq() {
  local filter="$1"
  shift
  jq -L "$here/lib" -nc "$@" "include \"feed\"; ${filter}"
}

# entry RUNTIME VERSION TAG PUBLISHED [LEVEL] — a feed entry
entry() {
  local level="${5:-routine}" deadline=""
  case "$level" in critical|zero-day) deadline="2026-10-30T00:00:00Z" ;; esac
  jq -cn --arg runtime "$1" --arg version "$2" --arg tag "$3" --arg published "$4" --arg level "$level" \
    --arg deadline "$deadline" --arg digest "sha256:$(printf '%s' "$1$3" | sha256sum | cut -d' ' -f1)" \
    '{id: "\($runtime)-\($version)-\($tag)", runtime: $runtime, version: $version, tag: $tag,
      image: "ghcr.io/brf-tech/runr/exec-\($runtime)", digest: $digest, level: $level,
      reason: {en: "Upstream \($tag)", tr: "\($tag) sürümüne güncellendi"}, cves: [],
      upstream: "\($runtime) \($tag | sub("-r[0-9]+$"; ""))", published_at: $published}
     + (if $deadline != "" then {deadline_at: $deadline} else {} end)'
}

# --- patch tags -------------------------------------------------------------------------------------
order=$(fjq '["8.3.36-r10", "8.3.4-r1", "8.3.36-r9", "8.3.36-r1", "3.15.0rc1-r1", "3.15.0-r1", "3.15.0b4-r2", "8.3.36-r2"]
  | sort_by(tag_key) | join(" ")' -r)
[ "$order" = "3.15.0b4-r2 3.15.0rc1-r1 3.15.0-r1 8.3.4-r1 8.3.36-r1 8.3.36-r2 8.3.36-r9 8.3.36-r10" ] || fail "tag order: $order"
versions=$(fjq '["8.3.36-r2", "22.11.0-r1", "3.15.0rc1-r1", "2.14.1-gpu-r1", "4.1-r3"] | map(tag_version) | join(" ")' -r)
[ "$versions" = "8.3 22.11 3.15 2.14-gpu 4.1" ] || fail "floating tags of patch tags: $versions"
patch_tags=$(fjq '["8.3", "8.3.36-r1", "latest", "8.3.36", "sha256-abc.sig", "8.3.36-r0", "22.11.0-r12"] | map(select(is_patch_tag)) | join(" ")' -r)
[ "$patch_tags" = "8.3.36-r1 22.11.0-r12" ] || fail "patch tags: $patch_tags"
echo "ok - patch tags: release order with pre-releases and r10 after r9, the floating tag of each"

# --- retention -----------------------------------------------------------------------------------------
tags='["8.3", "8.4", "8.3.30-r1", "8.3.31-r1", "8.3.31-r2", "8.3.32-r1", "8.3.33-r1", "8.3.34-r1", "8.3.34-r2", "8.4.1-r1", "latest"]'
feed=$(jq -cn --argjson a "$(entry php 8.3 8.3.30-r1 2026-01-01T00:00:00Z)" '{patches: [$a]}')
doomed=$(fjq '$feed | retention($tags; "php"; 5) | join(" ")' -r --argjson tags "$tags" --argjson feed "$feed")
[ "$doomed" = "8.3.31-r1" ] || fail "retention: '$doomed' (8.3.30-r1 is in the feed, the newest five stay)"
doomed=$(fjq '{patches: []} | retention($tags; "php"; 5) | join(" ")' -r --argjson tags "$tags")
[ "$doomed" = "8.3.30-r1 8.3.31-r1" ] || fail "retention without a feed: '$doomed'"
doomed=$(fjq '$feed | retention($tags; "nodejs"; 5) | join(" ")' -r --argjson tags "$tags" --argjson feed "$feed")
[ "$doomed" = "8.3.30-r1 8.3.31-r1" ] || fail "retention: another runtime's feed entries protected a tag: '$doomed'"
doomed=$(fjq '{} | retention(["8.3", "8.3.1-r1", "8.3.1-r2"]; "php"; 1) | join(" ")' -r)
[ "$doomed" = "8.3.1-r1" ] || fail "retention keeps the newest and never the floating tag: '$doomed'"
unlisted=$(fjq '$feed | unlisted_patch_tags($tags; "php"; 5) | join(" ")' -r --argjson tags "$tags" --argjson feed "$feed")
[ "$unlisted" = "8.3.34-r2 8.3.34-r1 8.3.33-r1 8.3.32-r1 8.3.31-r2 8.4.1-r1" ] || fail "unlisted patch tags: '$unlisted'"
echo "ok - retention: the newest 5 of each floating tag and the feed's patches stay, floating tags never go"

# --- annotations ↔ feed entry -------------------------------------------------------------------------
zd=$(jq -c '.cves = ["CVE-2026-109618", "CVE-2026-1001"] | .url = "https://example.org/advisory" | .reason = {en: "Heap overflow, exploited", tr: "Heap taşması, istismar ediliyor"}' \
  <<< "$(entry php 8.3 8.3.36-r2 2026-10-21T14:29:12Z zero-day)")
mapfile -t annotations < <(fjq '$e | patch_annotations("sha256:build"; "ghcr.io/brf-tech/runr/reqs/php:8.3-cli-alpine@sha256:base")' -r --argjson e "$zd")
printf '%s\n' "${annotations[@]}" | grep -qxF 'index:sh.runr.patch.cves=CVE-2026-109618,CVE-2026-1001' || fail "annotations: cves $(printf '%s\n' "${annotations[@]}")"
printf '%s\n' "${annotations[@]}" | grep -qxF 'index:sh.runr.patch.reason.tr=Heap taşması, istismar ediliyor' || fail "annotations: reason.tr"
printf '%s\n' "${annotations[@]}" | grep -qxF 'index:sh.runr.patch.build=sha256:build' || fail "annotations: build"
printf '%s\n' "${annotations[@]}" | grep -q '^index:sh.runr.patch.digest' && fail "annotations: the index carries its own digest"
index=$(printf '%s\n' "${annotations[@]}" | jq -Rn '{annotations: ([inputs | sub("^index:"; "") | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries)}')
back=$(jq -L "$here/lib" -c --arg digest "$(jq -r .digest <<< "$zd")" 'include "feed"; entry_from_annotations("ghcr.io/brf-tech/runr/exec-php"; $digest)' <<< "$index")
[ "$(jq -cS . <<< "$back")" = "$(jq -cS . <<< "$zd")" ] || fail "an entry read from its annotations differs: $back"
[ -z "$(jq -L "$here/lib" -c 'include "feed"; entry_from_annotations("x"; "y")' <<< '{"annotations": {"org.opencontainers.image.source": "x"}}')" ] \
  || fail "an index without patch annotations gave an entry"
echo "ok - the patch annotations carry the whole entry but its digest, and give it back"

# --- merging -----------------------------------------------------------------------------------------------
merge() { # merge FEED RESULTS FOUND PLATFORM → the next feed
  fjq '$feed | feed_merge($results; $found; $platform; "2026-10-21T14:30:00Z"; 5; 10)' \
    --argjson feed "$1" --argjson results "$2" --argjson found "$3" --argjson platform "$4"
}
old='{"schema": 1, "generated_at": "2026-10-20T00:00:00Z", "patches": [], "platform": []}'
for i in 1 2 3 4 5; do
  old=$(jq -c --argjson e "$(entry php 8.3 "8.3.3${i}-r1" "2026-10-0${i}T00:00:00Z")" '.patches = [$e] + .patches' <<< "$old")
done
new=$(entry php 8.3 8.3.36-r1 2026-10-21T14:00:00Z)
next=$(merge "$old" "[{\"result\": \"new\", \"entry\": ${new}}]" '[]' '[]')
[ "$(jq -r '.patches | map(.tag) | join(" ")' <<< "$next")" = "8.3.36-r1 8.3.35-r1 8.3.34-r1 8.3.33-r1 8.3.32-r1" ] \
  || fail "merge: not the newest five, newest first: $(jq -c '.patches | map(.tag)' <<< "$next")"
[ "$(jq -r '.generated_at, .schema' <<< "$next" | paste -sd' ' -)" = "2026-10-21T14:30:00Z 1" ] || fail "merge: generated_at/schema"
# the registry's entry of an id the feed has does not replace it; one it lacks is added
found=$(jq -c '.level = "zero-day" | .deadline_at = "2026-10-30T00:00:00Z"' <<< "$(entry php 8.3 8.3.35-r1 2026-10-05T00:00:00Z)")
next=$(merge "$old" '[]' "[${found}, $(entry nodejs 22.23 22.23.3-r1 2026-10-19T03:41:07Z)]" '[]')
[ "$(jq -r '.patches[] | select(.id == "php-8.3-8.3.35-r1") | .level' <<< "$next")" = routine ] || fail "merge: the registry replaced a feed entry"
jq -e '.patches[] | select(.id == "nodejs-22.23-22.23.3-r1")' <<< "$next" >/dev/null || fail "merge: a registry patch the feed lacks was not added"
# an unchanged image under a zero-day request: its patch becomes the zero-day patch
request='{"level": "zero-day", "reason": {"en": "Heap overflow", "tr": "Heap taşması"}, "cves": ["CVE-2026-1002"], "url": "https://example.org/a", "deadline_at": "2026-10-24T14:30:00Z"}'
unchanged=$(jq -c '.cves = ["CVE-2026-1001"]' <<< "$(entry php 8.3 8.3.35-r1 2026-10-05T00:00:00Z)")
next=$(merge "$(jq -c --argjson u "$unchanged" '.patches |= map(if .id == $u.id then $u else . end)' <<< "$old")" \
  "[{\"result\": \"unchanged\", \"entry\": $(entry php 8.3 8.3.35-r1 2026-10-05T00:00:00Z), \"request\": ${request}, \"promote\": true}]" '[]' '[]')
promoted=$(jq -c '.patches[] | select(.id == "php-8.3-8.3.35-r1")' <<< "$next")
[ "$(jq -r '[.level, .reason.en, (.cves | join(",")), .url, .deadline_at, .published_at] | join("|")' <<< "$promoted")" \
  = "zero-day|Heap overflow|CVE-2026-1001,CVE-2026-1002|https://example.org/a|2026-10-24T14:30:00Z|2026-10-05T00:00:00Z" ] \
  || fail "promotion: $promoted"
# a lower request keeps the level, reason and earlier deadline, and adds its CVEs
lower='{"level": "security", "reason": {"en": "Another", "tr": "Başka"}, "cves": ["CVE-2026-1003"], "url": null, "deadline_at": "2026-10-28T00:00:00Z"}'
again=$(merge "$next" "[{\"result\": \"unchanged\", \"entry\": ${promoted}, \"request\": ${lower}, \"promote\": true}]" '[]' '[]')
[ "$(jq -r '.patches[] | select(.id == "php-8.3-8.3.35-r1") | [.level, .reason.en, (.cves | join(",")), .deadline_at] | join("|")' <<< "$again")" \
  = "zero-day|Heap overflow|CVE-2026-1001,CVE-2026-1002,CVE-2026-1003|2026-10-24T14:30:00Z" ] || fail "a lower request: $(jq -c '.patches[0]' <<< "$again")"
# a routine build of an unchanged image changes nothing
same=$(merge "$old" "[{\"result\": \"unchanged\", \"entry\": $(entry php 8.3 8.3.35-r1 2026-10-05T00:00:00Z), \"request\": {\"level\": \"routine\"}}]" '[]' '[]')
[ "$(jq -c 'del(.generated_at)' <<< "$same")" = "$(merge "$old" '[]' '[]' '[]' | jq -c 'del(.generated_at)')" ] || fail "a routine unchanged result changed the feed"
# an unchanged image whose patch the feed lacks is added (and promoted)
added=$(merge "$old" "[{\"result\": \"unchanged\", \"entry\": $(entry go 1.26 1.26.2-r1 2026-10-10T00:00:00Z), \"request\": ${request}, \"promote\": true}]" '[]' '[]')
[ "$(jq -r '.patches[] | select(.id == "go-1.26-1.26.2-r1") | .level' <<< "$added")" = zero-day ] || fail "an unchanged patch the feed lacked"
# without the operator's word (promote) an unchanged image keeps its level: upstream may not have
# the fix yet
kept=$(merge "$old" "[{\"result\": \"unchanged\", \"entry\": $(entry php 8.3 8.3.35-r1 2026-10-05T00:00:00Z), \"request\": ${request}, \"promote\": false}]" '[]' '[]')
[ "$(jq -r '.patches[] | select(.id == "php-8.3-8.3.35-r1") | .level' <<< "$kept")" = routine ] || fail "an unchanged image was promoted without promote"
echo "ok - merge: new and registry patches, the feed's entries win, promotions of unchanged images, newest five"

# platform releases: added, replaced by version, the newest ten, newest first
plat='{"version": "0.5.11", "level": "zero-day", "reason": {"en": "Fix", "tr": "Düzeltme"}, "url": "https://example.org/r", "published_at": "2026-10-21T14:00:00Z"}'
next=$(merge "$old" '[]' '[]' "[${plat}]")
jq -e '.platform | length == 1 and .[0].version == "0.5.11" and (.[0] | keys_unsorted) == ["version", "level", "reason", "url", "published_at"]' <<< "$next" >/dev/null || fail "platform: $(jq -c .platform <<< "$next")"
replaced=$(merge "$next" '[]' '[]' "[$(jq -c '.level = "critical"' <<< "$plat")]")
[ "$(jq -r '.platform | map(.version + " " + .level) | join(",")' <<< "$replaced")" = "0.5.11 critical" ] || fail "platform: the same version not replaced"
many="$old"
for i in $(seq 1 12); do
  many=$(merge "$many" '[]' '[]' "[$(jq -c --arg v "0.5.$i" --arg t "$(printf '2026-10-%02dT00:00:00Z' "$i")" '.version = $v | .published_at = $t' <<< "$plat")]")
done
[ "$(jq -r '.platform | map(.version) | join(" ")' <<< "$many")" = "0.5.12 0.5.11 0.5.10 0.5.9 0.5.8 0.5.7 0.5.6 0.5.5 0.5.4 0.5.3" ] \
  || fail "platform: not the newest ten: $(jq -c '.platform | map(.version)' <<< "$many")"
echo "ok - platform releases: added, replaced by version, the newest ten"

# --- the schema and the rules ------------------------------------------------------------------------------
example="$here/schema/patch-feed.example.json"
check() { # check JSON — feed_validate of the document; its exit status
  printf '%s\n' "$1" > "$tmp/check.json"
  feed_validate "$tmp/check.json" > "$tmp/check.out" 2>&1
}
check "$(cat "$example")" || fail "the example feed: $(cat "$tmp/check.out")"
check "$next" || fail "a merged feed: $(cat "$tmp/check.out")"
check "$many" || fail "a merged feed with platform releases: $(cat "$tmp/check.out")"
check "$(jq '.patches[0].id = "php-8.3-8.3.35-r2"' "$example")" && fail "an id that is not runtime-version-tag passed"
check "$(jq '.patches += [.patches[0]]' "$example")" && fail "a duplicate id passed"
check "$(jq '.patches[0].tag = "8.4.1-r1" | .patches[0].id = "php-8.3-8.4.1-r1"' "$example")" && fail "a tag of another version passed"
six=$(jq -c '.' "$example")
for i in 1 2 3 4 5; do six=$(jq -c --argjson e "$(entry php 8.3 "8.3.2${i}-r1" "2026-09-0${i}T00:00:00Z")" '.patches += [$e]' <<< "$six"); done
check "$six" && fail "six patches of one version passed"
grep -q 'php 8.3: 7 patches (at most 5)' "$tmp/check.out" || fail "six patches: $(cat "$tmp/check.out")"
if [ -n "$validator" ]; then
  check "$(jq 'del(.patches[0].deadline_at)' "$example")" && fail "a zero-day patch without a deadline passed"
  check "$(jq '.patches[0].level = "urgent"' "$example")" && fail "an unknown level passed"
  check "$(jq '.patches[0].digest = "sha256:abc"' "$example")" && fail "a short digest passed"
  check "$(jq '.patches[0].cves = ["CVE-26-1"]' "$example")" && fail "a malformed CVE passed"
  check "$(jq '.patches[0].extra = 1' "$example")" && fail "an unknown field passed"
  check "$(jq '.patches[1].url = "http://example.org"' "$example")" && fail "an http URL passed"
  check "$(jq '.patches[0].reason.tr = "two\nlines"' "$example")" && fail "a reason on two lines passed"
  check "$(jq '.schema = 2' "$example")" && fail "schema 2 passed"
  check "$(jq '.generated_at = "2026-10-21 14:30"' "$example")" && fail "a time without T and Z passed"
  check "$(jq --argjson p "$(jq -c '.platform[0]' "$example")" '.platform = [range(11) as $i | $p | .version = "0.5.\($i)"]' "$example")" \
    && fail "eleven platform releases passed"
  echo "ok - the feed against schema/patch-feed.v1.json (${validator}) and its rules"
else
  echo "skip - schema checks (no check-jsonschema, no python3 jsonschema); the rules were checked"
fi

# --- pulling the feed ---------------------------------------------------------------------------------
feed_body="$(jq -c . "$example")"
printf '%s' "$feed_body" > "$tmp/blob"
blob_digest="sha256:$(sha256_of "$tmp/blob")"
manifest_status=200
curl_calls="$tmp/curl.calls"
: > "$curl_calls"
# curl: the registry's answers (token service, the feed's manifest and blob) and the GitHub
# Packages API; records method and URL
curl() {
  local url="" out="" headers="" method=GET write=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift ;;
      -D) headers="$2"; shift ;;
      -w) write="$2"; shift ;;
      -X) method="$2"; shift ;;
      -H|-u) shift ;;
      http*) url="$1" ;;
    esac
    shift
  done
  echo "${method} ${url}" >> "$curl_calls"
  local status=200 body=""
  case "${method} ${url}" in
    "GET https://ghcr.io/v2/")
      [ "$headers" = "-" ] && printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io"\r\n\r\n'
      return 0 ;;
    "GET https://ghcr.io/token?"*) echo '{"token":"t"}'; return 0 ;;
    "GET https://ghcr.io/v2/brf-tech/runr/runtime-patches/manifests/feed")
      status="$manifest_status"
      body=$(jq -cn --arg d "$blob_digest" --arg mt "$PATCH_FEED_MEDIA_TYPE" \
        '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $mt,
          config: {mediaType: "application/vnd.oci.empty.v1+json", digest: "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", size: 2},
          layers: [{mediaType: $mt, digest: $d, size: 1}]}')
      [ -n "$headers" ] && printf 'HTTP/2 %s\r\ndocker-content-digest: sha256:%064d\r\n\r\n' "$status" 7 > "$headers" ;;
    "GET https://ghcr.io/v2/brf-tech/runr/runtime-patches/blobs/${blob_digest}")
      body="$(cat "$tmp/blob")" ;;
    "GET https://ghcr.io/v2/brf-tech/runr/exec-"*"/tags/list?n=1000")
      local repo="${url#https://ghcr.io/v2/brf-tech/runr/}"
      repo="${repo%%/*}"
      body=$(jq -cn --arg name "brf-tech/runr/${repo}" --argjson tags "$(cat "$tmp/tags-${repo}" 2>/dev/null || echo '[]')" '{name: $name, tags: $tags}') ;;
    "GET https://ghcr.io/v2/brf-tech/runr/exec-"*"/manifests/"*)
      local name="${url#https://ghcr.io/v2/brf-tech/runr/}"
      name="${name%%/*}_${name##*/}"
      if [ -f "$tmp/manifest-${name}" ]; then
        body="$(cat "$tmp/manifest-${name}")"
        [ -n "$headers" ] && printf 'HTTP/2 200\r\ndocker-content-digest: sha256:%064d\r\n\r\n' 9 > "$headers"
      else
        status=404
      fi ;;
    "GET https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-php/versions?per_page=100&page=1")
      body='[{"id":31,"metadata":{"container":{"tags":["8.3.30-r1"]}}},{"id":32,"metadata":{"container":{"tags":["8.3.31-r1"]}}},{"id":33,"metadata":{"container":{"tags":["8.3", "8.3.35-r1"]}}}]' ;;
    "GET https://api.github.com/orgs/brf-tech/packages/container/"*"&page=2") body='[]' ;;
    "DELETE https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-php/versions/"*) status=204 ;;
    *) status=404 ;;
  esac
  [ -n "$headers" ] && [ "$headers" != "-" ] && [ ! -s "$headers" ] && printf 'HTTP/2 %s\r\n\r\n' "$status" > "$headers"
  if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
  if [ -n "$write" ]; then printf '%s' "$status"; fi
  return 0
}

feed_pull "$tmp/pulled.json" || fail "feed_pull of a published feed failed"
cmp -s "$tmp/pulled.json" "$tmp/blob" || fail "feed_pull: not the feed's layer"
[ "$FEED_DIGEST" = "sha256:$(printf '%064d' 7)" ] || fail "feed_pull: the manifest digest: $FEED_DIGEST"
grep -qx "GET https://ghcr.io/v2/brf-tech/runr/runtime-patches/blobs/${blob_digest}" "$curl_calls" || fail "feed_pull: the blob was not read"
manifest_status=404
rc=0; feed_pull "$tmp/pulled.json" 2>/dev/null || rc=$?
[ "$rc" = 3 ] || fail "feed_pull without a feed: exit $rc, not 3"
manifest_status=403
rc=0; feed_pull "$tmp/pulled.json" 2>/dev/null || rc=$?
[ "$rc" = 3 ] || fail "feed_pull of a package that cannot be read anonymously: exit $rc, not 3"
manifest_status=500
rc=0; feed_pull "$tmp/pulled.json" 2>/dev/null || rc=$?
[ "$rc" = 1 ] || fail "feed_pull with a registry error: exit $rc, not 1 (an error must not start an empty feed)"
manifest_status=200
printf '%s' '{"schema": 1, "tampered": true}' > "$tmp/blob"
rc=0; feed_pull "$tmp/pulled.json" 2>/dev/null || rc=$?
[ "$rc" = 1 ] || fail "feed_pull of a blob that does not match its digest: exit $rc"
printf '%s' "$feed_body" > "$tmp/blob"
echo "ok - feed_pull: the feed's layer by its digest; no feed (404, no anonymous access) apart from a registry error"

# --- publishing the feed -----------------------------------------------------------------------------
tool_calls="$tmp/tool.calls"
verify_ok=1
previous_key=""
existing_feed=0
oras() {
  echo "oras $*" >> "$tool_calls"
  case "$1 $2" in
    "manifest fetch")
      case "$*" in
        *":feed-candidate") echo "{\"digest\": \"sha256:$(printf '%064d' 5)\"}" ;;
        *":feed") [ "$existing_feed" = 1 ] && echo '{"digest": "sha256:x"}'; [ "$existing_feed" = 1 ]; return ;;
      esac ;;
    "push "*) [ -f "patch-feed.json" ] || return 1 ;;
  esac
  return 0
}
cosign() {
  echo "cosign $* password=${COSIGN_PASSWORD:-}" >> "$tool_calls"
  case "$1" in
    verify) [ "$verify_ok" = 1 ] || { [ -n "$previous_key" ] && [ "$3" = "$previous_key" ]; } ;;
    *) return 0 ;;
  esac
}
key="$tmp/patch-feed.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n' > "$key"
export PATCH_FEED_KEY="$key" RUNR_PATCH_FEED_COSIGN_KEY="private" RUNR_PATCH_FEED_COSIGN_PASSWORD="secret"
if [ -z "$validator" ]; then check-jsonschema() { :; }; fi
cp "$example" "$tmp/next.json"

: > "$tool_calls"
feed_push "$tmp/next.json" 0 > "$tmp/out" 2>&1 || fail "feed_push: $(cat "$tmp/out")"
digest="sha256:$(printf '%064d' 5)"
grep -n '' "$tool_calls" | sed 's/^\([0-9]*\):\([a-z]*\) \([a-z]*\).*/\1 \2 \3/' | paste -sd' ' - > "$tmp/order"
[ "$(cat "$tmp/order")" = "1 oras push 2 oras manifest 3 cosign sign 4 cosign verify 5 oras tag" ] || fail "feed_push order: $(cat "$tool_calls")"
push_call="$(grep '^oras push' "$tool_calls")"
[[ "$push_call" == "oras push ghcr.io/brf-tech/runr/runtime-patches:feed-candidate --artifact-type ${PATCH_FEED_MEDIA_TYPE} --annotation org.opencontainers.image.source=https://github.com/BRF-Tech/runr-runtimes "*" patch-feed.json:${PATCH_FEED_MEDIA_TYPE}" ]] \
  || fail "feed_push: the oras push ${push_call}"
grep -qxF "cosign sign --yes --tlog-upload=false --key env://RUNR_PATCH_FEED_COSIGN_KEY ghcr.io/brf-tech/runr/runtime-patches@${digest} password=secret" "$tool_calls" \
  || fail "feed_push: not signed by digest with the key: $(grep '^cosign sign' "$tool_calls")"
grep -qxF "cosign verify --key ${key} --insecure-ignore-tlog=true ghcr.io/brf-tech/runr/runtime-patches@${digest} password=" "$tool_calls" \
  || fail "feed_push: the signature not verified with the public key: $(grep '^cosign verify' "$tool_calls")"
grep -qxF "oras tag ghcr.io/brf-tech/runr/runtime-patches@${digest} feed" "$tool_calls" || fail "feed_push: not tagged feed"
: > "$tool_calls"
verify_ok=0
feed_push "$tmp/next.json" 0 > "$tmp/out" 2>&1 && fail "feed_push with a signature that does not verify passed"
grep -q '^oras tag' "$tool_calls" && fail "feed_push tagged a feed whose signature does not verify"
verify_ok=1
: > "$tool_calls"
existing_feed=1
feed_push "$tmp/next.json" 1 > "$tmp/out" 2>&1 && fail "feed_push replaced a feed it could not read"
grep -q '^oras push' "$tool_calls" && fail "feed_push pushed over a feed it could not read"
existing_feed=0
echo "ok - feed_push: candidate, signed by digest, verified with keys/patch-feed.pub, then tagged feed"

# feed_tools: the placeholder key and a missing signing key refuse a push
PATCH_FEED_KEY="$here/keys/patch-feed.pub" feed_tools 1 > "$tmp/out" 2>&1 && fail "feed_tools accepted the placeholder key"
grep -q 'not a public key' "$tmp/out" || fail "feed_tools placeholder: $(cat "$tmp/out")"
RUNR_PATCH_FEED_COSIGN_KEY="" feed_tools 1 > "$tmp/out" 2>&1 && fail "feed_tools without a signing key passed"
feed_tools 1 > "$tmp/out" 2>&1 || fail "feed_tools: $(cat "$tmp/out")"
echo "ok - a feed is published only with the public key and the signing key"

# --- a whole update: the registry's patches, retention -------------------------------------------------
echo '["8.3", "8.3.30-r1", "8.3.31-r1", "8.3.32-r1", "8.3.33-r1", "8.3.34-r1", "8.3.35-r1", "8.3.36-r1"]' > "$tmp/tags-exec-php"
for t in 8.3.32-r1 8.3.33-r1 8.3.34-r1 8.3.35-r1 8.3.36-r1; do
  jq -n '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: []}' > "$tmp/manifest-exec-php_$t"
done
# 8.3.36-r1: published, but its feed update did not run
mapfile -t ann < <(fjq '$e | patch_annotations("sha256:b"; "")' -r --argjson e "$(entry php 8.3 8.3.36-r1 2026-10-21T10:00:00Z)")
printf '%s\n' "${ann[@]}" | jq -Rn '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [],
  annotations: ([inputs | sub("^index:"; "") | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries)}' > "$tmp/manifest-exec-php_8.3.36-r1"
current='{"schema": 1, "generated_at": "2026-10-20T00:00:00Z", "patches": [], "platform": []}'
for t in 8.3.31-r1 8.3.32-r1 8.3.33-r1 8.3.34-r1 8.3.35-r1; do
  current=$(jq -c --argjson e "$(entry php 8.3 "$t" "2026-10-0${t:5:1}T00:00:00Z")" '.patches = [$e] + .patches' <<< "$current")
done
printf '%s' "$current" > "$tmp/blob"
blob_digest="sha256:$(sha256_of "$tmp/blob")"
: > "$curl_calls"
: > "$tool_calls"
feed_update 0 "" "$tmp/dry.json" > "$tmp/out" 2>&1 || fail "feed_update (dry run): $(cat "$tmp/out")"
[ "$(jq -r '.patches | map(.tag) | join(" ")' "$tmp/dry.json")" = "8.3.36-r1 8.3.35-r1 8.3.34-r1 8.3.33-r1 8.3.32-r1" ] \
  || fail "feed_update: the registry's patch not added or not the newest five: $(jq -c '.patches | map(.tag)' "$tmp/dry.json")"
grep -q '+ php-8.3-8.3.36-r1 routine' "$tmp/out" || fail "feed_update: the change not reported: $(cat "$tmp/out")"
grep -q -- '- php-8.3-8.3.31-r1' "$tmp/out" || fail "feed_update: the dropped patch not reported"
grep -q 'dry run: retention would delete ghcr.io/brf-tech/runr/exec-php: 8.3.30-r1 8.3.31-r1' "$tmp/out" || fail "feed_update: retention plan: $(cat "$tmp/out")"
grep -q '^DELETE' "$curl_calls" && fail "feed_update dry run deleted"
grep -qE '^(oras push|cosign sign)' "$tool_calls" && fail "feed_update dry run published"
grep -q 'signature verified' "$tmp/out" || fail "feed_update: the current feed's signature not verified"

: > "$curl_calls"
GHCR_TOKEN=token feed_update 1 "" "" > "$tmp/out" 2>&1 || fail "feed_update --push: $(cat "$tmp/out")"
grep -q '^oras tag' "$tool_calls" || fail "feed_update --push: not published"
grep -qx 'DELETE https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-php/versions/31' "$curl_calls" || fail "retention: 8.3.30-r1 not deleted: $(cat "$curl_calls")"
grep -qx 'DELETE https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-php/versions/32' "$curl_calls" || fail "retention: 8.3.31-r1 not deleted"
grep -q 'DELETE .*/versions/33' "$curl_calls" && fail "retention deleted the version of the floating tag"
verify_ok=0
: > "$tool_calls"
GHCR_TOKEN=token feed_update 1 "" "" > "$tmp/out" 2>&1 && fail "feed_update with a current feed whose signature does not verify passed"
grep -q '^oras push' "$tool_calls" && fail "feed_update published over a feed whose signature does not verify"
# a key rotation: the current feed verifies with the previous key
previous_key="$tmp/previous.pub"
PATCH_FEED_PREVIOUS_KEY="$previous_key" feed_update 0 "" "" > "$tmp/out" 2>&1 || fail "a key rotation: $(cat "$tmp/out")"
grep -q "signature verified with the previous key" "$tmp/out" || fail "a key rotation: $(cat "$tmp/out")"
previous_key=""
verify_ok=1
echo "ok - feed_update: the registry's patches added, the newest five, signed and published, retention through the Packages API"

# an unchanged feed is not published again
printf '%s' "$(jq -c '.generated_at = "2026-10-21T00:00:00Z"' "$tmp/dry.json")" > "$tmp/blob"
blob_digest="sha256:$(sha256_of "$tmp/blob")"
: > "$tool_calls"
GHCR_TOKEN=token feed_update 1 "" "" > "$tmp/out" 2>&1 || fail "feed_update of an up-to-date feed: $(cat "$tmp/out")"
grep -q 'up to date' "$tmp/out" || fail "feed_update: an unchanged feed not reported: $(cat "$tmp/out")"
grep -q '^oras push' "$tool_calls" && fail "feed_update published an unchanged feed"
echo "ok - an unchanged feed is not published again"

# --- ci.sh feed platform -------------------------------------------------------------------------------
: > "$tool_calls"
cmd_feed platform --version 0.5.11 --level zero-day --reason-en "Remote code execution in the API" \
  --reason-tr "API'de uzaktan kod çalıştırma" --url https://example.org/runr-0.5.11 --out "$tmp/platform.json" > "$tmp/out" 2>&1 \
  || fail "feed platform: $(cat "$tmp/out")"
[ "$(jq -c '.platform[0] | [.version, .level, .reason.tr, .url, .published_at]' "$tmp/platform.json")" \
  = '["0.5.11","zero-day","API'"'"'de uzaktan kod çalıştırma","https://example.org/runr-0.5.11","2026-10-21T14:30:00Z"]' ] \
  || fail "feed platform: $(jq -c '.platform' "$tmp/platform.json")"
grep -q '^oras push' "$tool_calls" && fail "feed platform without --push published"
cmd_feed platform --version v0.5 --level urgent --reason-en "" --reason-tr x > "$tmp/out" 2>&1 && fail "feed platform with bad input passed"
grep -q "version: 'v0.5'" "$tmp/out" && grep -q "level: 'urgent'" "$tmp/out" && grep -q 'reason (en)' "$tmp/out" || fail "feed platform problems: $(cat "$tmp/out")"
echo "ok - ci.sh feed platform: a checked platform release in the next feed"
