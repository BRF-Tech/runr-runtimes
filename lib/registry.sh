# ── OCI registry and GHCR helpers ──
# This file is sourced, so it has no shebang.
#
# Reads go through the OCI distribution API (GET /v2/…) with the registry's token service, anonymous
# for public repositories; GHCR_USERNAME + GHCR_TOKEN authenticate the reads of private packages.
# GHCR has no tag delete in the OCI API: package versions are deleted through the GitHub Packages
# API (ghcr_*), with GHCR_TOKEN (delete:packages, or a workflow's GITHUB_TOKEN when the repository
# has the Admin role on the package); GHCR_OWNER_KIND=users for a user-owned namespace.

# The manifest types a read accepts: an image index (a multi-arch image), an image manifest, an
# artifact manifest (the patch feed)
REGISTRY_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# "ghcr.io/brf-tech/runr" → "ghcr.io" (Docker Hub's API host is registry-1.docker.io)
registry_api_host() {
  local host="${1%%/*}"
  case "$host" in
    docker.io|index.docker.io) echo "registry-1.docker.io" ;;
    *) echo "$host" ;;
  esac
}

# "ghcr.io/brf-tech/runr" → "brf-tech/runr" ("" for a registry without a namespace)
registry_namespace() {
  local ref="$1"
  if [[ "$ref" == */* ]]; then echo "${ref#*/}"; else echo ""; fi
}

# registry_token <api-host> <repository> — a pull token from the registry's token service
# (WWW-Authenticate: Bearer realm="…",service="…"); empty when the registry asks for none
registry_token() {
  local host="$1" repo="$2" challenge realm service
  challenge=$(curl -s -o /dev/null -D - "https://${host}/v2/" 2>/dev/null | tr -d '\r' | grep -i '^www-authenticate:' || true)
  [[ "$challenge" =~ realm=\"([^\"]+)\" ]] || return 0
  realm="${BASH_REMATCH[1]}"
  service="$host"
  if [[ "$challenge" =~ service=\"([^\"]+)\" ]]; then service="${BASH_REMATCH[1]}"; fi

  local auth=()
  if [ "$host" = "ghcr.io" ] && [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    auth=(-u "${GHCR_USERNAME}:${GHCR_TOKEN}")
  fi
  curl -sf ${auth[@]+"${auth[@]}"} "${realm}?service=${service}&scope=repository:${repo}:pull" 2>/dev/null \
    | grep -o '"token" *: *"[^"]*"' | head -1 | sed 's/^"token" *: *"//;s/"$//' || true
}

# registry_tags <api-host> <repository> — every tag of the repository, one per line
# (tags/list, following the Link: <…>; rel="next" pages); what it could read when a page fails
registry_tags() {
  local host="$1" repo="$2" token
  token=$(registry_token "$host" "$repo")

  local auth=()
  if [ -n "$token" ]; then auth=(-H "Authorization: Bearer ${token}"); fi

  local path="/v2/${repo}/tags/list?n=1000" pages=0 headers body
  headers=$(mktemp)
  while [ -n "$path" ] && [ "$pages" -lt 20 ]; do
    : > "$headers"
    body=$(curl -sf ${auth[@]+"${auth[@]}"} -D "$headers" "https://${host}${path}" 2>/dev/null) || break
    echo "$body" | grep -o '"tags" *: *\[[^]]*\]' | sed 's/^[^[]*\[//;s/\]$//' | tr ',' '\n' | tr -d '" ' | grep -v '^$' || true
    path=$(tr -d '\r' < "$headers" | grep -i '^link:' | grep -o '<[^>]*>' | head -1 | tr -d '<>' || true)
    pages=$((pages + 1))
  done
  rm -f "$headers"
}

# ref_split REF — sets _ref_host (API host), _ref_repo (repository path) and _ref_ref (tag or
# digest) of ghcr.io/brf-tech/runr/exec-php:8.3, …@sha256:… or a repository without a tag ("")
ref_split() {
  local ref="$1" name
  if [[ "$ref" == *@* ]]; then
    name="${ref%@*}"
    _ref_ref="${ref##*@}"
  elif [[ "${ref##*/}" == *:* ]]; then
    name="${ref%:*}"
    _ref_ref="${ref##*:}"
  else
    name="$ref"
    _ref_ref=""
  fi
  _ref_host="$(registry_api_host "$name")"
  _ref_repo="${name#*/}"
}

# registry_get URL OUT HEADERS [CURL ARG...] — GET with the token of the last ref_split; prints the
# HTTP status ("000" when curl failed)
registry_get() {
  local url="$1" out="$2" headers="$3" token status
  shift 3
  token=$(registry_token "$_ref_host" "$_ref_repo")
  local auth=()
  if [ -n "$token" ]; then auth=(-H "Authorization: Bearer ${token}"); fi
  status=$(curl -sS -o "$out" -D "$headers" -w '%{http_code}' ${auth[@]+"${auth[@]}"} "$@" "$url" 2>/dev/null) || true
  echo "${status:-000}"
}

# registry_manifest REF OUT — the manifest of REF (an image index for a multi-arch image) into
# OUT; prints its digest. Exit status: 0 read; 3 not found (HTTP 404: no such tag or repository);
# 4 denied (HTTP 401/403: GHCR answers so for a package that does not exist or that is private,
# without credentials that may read it); 1 any other failure.
registry_manifest() {
  local ref="$1" out="$2" headers status digest
  ref_split "$ref"
  headers=$(mktemp)
  status=$(registry_get "https://${_ref_host}/v2/${_ref_repo}/manifests/${_ref_ref:-latest}" "$out" "$headers" \
    -H "Accept: ${REGISTRY_ACCEPT}")
  digest=$(tr -d '\r' < "$headers" | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }' | head -n 1)
  rm -f -- "$headers"
  case "$status" in
    200) ;;
    404) return 3 ;;
    401|403) return 4 ;;
    *) echo "  ${ref}: HTTP ${status}" >&2; return 1 ;;
  esac
  if [ -z "$digest" ]; then
    digest="sha256:$(sha256_of "$out")"
  fi
  echo "$digest"
}

# registry_blob REPOSITORY DIGEST OUT — the blob DIGEST of REPOSITORY (host/path) into OUT,
# checked against its digest (redirects followed: GHCR serves blobs from another host)
registry_blob() {
  local repository="$1" digest="$2" out="$3" headers status
  ref_split "$repository"
  headers=$(mktemp)
  status=$(registry_get "https://${_ref_host}/v2/${_ref_repo}/blobs/${digest}" "$out" "$headers" -L)
  rm -f -- "$headers"
  if [ "$status" != 200 ]; then
    echo "  ${repository}@${digest}: HTTP ${status}" >&2
    return 1
  fi
  if [ "sha256:$(sha256_of "$out")" != "$digest" ]; then
    echo "  ${repository}@${digest}: the blob does not match its digest" >&2
    return 1
  fi
}

# registry_tags_checked REPOSITORY — every tag of REPOSITORY (host/path), one per line, like
# registry_tags but certain: no tag for a repository that does not exist (HTTP 404), a failure for
# any page that cannot be read (a tag a caller does not see could be overwritten)
registry_tags_checked() {
  local repository="$1" path headers body status pages=0
  ref_split "$repository"
  path="/v2/${_ref_repo}/tags/list?n=1000"
  headers=$(mktemp)
  body=$(mktemp)
  while [ -n "$path" ]; do
    if [ "$pages" -ge 50 ]; then
      echo "  ${repository}: more than 50 pages of tags" >&2
      rm -f -- "$headers" "$body"
      return 1
    fi
    status=$(registry_get "https://${_ref_host}${path}" "$body" "$headers")
    if [ "$status" = 404 ] && [ "$pages" = 0 ]; then
      rm -f -- "$headers" "$body"
      return 0
    fi
    if [ "$status" != 200 ]; then
      echo "  ${repository}: cannot list its tags (HTTP ${status}; a private package needs GHCR_USERNAME and GHCR_TOKEN)" >&2
      rm -f -- "$headers" "$body"
      return 1
    fi
    jq -r '.tags // [] | .[]' "$body" || { rm -f -- "$headers" "$body"; return 1; }
    path=$(tr -d '\r' < "$headers" | grep -i '^link:' | grep -o '<[^>]*>' | head -1 | tr -d '<>' || true)
    pages=$((pages + 1))
  done
  rm -f -- "$headers" "$body"
}

# sha256_of FILE — the hex SHA-256 of FILE
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

# ── GHCR package versions (GitHub Packages API) ──

# ghcr_api — the GitHub Packages API of REGISTRY's owner: sets _ghcr_api (…/packages/container),
# _ghcr_path (the package name prefix of REGISTRY's path, "runr/") and _ghcr_auth (curl headers).
# Fails outside GHCR, without GHCR_TOKEN or without jq.
ghcr_api() {
  local host ns owner
  host=$(registry_api_host "$REGISTRY")
  ns=$(registry_namespace "$REGISTRY")
  owner="${ns%%/*}"
  _ghcr_path=""
  [[ "$ns" == */* ]] && _ghcr_path="${ns#*/}/"

  if [ "$host" != "ghcr.io" ] || [ -z "$ns" ]; then
    echo -e "${RED}--prune supports GHCR (ghcr.io/<owner>) only; delete the tags of ${REGISTRY} in that registry.${NC}"
    return 1
  fi
  if [ -z "${GHCR_TOKEN:-}" ]; then
    echo -e "${RED}Set GHCR_TOKEN (a GitHub token with delete:packages, or a workflow's GITHUB_TOKEN with the Admin role on the package)${NC}"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}--prune needs jq.${NC}"
    return 1
  fi
  _ghcr_api="https://api.github.com/${GHCR_OWNER_KIND:-orgs}/${owner}/packages/container"
  _ghcr_auth=(-H "Authorization: Bearer ${GHCR_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
}

# ghcr_package REPO — the package name of ${REGISTRY}/REPO for the API: runr%2Fexec-python
ghcr_package() {
  local package="${_ghcr_path}$1"
  echo "${package//\//%2F}"
}

# ghcr_tag_version REPO TAG — "<id> <tag,tag,…>" of the package version of ${REGISTRY}/REPO that
# carries TAG; nothing when no version does (ghcr_api first)
ghcr_tag_version() {
  local package match="" page=1 versions
  package=$(ghcr_package "$1")
  while [ -z "$match" ] && [ "$page" -le 20 ]; do
    versions=$(curl -sf "${_ghcr_auth[@]}" "${_ghcr_api}/${package}/versions?per_page=100&page=${page}" 2>/dev/null) || break
    [ "$(echo "$versions" | jq 'length')" = "0" ] && break
    match=$(echo "$versions" | jq -r --arg t "$2" '.[] | select((.metadata.container.tags // []) | index($t)) | "\(.id) \(.metadata.container.tags | join(","))"' | head -1)
    page=$((page + 1))
  done
  echo "$match"
}

# ghcr_delete_version REPO ID — deletes the package version ID of ${REGISTRY}/REPO; prints the
# HTTP status (204: deleted)
ghcr_delete_version() {
  local package status_code
  package=$(ghcr_package "$1")
  status_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${_ghcr_auth[@]}" "${_ghcr_api}/${package}/versions/$2") || true
  echo "${status_code:-000}"
}

# ghcr_delete_tags REPO TAG... — deletes the package versions of ${REGISTRY}/REPO that carry the
# TAGs. A package version is one manifest: it is deleted only when every tag it carries is one of
# the TAGs, otherwise kept and reported. Exit 1 when a deletion failed (ghcr_api first).
ghcr_delete_tags() {
  local repo="$1" tag match id other keep status_code rc=0
  shift
  local doomed=" $* "
  for tag in "$@"; do
    echo -n "  Deleting ${REGISTRY}/${repo}:${tag}... "
    match=$(ghcr_tag_version "$repo" "$tag")
    if [ -z "$match" ]; then
      echo -e "${YELLOW}not found${NC}"
      continue
    fi
    id="${match%% *}"
    keep=""
    for other in $(echo "${match#* }" | tr ',' ' '); do
      [[ "$doomed" == *" ${other} "* ]] || keep="${keep:+${keep}, }${other}"
    done
    if [ -n "$keep" ]; then
      echo -e "${YELLOW}kept (the image is also tagged ${keep})${NC}"
      continue
    fi
    status_code=$(ghcr_delete_version "$repo" "$id")
    if [ "$status_code" = "204" ]; then
      echo -e "${GREEN}done${NC}"
    else
      echo -e "${RED}failed (HTTP ${status_code})${NC}"
      rc=1
    fi
  done
  return "$rc"
}
