#!/usr/bin/env bash
# Tests the downloads that survive an upstream's bad minute, without the network: curl is a script
# that answers from fixtures (a body, or an HTTP status such as 504) and records every call.
# Checks that:
#   - fetch_download (lib/fetch.sh) retries every error (--retry 5 --retry-all-errors), takes a
#     GitHub release asset that releases/download does not give through the GitHub API's asset
#     endpoint (GH_TOKEN to api.github.com alone), and says "download failed: URL (HTTP 504)" when
#     nothing answers, which lang-bot.sh upstream reads as an outage (the fallback's notice is none);
#   - ci/fetch.sh keeps a download whose SHA256 is the pinned one, removes any other;
#   - the download function of the WebAssembly Dockerfiles is one and the same in all of them, and
#     does the same under sh: retries, the asset through the API, the failure line;
#   - ci/check-dockerfiles.sh refuses a RUN step whose curl does not retry.
#
#   bash test/fetch_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip: fetch_test needs jq"; exit 0; }

# --- a curl that answers from fixtures ---------------------------------------------------------------
# $FX/<URL with every character but [A-Za-z0-9._-] as _>: the body (200); <name>@<code>: that status
mkdir -p "$tmp/bin" "$tmp/fx"
export FX="$tmp/fx" CALLS="$tmp/calls"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" write="" url="" fail=0 headers=()
args="$*"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) write="$2"; shift 2 ;;
    -H) headers+=("$2"); shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    --*) shift ;;
    -*) [[ "$1" == *f* ]] && fail=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl ${args}" >> "$CALLS"
file="${FX}/${url//[^A-Za-z0-9._-]/_}"
code=200
if [ ! -f "$file" ]; then
  code=404
  for f in "$file"@*; do [ -f "$f" ] && code="${f##*@}"; done
fi
# -w '%{http_code}', the one write-out the downloads ask for
[ -z "$write" ] || printf '%s' "$code"
if [ "$code" = 200 ]; then
  if [ -n "$out" ]; then cat "$file" > "$out"; else cat "$file"; fi
  exit 0
fi
[ "$fail" = 1 ] || exit 0
echo "curl: (22) The requested URL returned error: ${code}" >&2
exit 22
EOF
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
fx() { printf '%s' "$2" > "${FX}/${1//[^A-Za-z0-9._-]/_}"; }
fx_status() { : > "${FX}/${1//[^A-Za-z0-9._-]/_}@$2"; }

asset="https://github.com/spinframework/spin/releases/download/v4.1.0/spin-v4.1.0-static-linux-amd64.tar.gz"
api="https://api.github.com/repos/spinframework/spin/releases/tags/v4.1.0"
asset_api="https://api.github.com/repos/spinframework/spin/releases/assets/531067666"
# the release as the GitHub API gives it (pretty-printed; another asset first, an uploader object
# with a url of its own between)
release_json() {
  cat <<'EOF'
{
  "url": "https://api.github.com/repos/spinframework/spin/releases/377284455",
  "tag_name": "v4.1.0",
  "body": "notes with \"url\": \"https://api.github.com/repos/x/y/releases/assets/1\"",
  "assets": [
    {
      "url": "https://api.github.com/repos/spinframework/spin/releases/assets/531067388",
      "id": 531067388,
      "node_id": "RA_kwDOGUDWsM4fp3H8",
      "name": "checksums-v4.1.0.txt",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7605165,
        "url": "https://api.github.com/users/someone"
      },
      "browser_download_url": "https://github.com/spinframework/spin/releases/download/v4.1.0/checksums-v4.1.0.txt"
    },
    {
      "url": "https://api.github.com/repos/spinframework/spin/releases/assets/531067666",
      "id": 531067666,
      "node_id": "RA_kwDOGUDWsM4fp3MS",
      "name": "spin-v4.1.0-static-linux-amd64.tar.gz",
      "label": "",
      "uploader": {
        "login": "someone",
        "id": 7605165,
        "url": "https://api.github.com/users/someone"
      },
      "browser_download_url": "https://github.com/spinframework/spin/releases/download/v4.1.0/spin-v4.1.0-static-linux-amd64.tar.gz"
    }
  ]
}
EOF
}

# shellcheck source=../lib/fetch.sh
source "$here/lib/fetch.sh"
bot="$here/ci/lang-bot.sh"

# --- fetch_download -----------------------------------------------------------------------------------
fx https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl 'kubectl'
: > "$CALLS"
fetch_download https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl "$tmp/kubectl" 2> "$tmp/err" || fail "a download that answers: $(cat "$tmp/err")"
[ "$(cat "$tmp/kubectl")" = kubectl ] || fail "the download's body"
grep -qF -- '--retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30' "$CALLS" || fail "no retries: $(cat "$CALLS")"
[ "$(wc -l < "$CALLS")" = 1 ] || fail "more calls than one: $(cat "$CALLS")"

# releases/download gives 504: the asset through the API, with GH_TOKEN there alone
fx_status "$asset" 504
fx "$api" "$(release_json)"
fx "$asset_api" 'spin amd64'
: > "$CALLS"
GH_TOKEN=t0ken fetch_download "$asset" "$tmp/spin.tar.gz" 2> "$tmp/err" || fail "the asset through the API: $(cat "$tmp/err") $(cat "$CALLS")"
[ "$(cat "$tmp/spin.tar.gz")" = 'spin amd64' ] || fail "the API's asset"
grep -F "$asset_api" "$CALLS" | grep -qF "Accept: application/octet-stream" || fail "the asset endpoint: $(cat "$CALLS")"
grep -F "$asset" "$CALLS" | grep -qF 'Authorization' && fail "the token went to github.com: $(cat "$CALLS")"
grep -F "$api" "$CALLS" | grep -qF 'Authorization: Bearer t0ken' || fail "no token to the API: $(cat "$CALLS")"
grep -qF 'download failed' "$tmp/err" && fail "a download that came through the API failed: $(cat "$tmp/err")"
bash "$bot" upstream "$tmp/err" >/dev/null && fail "the API's fallback notice read as an outage: $(cat "$tmp/err")"

# the API fails too: the failure line, the file gone, an outage for lang-bot.sh upstream
rm -f "${FX}/${api//[^A-Za-z0-9._-]/_}"
fx_status "$api" 503
echo partial > "$tmp/spin.tar.gz"
fetch_download "$asset" "$tmp/spin.tar.gz" 2> "$tmp/err" && fail "a download nothing answered passed"
grep -qxF "download failed: ${asset} (HTTP 504)" "$tmp/err" || fail "the failure line: $(cat "$tmp/err")"
[ ! -e "$tmp/spin.tar.gz" ] || fail "a failed download left its file"
[ "$(bash "$bot" upstream "$tmp/err")" = "download failed: ${asset} (HTTP 504)" ] || fail "the failure is no outage for lang-bot.sh upstream"
# a download that is not a GitHub release asset: no API
fx_status https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz 502
: > "$CALLS"
fetch_download https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz "$tmp/helm.tar.gz" 2> "$tmp/err" && fail "a 502 passed"
grep -qF api.github.com "$CALLS" && fail "the API for another host: $(cat "$CALLS")"
grep -qxF 'download failed: https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz (HTTP 502)' "$tmp/err" || fail "the 502: $(cat "$tmp/err")"
echo "ok - fetch_download: retries, a GitHub release asset through the API (the token there alone), the failure line an outage"

# --- ci/fetch.sh: the pinned SHA256 -------------------------------------------------------------------
sum="$(printf 'kubectl' | sha256sum | cut -d' ' -f1)"
bash "$here/ci/fetch.sh" https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl "$tmp/k" "$sum" >/dev/null 2>&1 || fail "ci/fetch.sh with its SHA256"
[ "$(cat "$tmp/k")" = kubectl ] || fail "ci/fetch.sh's file"
bash "$here/ci/fetch.sh" https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl "$tmp/k2" "$(printf '0%.0s' {1..64})" >/dev/null 2>&1 && fail "another SHA256 passed"
[ ! -e "$tmp/k2" ] || fail "a download with another SHA256 stayed"
bash "$here/ci/fetch.sh" https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl "$tmp/k3" "abc" >/dev/null 2>&1 && fail "no SHA256 passed"
bash "$here/ci/fetch.sh" https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz "$tmp/h" "$sum" >/dev/null 2>&1 && fail "a failed download passed"
echo "ok - ci/fetch.sh: the download kept with its pinned SHA256, removed with another"

# --- the WebAssembly Dockerfiles' download ----------------------------------------------------------
# download() { … }; of a Dockerfile's RUN step, as sh reads it
func_of() { sed -n '/^    download() { \\$/,/^    }; \\$/p' "$1" | sed -e 's/^    //' -e 's/ \\$//'; }
ref="$(func_of "$here/runtimes/wasm-exec/Dockerfile")"
[ -n "$ref" ] || fail "runtimes/wasm-exec/Dockerfile has no download function"
for d in wasm-go wasm-js wasm-python wasm-rust; do
  [ "$(func_of "$here/runtimes/$d/Dockerfile")" = "$ref" ] || fail "runtimes/${d}/Dockerfile has another download function"
  grep -qE '^    download /tmp/spin\.tar\.gz "https://github\.com/spinframework/spin/releases/download/' "$here/runtimes/$d/Dockerfile" \
    || fail "runtimes/${d}/Dockerfile does not download Spin with it"
done
for f in spin wasi-sdk zig wasm-tools; do
  grep -qE "^    download /tmp/${f}\.tar\." "$here/runtimes/wasm-exec/Dockerfile" || fail "wasm-exec does not download ${f} with it"
done
dl() { sh -c "set -eu; ${ref}"$'\n'"download \"\$1\" \"\$2\"" sh "$@"; }
fx "$api" "$(release_json)"
rm -f "${FX}/${api//[^A-Za-z0-9._-]/_}@503"
: > "$CALLS"
dl "$tmp/d1" https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl 2> "$tmp/err" || fail "the Dockerfiles' download: $(cat "$tmp/err")"
[ "$(cat "$tmp/d1")" = kubectl ] && grep -qF -- '--retry 5 --retry-all-errors --retry-delay 10' "$CALLS" || fail "the Dockerfiles' download: $(cat "$CALLS")"
dl "$tmp/d2" "$asset" 2> "$tmp/err" || fail "the Dockerfiles' download through the API: $(cat "$tmp/err") $(cat "$CALLS")"
[ "$(cat "$tmp/d2")" = 'spin amd64' ] || fail "the Dockerfiles' download: not the API's asset"
grep -F "$asset_api" "$CALLS" | grep -qF "Accept: application/octet-stream" || fail "the Dockerfiles' download: the asset endpoint: $(cat "$CALLS")"
bash "$bot" upstream "$tmp/err" >/dev/null && fail "the Dockerfiles' fallback notice read as an outage"
rm -f "${FX}/${api//[^A-Za-z0-9._-]/_}"
fx_status "$api" 503
dl "$tmp/d3" "$asset" 2> "$tmp/err" && fail "the Dockerfiles' download: nothing answered, it passed"
grep -qxF "download failed: ${asset} (HTTP 504)" "$tmp/err" || fail "the Dockerfiles' download: the failure line: $(cat "$tmp/err")"
# BuildKit's prefix in front: an outage still
sed 's/^/#10 28.19 /' "$tmp/err" > "$tmp/build.log"
bash "$bot" upstream "$tmp/build.log" >/dev/null || fail "an outage in a RUN step's output: $(cat "$tmp/build.log")"
echo "ok - the WebAssembly Dockerfiles: one download function, retries, a release asset through the API, the failure line"

# --- ci/check-dockerfiles.sh: a curl that does not retry ----------------------------------------------
mkdir -p "$tmp/df"
printf 'FROM ghcr.io/brf-tech/runr/reqs/curl:latest\nRUN apt-get install -y curl; \\\n    curl -fsSL -o /tmp/x https://example.org/x\n' > "$tmp/df/Dockerfile"
out="$(bash "$here/ci/check-dockerfiles.sh" "$tmp/df/Dockerfile" 2>&1)" && fail "a curl without --retry passed: ${out}"
grep -qF "$tmp/df/Dockerfile:3: RUN runs curl without --retry" <<<"$out" || fail "check-dockerfiles: ${out}"
printf 'FROM ghcr.io/brf-tech/runr/reqs/curl:latest\nRUN apt-get install -y curl; \\\n    curl -fsSL --retry 5 -o /tmp/x https://example.org/x\n' > "$tmp/df/Dockerfile"
bash "$here/ci/check-dockerfiles.sh" "$tmp/df/Dockerfile" >/dev/null 2>&1 || fail "a curl with --retry: $(bash "$here/ci/check-dockerfiles.sh" "$tmp/df/Dockerfile" 2>&1)"
echo "ok - ci/check-dockerfiles.sh: every curl of a RUN step retries"
