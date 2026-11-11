#!/usr/bin/env bash
# Tests `ci.sh eol` without network: curl is a shell function that answers like GHCR (token
# service, paginated tags/list, the GitHub Packages API) and endoflife.date, and records every
# URL and header it is asked for. The EOL report reads the registry the exec-* images are pushed
# to (ghcr.io/brf-tech/runr), never Docker Hub. The archive of an EOL version (eol_archive_image)
# runs against a registry that keeps its tags in a file: crane and the Packages API as functions.
#
#   bash test/eol_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/eol.sh
source "$here/lib/eol.sh"

REGISTRY="ghcr.io/brf-tech/runr"
RUNTIME_DEFS=(
  "python|library/python|-slim|3.10|major.minor"
  "go|library/golang|-alpine|1.22|major.minor"
)
urls="$tmp/urls"
sent="$tmp/headers"
: > "$urls"
: > "$sent"

curl() {
  local url="" headers="" method="GET"
  while [ $# -gt 0 ]; do
    case "$1" in
      -D) headers="$2"; shift ;;
      -H) echo "$2" >> "$sent"; shift ;;
      -X) method="$2"; shift ;;
      -o|-w|-u|-d) shift ;;
      http*) url="$1" ;;
    esac
    shift
  done
  echo "${method} ${url}" >> "$urls"

  case "${method} ${url}" in
    "GET https://ghcr.io/v2/")
      [ "$headers" = "-" ] && printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/image:pull"\r\n\r\n'
      return 0 ;;
    "GET https://ghcr.io/token?"*)
      echo '{"token":"anon-token"}' ;;
    "GET https://ghcr.io/v2/brf-tech/runr/exec-python/tags/list?n=1000")
      printf 'HTTP/2 200\r\nlink: </v2/brf-tech/runr/exec-python/tags/list?last=3.12&n=1000>; rel="next"\r\n\r\n' > "$headers"
      echo '{"name":"brf-tech/runr/exec-python","tags":["3.8","3.12","latest"]}' ;;
    "GET https://ghcr.io/v2/brf-tech/runr/exec-python/tags/list?last=3.12&n=1000")
      printf 'HTTP/2 200\r\n\r\n' > "$headers"
      echo '{"name":"brf-tech/runr/exec-python","tags":["3.13"]}' ;;
    "GET https://ghcr.io/v2/brf-tech/runr/exec-go/tags/list?n=1000")
      printf 'HTTP/2 200\r\n\r\n' > "$headers"
      echo '{"name":"brf-tech/runr/exec-go","tags":["1.22"]}' ;;
    "GET https://endoflife.date/api/python/3.8.json")
      echo '{"cycle":"3.8","eol":"2024-10-07"}' ;;
    "GET https://endoflife.date/api/python/3.12.json" | "GET https://endoflife.date/api/python/3.13.json")
      echo '{"eol":"2099-10-31"}' ;;
    "GET https://endoflife.date/api/go/1.22.json")
      echo '{"cycle":"1.22","eol":"2025-02-11"}' ;;
    "GET https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-python/versions?per_page=100&page=1")
      echo '[{"id":11,"metadata":{"container":{"tags":["3.8"]}}},{"id":12,"metadata":{"container":{"tags":["3.12","latest"]}}}]' ;;
    "GET https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-go/versions?per_page=100&page=1")
      echo '[{"id":21,"metadata":{"container":{"tags":["1.22","1.22.5"]}}}]' ;;
    "GET https://api.github.com/orgs/brf-tech/packages/container/"*"&page=2")
      echo '[]' ;;
    "DELETE https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-python/versions/11")
      echo '204' ;;
    *)
      return 22 ;;
  esac
}

# --- report --------------------------------------------------------------------------------
out=$(cmd_eol 2>&1) || fail "cmd_eol failed: $out"

grep -q 'hub.docker.com' "$urls" && fail "the report queried Docker Hub"
grep -qx 'GET https://ghcr.io/v2/brf-tech/runr/exec-python/tags/list?n=1000' "$urls" || fail "exec-python tags not read from GHCR"
grep -qx 'GET https://ghcr.io/v2/brf-tech/runr/exec-python/tags/list?last=3.12&n=1000' "$urls" || fail "the next tags page was not followed"
grep -qx 'GET https://ghcr.io/v2/brf-tech/runr/exec-go/tags/list?n=1000' "$urls" || fail "exec-go tags not read from GHCR"
grep -q 'scope=repository:brf-tech/runr/exec-python:pull' "$urls" || fail "no pull token requested for exec-python"
grep -qx 'Authorization: Bearer anon-token' "$sent" || fail "tags/list was not sent the registry token"

echo "$out" | grep -q 'ghcr.io/brf-tech/runr/exec-python' || fail "report does not name the GHCR repository"
echo "$out" | grep -E '^  3\.8 ' | grep -q 'EOL' || fail "3.8 not reported EOL"
echo "$out" | grep -E '^  3\.13 ' | grep -q 'supported' || fail "3.13 (second page) not reported"
echo "$out" | grep -q 'latest' && fail "non-version tag reported"
echo "$out" | grep -q 'Supported: 2' || fail "supported count: $out"
echo "$out" | grep -q 'EOL: 2' || fail "EOL count: $out"

# --- archive -------------------------------------------------------------------------------
# A registry that keeps state: $reg holds "<repo> <tag> <digest>" lines; crane reads and moves the
# tags, the GitHub Packages API lists one package version per digest and deletes it with its tags
if command -v jq >/dev/null 2>&1; then
  reg="$tmp/registry"
  old="sha256:$(printf 'a%.0s' {1..64})"
  printf '%s\n' "exec-python 3.8 ${old}" "exec-python 3.8.20-r1 ${old}" "exec-python 3.8.19-r1 sha256:$(printf 'c%.0s' {1..64})" \
    "exec-python 3.12 sha256:$(printf 'd%.0s' {1..64})" > "$reg"
  # repo_tag REF — "<repo> <tag>" of ghcr.io/brf-tech/runr/<repo>:<tag>
  repo_tag() { local r="${1#ghcr.io/brf-tech/runr/}"; echo "${r%%:*} ${r#*:}"; }
  crane() {
    echo "crane $*" >> "$urls"
    local repo tag
    case "$1" in
      digest)
        if [[ "$2" == *@sha256:* ]]; then echo "${2#*@}"; return 0; fi
        read -r repo tag <<< "$(repo_tag "$2")"
        awk -v r="$repo" -v t="$tag" '$1 == r && $2 == t { print $3; f = 1 } END { exit !f }' "$reg" ;;
      tag)
        repo="${2#ghcr.io/brf-tech/runr/}"
        [ "${fail_tag:-}" != "$3" ] || return 1
        awk -v r="${repo%%@*}" -v t="$3" '!($1 == r && $2 == t)' "$reg" > "$reg.new" && mv "$reg.new" "$reg"
        echo "${repo%%@*} $3 ${repo#*@}" >> "$reg" ;;
      append)
        read -r repo tag <<< "$(repo_tag "$5")"
        [ "$2" = -f ] && [ -f "$3" ] || return 1
        awk -v r="$repo" -v t="$tag" '!($1 == r && $2 == t)' "$reg" > "$reg.new" && mv "$reg.new" "$reg"
        echo "${repo} ${tag} sha256:$(printf 'e%.0s' {1..64})" >> "$reg" ;;
      *) return 1 ;;
    esac
  }
  curl() {
    local url="" method="GET"
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) method="$2"; shift ;;
        -H|-o|-w|-u|-d|-D) shift ;;
        http*) url="$1" ;;
      esac
      shift
    done
    echo "${method} ${url}" >> "$urls"
    local base="https://api.github.com/orgs/brf-tech/packages/container/runr%2Fexec-python/versions"
    case "${method} ${url}" in
      "GET ${base}?per_page=100&page=1")
        awk '$1 == "exec-python" { print $3, $2 }' "$reg" | jq -Rn '[inputs | split(" ") | {d: .[0], t: .[1]}] | group_by(.d)
          | map({id: (.[0].d | .[7:15]), metadata: {container: {tags: map(.t)}}})' ;;
      "GET ${base}?per_page=100&page="*) echo '[]' ;;
      "DELETE ${base}/"*)
        [ "${fail_delete:-0}" = 0 ] || { echo 500; return 0; }
        awk -v id="${url##*/}" '!(substr($3, 8, 8) == id)' "$reg" > "$reg.new" && mv "$reg.new" "$reg"
        echo 204 ;;
      *) return 22 ;;
    esac
  }
  export EOL_ARCHIVE_WAIT=0
  REGISTRY="ghcr.io/brf-tech/runr"
  tags_of() { awk -v r="$1" -v d="$2" '$1 == r && $3 == d { print $2 }' "$reg" | sort | paste -sd ' ' -; }

  : > "$urls"
  out="$(GHCR_TOKEN=test-token eol_archive_image python 3.8 2>"$tmp/err")" || fail "archive: $(cat "$tmp/err")"
  [ "$out" = "$old" ] || fail "the archived digest: ${out}"
  [ "$(tags_of exec-python "$old")" = "3.8.20-r1 eol-3.8" ] || fail "the archived image's tags: $(cat "$reg")"
  grep -q '^exec-python 3.8 ' "$reg" && fail "the floating tag stayed: $(cat "$reg")"
  grep -q "^exec-python 3.8.19-r1 " "$reg" && grep -q '^exec-python 3.12 ' "$reg" || fail "another tag went: $(cat "$reg")"
  grep -q 'DELETE .*/versions/eeeeeeee$' "$urls" || fail "the empty image's package version was not deleted: $(cat "$urls")"
  grep -q "DELETE .*/versions/aaaaaaaa" "$urls" && fail "the archived image was deleted"
  # again: archived already, nothing changes
  cp "$reg" "$tmp/reg.before"
  out="$(GHCR_TOKEN=test-token eol_archive_image python 3.8 2>"$tmp/err")" || fail "archive again: $(cat "$tmp/err")"
  [ "$out" = "$old" ] && cmp -s "$reg" "$tmp/reg.before" && grep -qF 'archived already' "$tmp/err" || fail "archive again: ${out} $(cat "$tmp/err")"
  # the package version cannot be deleted: the floating tag goes back to the image, the run fails
  echo "exec-python 3.13 sha256:$(printf 'f%.0s' {1..64})" >> "$reg"
  fail_delete=1
  out="$(GHCR_TOKEN=test-token eol_archive_image python 3.13 2>"$tmp/err")" && fail "a failed deletion passed: ${out}"
  [ "$(tags_of exec-python "sha256:$(printf 'f%.0s' {1..64})")" = "3.13 eol-3.13" ] || fail "the floating tag was not put back: $(cat "$reg")"
  fail_delete=0
  # nothing to archive: no such tag
  GHCR_TOKEN=test-token eol_archive_image python 3.7 >/dev/null 2>&1 && fail "archive of a version the registry lacks"
  # ci.sh eol --archive: the EOL versions of the report (--prune is its former name)
  printf '%s\n' "exec-python 3.8 ${old}" "exec-python 3.8.20-r1 ${old}" "exec-python 3.12 sha256:$(printf 'd%.0s' {1..64})" > "$reg"
  out="$(GHCR_TOKEN=test-token archive_eol_tags 1 exec-python:3.8 2>&1)" || fail "archive_eol_tags: ${out}"
  grep -qF "ghcr.io/brf-tech/runr/exec-python:eol-3.8 (${old})" <<<"$out" && ! grep -q '^exec-python 3.8 ' "$reg" || fail "archive_eol_tags: ${out} $(cat "$reg")"
  unset -f crane curl
  echo "ok - archive: the image kept as eol-<version> with its patch tags, the floating tag gone (moved onto an empty image whose package version goes), again nothing, a failure puts the tag back"
else
  echo "skip: archive (jq not installed)"
fi

# --- the archive needs GHCR -------------------------------------------------------------------
REGISTRY="registry.example.com/runr"
out=$( (GHCR_TOKEN=x archive_eol_tags 1 "exec-python:3.8") 2>&1) && fail "archive outside GHCR did not fail"
echo "$out" | grep -q 'supports GHCR' || fail "archive outside GHCR: $out"

echo "ok: eol"
