# ── Downloads that survive an upstream's bad minute ──
# This file is sourced, so it has no shebang. ci/fetch.sh (the workflows' tool installs) and
# lib/watch.sh (the checksums the language bot moves) download through it.
#
# fetch_download URL OUT — URL into OUT. curl retries every error FETCH_RETRIES times (default 5),
# FETCH_RETRY_DELAY seconds apart (default 10), and gives up on a connection after 30 seconds. A
# GitHub release asset (https://github.com/OWNER/REPO/releases/download/TAG/NAME) that still fails
# comes through the GitHub API instead: the release's asset endpoint, which answers when
# releases/download gives 504 (GH_TOKEN, when set, raises the API's rate limit). Exit 1 and
# "download failed: URL (HTTP CODE)" on stderr when nothing answered; OUT is then removed.
# Needs curl and jq.

FETCH_RETRIES="${FETCH_RETRIES:-5}"
FETCH_RETRY_DELAY="${FETCH_RETRY_DELAY:-10}"

# fetch_curl ARGS… — curl with the retries
fetch_curl() {
  curl -fsSL --retry "$FETCH_RETRIES" --retry-all-errors --retry-delay "$FETCH_RETRY_DELAY" --connect-timeout 30 "$@"
}

fetch_download() {
  local url="$1" out="$2" code path repo rest tag name asset auth=()
  code="$(fetch_curl -w '%{http_code}' -o "$out" "$url" 2>/dev/null)" && return 0
  # the last attempt's status
  code="${code: -3}"
  case "$url" in
    https://github.com/*/*/releases/download/*/*)
      path="${url#https://github.com/}"
      repo="${path%%/releases/download/*}"
      rest="${path#*/releases/download/}"
      tag="${rest%/*}"
      name="${rest##*/}"
      # no status in this line: an asset that comes through the API is no outage (lang-bot.sh upstream)
      echo "${url}: no answer after its retries, the release asset through the GitHub API instead" >&2
      [ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GH_TOKEN}")
      asset="$(fetch_curl ${auth[@]+"${auth[@]}"} -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null \
        | jq -r --arg n "$name" '[.assets[]? | select(.name == $n) | .url] | first // empty' 2>/dev/null)" || asset=""
      if [[ "$asset" == https://api.github.com/repos/"${repo}"/releases/assets/* ]] \
        && fetch_curl ${auth[@]+"${auth[@]}"} -H 'Accept: application/octet-stream' -o "$out" "$asset" 2>/dev/null; then
        return 0
      fi ;;
  esac
  rm -f -- "$out"
  echo "download failed: ${url} (HTTP ${code:-000})" >&2
  return 1
}
