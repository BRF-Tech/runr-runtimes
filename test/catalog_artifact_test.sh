#!/usr/bin/env bash
# Tests the runtime catalog (lib/catalog.py, lib/catalog.jq, lib/catalog.sh) without a registry:
# the catalog of the real runtimes/ (RunR's order, "@file" references inlined, no files), building
# from fixtures (YAML 1.2 types, @file variants and CRLF, files only for a dockerfile runtime, an id
# that is not its directory's name, a reference outside the runtime's directory, a duplicate key),
# the catalog against schema/runtime-catalog.v1.json and its rules, the example, and publishing
# (curl answers as the registry API, oras and cosign are shell functions that record their calls):
# the first publish, an unchanged catalog not published again, a changed one pushed as candidate,
# signed by digest, verified, then tagged stable and its immutable tag; a current catalog whose
# signature does not verify, uncommitted changes and missing keys refuse a push. Needs jq and
# python3 with PyYAML; the schema checks need check-jsonschema or python3 with jsonschema (skipped
# without one).
#
#   bash test/catalog_artifact_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "skip: catalog_artifact_test needs jq"; exit 0; }
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null \
  || { echo "skip: catalog_artifact_test needs python3 with PyYAML"; exit 0; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/feed.sh
source "$here/lib/feed.sh"
# shellcheck source=../lib/catalog.sh
source "$here/lib/catalog.sh"

REGISTRY="ghcr.io/brf-tech/runr"
revision="3a65d02b3a71ae7845af6e01fc3f4d17e5b85cba"
export CATALOG_NOW="2026-11-07T12:00:00Z" CATALOG_REVISION="$revision"
validator="$(feed_schema_validator)"

# cjq FILTER [ARG...] — jq with lib/catalog.jq included
cjq() {
  local filter="$1"
  shift
  jq -L "$here/lib" "$@" "include \"catalog\"; ${filter}"
}

# build DIR [PYTHON ARG...] — lib/catalog.py of the manifests in DIR, on stdout
build() {
  local dir="$1"
  shift
  python3 "$here/lib/catalog.py" --runtimes "$dir" --repository https://github.com/BRF-Tech/runr-runtimes \
    --revision "$revision" --generated-at "$CATALOG_NOW" "$@"
}

# --- the catalog of runtimes/ ---------------------------------------------------------------------------
build "$here/runtimes" > "$tmp/real.json" || fail "the catalog of runtimes/ does not build"
ids=$(jq -r '[.runtimes[].manifest.id] | join(" ")' "$tmp/real.json")
[ "$ids" = "python nodejs go php tensorflow pytorch bun dotnet java ruby wasm-exec wasm-go wasm-js wasm-python wasm-rust" ] \
  || fail "the catalog order: $ids"
[ "$(jq -r '[.runtimes[].path] | join(" ")' "$tmp/real.json")" = "$(for id in $ids; do printf 'runtimes/%s/runtime.yaml ' "$id"; done | sed 's/ $//')" ] \
  || fail "the paths: $(jq -c '[.runtimes[].path]' "$tmp/real.json")"
[ "$(jq -c '[.schema, .generated_at, .source, .patches]' "$tmp/real.json")" \
  = "[1,\"2026-11-07T12:00:00Z\",{\"repository\":\"https://github.com/BRF-Tech/runr-runtimes\",\"revision\":\"${revision}\"},[]]" ] \
  || fail "the header: $(jq -c '[.schema, .generated_at, .source, .patches]' "$tmp/real.json")"
jq -e '[.runtimes[] | select(has("files"))] | length == 0' "$tmp/real.json" >/dev/null \
  || fail "files for a runtime without a dockerfile version: $(jq -c '[.runtimes[] | select(has("files")) | .manifest.id]' "$tmp/real.json")"
# "@file" references inlined: the variants of go's wrapper, wasm-go's go.mod and spin.toml
[ "$(jq -r '.runtimes[] | select(.manifest.id == "go") | .manifest.build.files["runr_wrapper_.go"].http' "$tmp/real.json")" \
  = "$(cat "$here/runtimes/go/wrapper_http.go")" ] || fail "go: @wrapper_http.go not inlined"
[ "$(jq -r '.runtimes[] | select(.manifest.id == "go") | .manifest.build.files["runr_wrapper_.go"].schedule' "$tmp/real.json")" \
  = "$(cat "$here/runtimes/go/wrapper_schedule.go")" ] || fail "go: @wrapper_schedule.go not inlined"
[ "$(jq -r '.runtimes[] | select(.manifest.id == "wasm-go") | .manifest.build.files["spin.toml"]' "$tmp/real.json")" \
  = "$(cat "$here/runtimes/wasm-go/spin.toml")" ] || fail "wasm-go: @spin.toml not inlined"
[ "$(jq '[.. | strings | select(startswith("@"))] | length' "$tmp/real.json")" = 0 ] || fail "an @file reference left"
# the quoted version stays a string, numbers and booleans stay what they are
[ "$(jq -c '.runtimes[] | select(.manifest.id == "wasm-go") | [.manifest.versions[0].version, .manifest.versions[0].default, .manifest.resources.memory_mb, .manifest.resources.cpu]' "$tmp/real.json")" \
  = '["4.1",true,128,"100m"]' ] || fail "wasm-go: the types of version, default, memory_mb, cpu"
# Java's default size of new projects (its cold start)
[ "$(jq -c '.runtimes[] | select(.manifest.id == "java") | .manifest.resources' "$tmp/real.json")" = '{"cpu":"500m","memory_mb":512}' ]   || fail "java: its default resources: $(jq -c '.runtimes[] | select(.manifest.id == "java") | .manifest.resources' "$tmp/real.json")"
# the manifest is the YAML, nothing added
[ "$(jq -c '.runtimes[0].manifest | keys_unsorted' "$tmp/real.json")" \
  = '["apiVersion","kind","id","name","description","language","extensions","category","versionDiscovery","handler","template","dependencies","run","triggers","sandbox"]' ] \
  || fail "python's manifest keys: $(jq -c '.runtimes[0].manifest | keys_unsorted' "$tmp/real.json")"
catalog_validate "$tmp/real.json" > "$tmp/out" 2>&1 || [ "$?" = 2 ] || fail "the catalog of runtimes/ is not valid: $(cat "$tmp/out")"
echo "ok - the catalog of runtimes/: 15 runtimes in RunR's order, @file references inlined, no files, the YAML's types"

# --- building from fixtures -----------------------------------------------------------------------------
fx="$tmp/fixtures"
mkdir -p "$fx"
# manifest DIR ID [EXTRA YAML] — a small manifest in DIR/ID/runtime.yaml
manifest() {
  mkdir -p "$1/$2"
  {
    printf 'apiVersion: runr.sh/v1\nkind: Runtime\nid: %s\nname: %s\nextensions: [x]\n' "$2" "$2"
    printf '%s\n' "${3:-}"
    printf 'run:\n  mode: exec\n  command: ["x"]\n'
  } > "$1/$2/runtime.yaml"
}
manifest "$fx" zeta 'versions:
  - version: "3.10"
    image: ghcr.io/acme/zeta:3.10
    default: yes
    eol: 2027-06-30
env:
  A: yes
  B: 3.10
  C: 010
  D: ~
  E: true
  F: 0x1f
  G: 1e3
  H: off'
manifest "$fx" go 'versions:
  - version: "1.0"
    image: ghcr.io/acme/go:1.0
build:
  files:
    plain.txt: "@plain.txt"
    variant.go:
      http: "@http.go"
      schedule: "@schedule.go"
    literal.txt: "no reference"'
printf 'line one\r\nline two\r\n' > "$fx/go/plain.txt"
printf 'package http\n' > "$fx/go/http.go"
printf 'package schedule\n' > "$fx/go/schedule.go"
manifest "$fx" python 'versions:
  - version: "3.12"
    image: ghcr.io/acme/python:3.12'
manifest "$fx" alpha 'versions:
  - version: "1.0"
    image: ghcr.io/acme/alpha:1.0'
manifest "$fx" q 'versions:
  - version: "1.0"
    dockerfile: Dockerfile
    default: true
  - version: "2.0"
    image: ghcr.io/acme/q:2.0'
printf 'FROM scratch\r\nCOPY q /q\r\n' > "$fx/q/Dockerfile"
printf 'q interpreter\n' > "$fx/q/main.q"
printf '.git\n' > "$fx/q/.dockerignore"
mkdir -p "$fx/q/sub"
printf 'not part of the catalog\n' > "$fx/q/sub/nested.txt"
mkdir -p "$fx/no-manifest"

build "$fx" > "$tmp/fx.json" || fail "the fixtures do not build"
[ "$(jq -r '[.runtimes[].manifest.id] | join(" ")' "$tmp/fx.json")" = "python go alpha q zeta" ] \
  || fail "order: python and go first, the rest by path: $(jq -c '[.runtimes[].manifest.id]' "$tmp/fx.json")"
zeta=$(jq -c '.runtimes[] | select(.manifest.id == "zeta") | .manifest' "$tmp/fx.json")
[ "$(jq -c '[.versions[0].version, .versions[0].default, .versions[0].eol]' <<< "$zeta")" = '["3.10","yes","2027-06-30"]' ] \
  || fail "YAML 1.2: a quoted version, yes and a date stay strings: $(jq -c '.versions[0]' <<< "$zeta")"
[ "$(jq -c '.env | del(.G)' <<< "$zeta")" = '{"A":"yes","B":3.1,"C":10,"D":null,"E":true,"F":31,"H":"off"}' ] \
  && jq -e '.env.G == 1000' <<< "$zeta" >/dev/null || fail "YAML 1.2 core types: $(jq -c '.env' <<< "$zeta")"
go=$(jq -c '.runtimes[] | select(.manifest.id == "go") | .manifest.build.files' "$tmp/fx.json")
[ "$go" = '{"plain.txt":"line one\nline two\n","variant.go":{"http":"package http\n","schedule":"package schedule\n"},"literal.txt":"no reference"}' ] \
  || fail "@file: a string, the variants of an object, CRLF → LF, a literal kept: $go"
q=$(jq -c '.runtimes[] | select(.manifest.id == "q")' "$tmp/fx.json")
[ "$(jq -c '.files' <<< "$q")" = '{".dockerignore":".git\n","Dockerfile":"FROM scratch\nCOPY q /q\n","main.q":"q interpreter\n"}' ] \
  || fail "files of a dockerfile runtime: every regular file but runtime.yaml, not recursive, CRLF → LF: $(jq -c '.files' <<< "$q")"
[ "$(jq '[.runtimes[] | select(has("files"))] | length' "$tmp/fx.json")" = 1 ] || fail "files for a runtime without a dockerfile version"
catalog_validate "$tmp/fx.json" > "$tmp/out" 2>&1 || [ "$?" = 2 ] || fail "the fixtures' catalog is not valid: $(cat "$tmp/out")"
# the same sources, the same catalog
build "$fx" | cmp -s - "$tmp/fx.json" || fail "two builds of the same sources differ"

# build_fails NAME WANT — building the fixtures fails with a message that contains WANT
build_fails() {
  if build "$fx" > "$tmp/bad.json" 2> "$tmp/err"; then fail "$1: built"; fi
  grep -qF -- "$2" "$tmp/err" || fail "$1: $(cat "$tmp/err")"
}
cp "$fx/alpha/runtime.yaml" "$tmp/alpha.yaml"
sed -i 's/^id: alpha$/id: beta/' "$fx/alpha/runtime.yaml"
build_fails "an id that is not the directory's name" 'runtimes/alpha/runtime.yaml: the id is "beta", not the directory'"'"'s name alpha'
cp "$tmp/alpha.yaml" "$fx/alpha/runtime.yaml"
printf 'name: twice\n' >> "$fx/alpha/runtime.yaml"
build_fails "a duplicate key" "duplicate key 'name'"
cp "$tmp/alpha.yaml" "$fx/alpha/runtime.yaml"
printf 'build:\n  files:\n    x: "@missing.txt"\n' >> "$fx/alpha/runtime.yaml"
build_fails "a missing @file" "references @missing.txt, which does not exist next to the manifest"
cp "$tmp/alpha.yaml" "$fx/alpha/runtime.yaml"
printf 'build:\n  files:\n    x: "@../go/plain.txt"\n' >> "$fx/alpha/runtime.yaml"
build_fails "an @file outside the runtime's directory" "outside the manifest's directory"
cp "$tmp/alpha.yaml" "$fx/alpha/runtime.yaml"
printf 'when: !!timestamp 2026-01-01\n' >> "$fx/alpha/runtime.yaml"
build_fails "a value JSON cannot carry" "a value that is not JSON"
cp "$tmp/alpha.yaml" "$fx/alpha/runtime.yaml"
printf '\xff\xfe' > "$fx/q/binary.bin"
build_fails "a file that is not UTF-8 text" "q/binary.bin: not UTF-8 text"
rm -f -- "$fx/q/binary.bin"
build "$fx" | cmp -s - "$tmp/fx.json" || fail "the fixtures changed"
echo "ok - building: RunR's order, YAML 1.2 types, @file strings and variants (CRLF → LF), files only for a dockerfile runtime; a wrong id, a duplicate key, a missing or outside @file fail"

# --- the schema and the rules ---------------------------------------------------------------------------
check() { # check JSON — catalog_validate of the document: valid (without a schema validator: its rules)
  local rc=0
  printf '%s\n' "$1" > "$tmp/check.json"
  catalog_validate "$tmp/check.json" > "$tmp/check.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && [ -z "$validator" ]; }
}
example="$here/schema/runtime-catalog.example.json"
check "$(cat "$example")" || fail "the example: $(cat "$tmp/check.out")"
jq -e '([.runtimes[] | select(has("files"))] | length) == 1 and (.patches | length) == 1' "$example" >/dev/null \
  || fail "the example shows one dockerfile runtime and one patch"
fxj="$(cat "$tmp/fx.json")"
check "$(jq '.runtimes |= reverse' <<< "$fxj")" && fail "a catalog out of order passed"
grep -q 'not in the catalog order' "$tmp/check.out" || fail "out of order: $(cat "$tmp/check.out")"
check "$(jq '.runtimes += [.runtimes[-1]]' <<< "$fxj")" && fail "a duplicate runtime passed"
grep -q 'duplicate runtime id zeta' "$tmp/check.out" || fail "duplicate: $(cat "$tmp/check.out")"
check "$(jq '(.runtimes[] | select(.manifest.id == "zeta") | .manifest.id) = "other"' <<< "$fxj")" && fail "an id that is not its path's directory passed"
grep -q 'runtimes/zeta/runtime.yaml: the manifest'"'"'s id is "other"' "$tmp/check.out" || fail "id/path: $(cat "$tmp/check.out")"
check "$(jq '(.runtimes[] | select(.manifest.id == "q") | .manifest.versions[0].dockerfile) = "Containerfile"' <<< "$fxj")" && fail "a dockerfile not among the files passed"
head -c 930000 /dev/zero | tr '\0' 'a' > "$tmp/big.txt"
check "$(jq --rawfile big "$tmp/big.txt" '(.runtimes[] | select(.manifest.id == "q") | .files.big) = $big' <<< "$fxj")" \
  && fail "files of more than 900 KB passed"
grep -q 'runtimes/q/runtime.yaml: its files are 9300[0-9]* bytes (at most 921600)' "$tmp/check.out" || fail "900 KB: $(cat "$tmp/check.out")"
lua_patch=$(jq -c '.patches[0]' "$example")
check "$(jq --argjson p "$lua_patch" '.patches = [$p]' <<< "$fxj")" && fail "a patch of a runtime the catalog lacks passed"
grep -q 'patch lua-5.4-5.4.7-r2: the runtime lua is not in the catalog' "$tmp/check.out" || fail "patch runtime: $(cat "$tmp/check.out")"
check "$(jq '.patches += [.patches[0]]' "$example")" && fail "a duplicate patch passed"
check "$(jq '.patches[0].id = "lua-5.4-5.4.7-r3"' "$example")" && fail "a patch id that is not runtime-version-tag passed"
check "$(jq '.patches[0].tag = "5.5.0-r1" | .patches[0].id = "lua-5.4-5.5.0-r1"' "$example")" && fail "a tag of another version passed"
check "$(jq --argjson p "$lua_patch" '.patches = [range(6) as $i | $p | .tag = "5.4.\($i)-r1" | .id = "lua-5.4-5.4.\($i)-r1"]' "$example")" \
  && fail "six patches of one version passed"
if [ -n "$validator" ]; then
  check "$(jq '(.runtimes[] | select(.manifest.id == "zeta")).files = {"Dockerfile": "FROM x"}' <<< "$fxj")" && fail "files of a runtime without a dockerfile version passed"
  check "$(jq '(.runtimes[] | select(.manifest.id == "q")) |= del(.files)' <<< "$fxj")" && fail "a dockerfile runtime without files passed"
  check "$(jq '(.runtimes[] | select(.manifest.id == "q")).files["sub/nested.txt"] = "x"' <<< "$fxj")" && fail "a file name that is no ConfigMap key passed"
  check "$(jq '(.runtimes[] | select(.manifest.id == "q")).files[".."] = "x"' <<< "$fxj")" && fail "the file name .. passed"
  check "$(jq '(.runtimes[] | select(.manifest.id == "q")).files["runtime.yaml"] = "x"' <<< "$fxj")" && fail "runtime.yaml among the files passed"
  check "$(jq '(.runtimes[] | select(.manifest.id == "q")).files += ([range(50)] | map({key: "f\(.)", value: "x"}) | from_entries)' <<< "$fxj")" \
    && fail "more than 50 files passed"
  check "$(jq 'del(.runtimes[0].manifest.kind)' <<< "$fxj")" && fail "a manifest without kind passed"
  check "$(jq '.source.revision = "abc"' <<< "$fxj")" && fail "a short revision passed"
  check "$(jq '.runtimes = []' <<< "$fxj")" && fail "an empty catalog passed"
  check "$(jq '.schema = 2' <<< "$fxj")" && fail "schema 2 passed"
  check "$(jq '.extra = 1' <<< "$fxj")" && fail "an unknown field passed"
  check "$(jq '.patches[0].level = "zero-day"' "$example")" && fail "a zero-day patch without a deadline passed"
  check "$(jq '.runtimes[0].path = "runtimes/lua/manifest.yaml"' "$example")" && fail "a path that is not <id>/runtime.yaml passed"
  echo "ok - the catalog against schema/runtime-catalog.v1.json (${validator}) and its rules; the example"
else
  echo "skip - schema checks (no check-jsonschema, no python3 jsonschema); the rules and the example were checked"
fi
head -c $((CATALOG_MAX_BYTES + 1)) /dev/zero > "$tmp/huge.json"
catalog_validate "$tmp/huge.json" > "$tmp/out" 2>&1 && fail "a catalog of more than 8 MiB passed"
grep -q 'at most 8388608, 8 MiB' "$tmp/out" || fail "8 MiB: $(cat "$tmp/out")"
[ "$(catalog_version_tag "$tmp/fx.json")" = "202611071200-3a65d02b3a71" ] || fail "the immutable tag: $(catalog_version_tag "$tmp/fx.json")"
echo "ok - the rules: order, duplicates, id and path, a dockerfile among the files, 900 KB of files, 8 MiB, the patches; the immutable tag"

# --- publishing ------------------------------------------------------------------------------------------------
manifest_status=404
blob="$tmp/blob"
blob_digest=""
curl_calls="$tmp/curl.calls"
: > "$curl_calls"
# curl: the registry's answers (token service, the catalog's manifest and blob); records method and URL
curl() {
  local url="" out="" headers="" write="" method=GET
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
  case "$url" in
    "https://ghcr.io/v2/")
      [ "$headers" = "-" ] && printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io"\r\n\r\n'
      return 0 ;;
    "https://ghcr.io/token?"*) echo '{"token":"t"}'; return 0 ;;
    "https://ghcr.io/v2/brf-tech/runr/runtime-catalog/manifests/stable")
      status="$manifest_status"
      body=$(jq -cn --arg d "$blob_digest" --arg mt "$CATALOG_MEDIA_TYPE" \
        '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $mt,
          config: {mediaType: "application/vnd.oci.empty.v1+json", digest: "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", size: 2},
          layers: [{mediaType: $mt, digest: $d, size: 1}]}')
      [ -n "$headers" ] && printf 'HTTP/2 %s\r\ndocker-content-digest: sha256:%064d\r\n\r\n' "$status" 7 > "$headers" ;;
    "https://ghcr.io/v2/brf-tech/runr/runtime-catalog/blobs/${blob_digest}")
      body="$(cat "$blob")" ;;
    *) status=404 ;;
  esac
  [ -n "$headers" ] && [ "$headers" != "-" ] && [ ! -s "$headers" ] && printf 'HTTP/2 %s\r\n\r\n' "$status" > "$headers"
  if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
  if [ -n "$write" ]; then printf '%s' "$status"; fi
  return 0
}
# current JSON — the registry's stable is this catalog
current() {
  printf '%s' "$1" > "$blob"
  blob_digest="sha256:$(sha256_of "$blob")"
  manifest_status=200
}

tool_calls="$tmp/tool.calls"
verify_ok=1
existing=0
oras() {
  echo "oras $*" >> "$tool_calls"
  case "$1 $2" in
    "manifest fetch")
      case "$*" in
        *":stable-candidate") echo "{\"digest\": \"sha256:$(printf '%064d' 5)\"}" ;;
        *":stable") [ "$existing" = 1 ] && echo '{"digest": "sha256:x"}'; [ "$existing" = 1 ]; return ;;
      esac ;;
    "push "*) [ -f runtime-catalog.json ] || return 1; cp runtime-catalog.json "$tmp/pushed.json" ;;
  esac
  return 0
}
cosign() {
  echo "cosign $* password=${COSIGN_PASSWORD:-}" >> "$tool_calls"
  case "$1" in
    verify) [ "$verify_ok" = 1 ] ;;
    *) return 0 ;;
  esac
}
if [ -z "$validator" ]; then check-jsonschema() { :; }; fi
key="$tmp/patch-feed.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n' > "$key"
export CATALOG_KEY="$key" RUNR_PATCH_FEED_COSIGN_KEY="private" RUNR_PATCH_FEED_COSIGN_PASSWORD="secret"
export RUNTIMES_DIR="$fx"
calls() { # the tool calls as "<tool> <subcommand>", in order
  sed 's/^\([a-z]*\) \([a-z]*\).*/\1 \2/' "$tool_calls" | paste -sd, -
}

# the first publish: no stable yet
manifest_status=404
: > "$tool_calls"
catalog_publish 1 "$tmp/first.json" > "$tmp/out" 2>&1 || fail "the first publish: $(cat "$tmp/out")"
grep -q 'this is the first one' "$tmp/out" || fail "the first publish: $(cat "$tmp/out")"
[ "$(calls)" = "oras manifest,oras push,oras manifest,cosign sign,cosign verify,oras tag" ] || fail "the first publish's calls: $(cat "$tool_calls")"
digest="sha256:$(printf '%064d' 5)"
push_call="$(grep '^oras push' "$tool_calls")"
[[ "$push_call" == "oras push ghcr.io/brf-tech/runr/runtime-catalog:stable-candidate --artifact-type ${CATALOG_MEDIA_TYPE} --annotation org.opencontainers.image.source=https://github.com/BRF-Tech/runr-runtimes "*"--annotation org.opencontainers.image.revision=${revision} runtime-catalog.json:${CATALOG_MEDIA_TYPE}" ]] \
  || fail "the oras push: ${push_call}"
grep -qxF "cosign sign --yes --tlog-upload=false --key env://RUNR_PATCH_FEED_COSIGN_KEY ghcr.io/brf-tech/runr/runtime-catalog@${digest} password=secret" "$tool_calls" \
  || fail "not signed by digest with the patch feed's key: $(grep '^cosign sign' "$tool_calls")"
grep -qxF "cosign verify --key ${key} --insecure-ignore-tlog=true ghcr.io/brf-tech/runr/runtime-catalog@${digest} password=" "$tool_calls" \
  || fail "the signature not verified with the public key: $(grep '^cosign verify' "$tool_calls")"
grep -qxF "oras tag ghcr.io/brf-tech/runr/runtime-catalog@${digest} stable 202611071200-${revision:0:12}" "$tool_calls" \
  || fail "not tagged stable and the immutable tag: $(grep '^oras tag' "$tool_calls")"
cmp -s "$tmp/pushed.json" "$tmp/first.json" || fail "the pushed catalog is not the one built"
cmp -s "$tmp/first.json" "$tmp/fx.json" || fail "the published catalog differs from lib/catalog.py's"
# a stable that exists but could not be read (a private package without credentials) is not replaced
existing=1
: > "$tool_calls"
catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "a stable that could not be read was replaced"
grep -q '^oras push' "$tool_calls" && fail "pushed over a stable that could not be read"
existing=0
echo "ok - the first publish: candidate, signed by digest with the patch feed's key, verified, then tagged stable and <time>-<commit>"

# an unchanged catalog (another time, another commit) is not published again
current "$(jq -c --arg r "$(printf '%040d' 9)" '.generated_at = "2026-11-01T00:00:00Z" | .source.revision = $r' "$tmp/fx.json")"
: > "$tool_calls"
CATALOG_REVISION="$(printf 'b%039d' 1)" catalog_publish 1 "" > "$tmp/out" 2>&1 || fail "an unchanged catalog: $(cat "$tmp/out")"
grep -q 'the catalog is up to date: nothing to publish' "$tmp/out" || fail "an unchanged catalog not reported: $(cat "$tmp/out")"
grep -q 'signature verified' "$tmp/out" || fail "the current catalog's signature not verified: $(cat "$tmp/out")"
[ "$(calls)" = "cosign verify" ] || fail "an unchanged catalog was published: $(cat "$tool_calls")"
echo "ok - an unchanged catalog (other generated_at and revision) is not published again"

# a changed catalog: a new runtime, a changed one, a removed one
current "$(jq -c '(.runtimes[] | select(.manifest.id == "zeta") | .manifest.name) = "Zeta 0"
  | .runtimes |= map(select(.manifest.id != "alpha"))
  | .runtimes += [{path: "runtimes/old/runtime.yaml", manifest: {apiVersion: "runr.sh/v1", kind: "Runtime", id: "old"}}]' "$tmp/fx.json")"
: > "$tool_calls"
catalog_publish 0 "" > "$tmp/out" 2>&1 || fail "a dry run: $(cat "$tmp/out")"
grep -q '^  + alpha (runtimes/alpha/runtime.yaml)$' "$tmp/out" || fail "a new runtime not reported: $(cat "$tmp/out")"
grep -q '^  ~ zeta (manifest)$' "$tmp/out" || fail "a changed runtime not reported: $(cat "$tmp/out")"
grep -q '^  - old$' "$tmp/out" || fail "a removed runtime not reported: $(cat "$tmp/out")"
grep -q 'dry run: not published (--push publishes it as stable and 202611071200-3a65d02b3a71)' "$tmp/out" || fail "the dry run: $(cat "$tmp/out")"
grep -qE '^oras (push|tag)|^cosign sign' "$tool_calls" && fail "a dry run published"
: > "$tool_calls"
catalog_publish 1 "" > "$tmp/out" 2>&1 || fail "a changed catalog: $(cat "$tmp/out")"
[ "$(calls)" = "cosign verify,oras push,oras manifest,cosign sign,cosign verify,oras tag" ] || fail "a changed catalog's calls: $(cat "$tool_calls")"
grep -q "✓ ghcr.io/brf-tech/runr/runtime-catalog:stable and :202611071200-3a65d02b3a71 → ${digest} (signed)" "$tmp/out" || fail "the publish: $(cat "$tmp/out")"
# a changed file of a dockerfile runtime is a change; a new patch too
current "$(jq -c '(.runtimes[] | select(.manifest.id == "q") | .files["main.q"]) = "old\n"' "$tmp/fx.json")"
catalog_publish 0 "" > "$tmp/out" 2>&1 || fail "a changed file: $(cat "$tmp/out")"
grep -q '^  ~ q (files)$' "$tmp/out" || fail "a changed file not reported: $(cat "$tmp/out")"
echo "ok - a changed catalog: added, changed and removed runtimes reported, then candidate → signed → verified → stable"

# refusals: a registry error (not a first publish), a current catalog whose signature does not
# verify, a signature that does not verify after signing, uncommitted changes, a placeholder public
# key, no signing key
manifest_status=500
: > "$tool_calls"
catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "published after a registry error"
grep -q 'cannot read the current catalog: not published' "$tmp/out" || fail "a registry error: $(cat "$tmp/out")"
grep -q '^oras push' "$tool_calls" && fail "a registry error started a first publish"
current "$(jq -c '.runtimes |= map(select(.manifest.id != "alpha"))' "$tmp/fx.json")"
verify_ok=0
: > "$tool_calls"
catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "published over a catalog whose signature does not verify"
grep -q "the current catalog's signature does not verify" "$tmp/out" || fail "an unverified current catalog: $(cat "$tmp/out")"
grep -q '^oras push' "$tool_calls" && fail "pushed over a catalog whose signature does not verify"
CATALOG_PREVIOUS_KEY="$tmp/previous.pub" catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "a previous key that does not verify either passed"
verify_ok=1
cp "$tmp/fx.json" "$tmp/next.json"
cosign() {
  echo "cosign $* password=${COSIGN_PASSWORD:-}" >> "$tool_calls"
  case "$1" in
    verify) [[ "$*" != *"@sha256:$(printf '%064d' 5)"* ]] ;;  # the new signature does not verify
    *) return 0 ;;
  esac
}
: > "$tool_calls"
catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "a catalog whose new signature does not verify passed"
grep -q '^oras tag' "$tool_calls" && fail "stable moved to a catalog whose signature does not verify"
grep -q 'the signing key is not its pair' "$tmp/out" || fail "the new signature: $(cat "$tmp/out")"
cosign() {
  echo "cosign $* password=${COSIGN_PASSWORD:-}" >> "$tool_calls"
  case "$1" in
    verify) [ "$verify_ok" = 1 ] ;;
    *) return 0 ;;
  esac
}
echo '# PLACEHOLDER, NOT A KEY.' > "$tmp/placeholder.pub"
CATALOG_KEY="$tmp/placeholder.pub" catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "a placeholder key passed"
grep -q 'is not a public key' "$tmp/out" || fail "placeholder: $(cat "$tmp/out")"
RUNR_PATCH_FEED_COSIGN_KEY="" catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "no signing key passed"
grep -q 'The signing key is not set: RUNR_PATCH_FEED_COSIGN_KEY' "$tmp/out" || fail "no signing key: $(cat "$tmp/out")"
CATALOG_KEY="$here/keys/patch-feed.pub" catalog_key_ready || fail "keys/patch-feed.pub is not a public key"
if command -v git >/dev/null 2>&1; then
  git -C "$fx" init -q
  git -C "$fx" add -A
  git -C "$fx" -c user.name=t -c user.email=t@example.org commit -qm fixtures
  printf 'changed\n' >> "$fx/q/main.q"
  : > "$tool_calls"
  catalog_publish 1 "" > "$tmp/out" 2>&1 && fail "a catalog of uncommitted changes was published"
  grep -q 'has uncommitted changes' "$tmp/out" || fail "uncommitted changes: $(cat "$tmp/out")"
  grep -q '^oras push' "$tool_calls" && fail "pushed a catalog of uncommitted changes"
  catalog_publish 0 "" > "$tmp/out" 2>&1 || fail "a dry run of uncommitted changes: $(cat "$tmp/out")"
  git -C "$fx" checkout -q -- q/main.q
fi
echo "ok - refused: a registry error, a current catalog that does not verify, a new signature that does not verify, a placeholder key, no signing key, uncommitted changes"

# --- ci.sh catalog ----------------------------------------------------------------------------------------------
unset RUNTIMES_DIR
out=$("$here/ci.sh" catalog build 2>&1) || fail "ci.sh catalog build: $out"
for id in python nodejs go php tensorflow pytorch bun dotnet java ruby wasm-exec wasm-go wasm-js wasm-python wasm-rust; do
  grep -qE "^    ${id}  " <<< "$out" || fail "ci.sh catalog build: ${id} not in the summary: $out"
done
"$here/ci.sh" catalog build --out - 2>/dev/null | jq -e '.runtimes | length == 15' >/dev/null || fail "ci.sh catalog build --out -: no catalog on stdout"
"$here/ci.sh" catalog build --out "$tmp/ci.json" > /dev/null 2>&1 || fail "ci.sh catalog build --out FILE"
if [ -n "$validator" ]; then
  "$here/ci.sh" catalog validate "$tmp/ci.json" "$example" > "$tmp/out" 2>&1 || fail "ci.sh catalog validate: $(cat "$tmp/out")"
fi
"$here/ci.sh" catalog validate "$tmp/huge.json" > /dev/null 2>&1 && fail "ci.sh catalog validate passed a file of more than 8 MiB"
"$here/ci.sh" catalog nothing > /dev/null 2>&1 && fail "ci.sh catalog nothing passed"
echo "ok - ci.sh catalog build (summary, --out FILE and -), validate"
