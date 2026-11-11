#!/usr/bin/env bash
# A pinned download of a workflow (a tool it installs: crane, kind, kubectl, helm, shellcheck…):
# downloaded with retries, a GitHub release asset through the GitHub API when releases/download
# does not answer (lib/fetch.sh), then checked against its SHA256. Tested by test/fetch_test.sh.
#
#   bash ci/fetch.sh URL OUT SHA256
#
# Exit 1: the download failed, or its SHA256 is another one (OUT is removed). Needs bash, curl, jq
# and sha256sum.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/fetch.sh
source "${ROOT}/lib/fetch.sh"

url="${1:?usage: ci/fetch.sh URL OUT SHA256}" out="${2:?usage: ci/fetch.sh URL OUT SHA256}" sum="${3:?usage: ci/fetch.sh URL OUT SHA256}"
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "${sum}: not a SHA256" >&2; exit 1; }
fetch_download "$url" "$out"
if ! echo "${sum}  ${out}" | sha256sum -c -; then
  rm -f -- "$out"
  echo "${url}: its SHA256 is not ${sum}" >&2
  exit 1
fi
