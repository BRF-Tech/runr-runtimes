# cmd_eol — EOL report of the runtime images + the archive of the end-of-life ones
#
# The images are the ones `ci.sh build --push` publishes: ${REGISTRY}/exec-<runtime> for the
# runtimes in RUNTIME_DEFS (REGISTRY defaults to ghcr.io/brf-tech/runr). Their tags are read from that
# registry through the OCI distribution API (GET /v2/<repo>/tags/list with the registry's token
# service), not from Docker Hub — Docker Hub only hosts the upstream base images.
#
# --archive (--prune, its former name) archives the EOL versions in the registry (eol_archive_image):
# the image stays as exec-<runtime>:eol-<major.minor> with its patch tags, the floating tag goes,
# so RunR's discovery no longer offers the version and nothing that runs it by digest breaks. The
# language bot does the same by itself after an end of life, with the records of the repository
# (ci/lang-bot.sh archive: runtimes/<runtime>/archived-versions, tested-versions, the lifecycle).
# It needs crane, logged in with write access, and GHCR_TOKEN (a token that may delete package
# versions: a workflow's GITHUB_TOKEN with the Admin role on the package; GHCR_OWNER_KIND=users for
# a user-owned namespace). GHCR_USERNAME + GHCR_TOKEN also authenticate the tag listing of private
# packages. The registry and GHCR helpers (registry_tags, ghcr_*) are in lib/registry.sh.

cmd_eol() {
  local archive=0 yes=0
  for arg in "$@"; do
    case "$arg" in
      --archive|--prune) archive=1 ;;
      --yes)   yes=1 ;;
    esac
  done

  local host ns
  host=$(registry_api_host "$REGISTRY")
  ns=$(registry_namespace "$REGISTRY")
  local eol_list=()
  local supported_list=()
  local found=0

  echo ""
  echo -e "${BOLD}EOL Check — ${REGISTRY}/exec-*${NC}"
  echo -e "${BOLD}$(date +%Y-%m-%d)${NC}"
  echo ""

  local def runtime rest product
  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime rest <<< "$def"
    product="$(runtime_product "$runtime")"
    local repo="exec-${runtime}"
    echo -e "${BOLD}── ${REGISTRY}/${repo} ──${NC}"

    local tags
    tags=$(registry_tags "$host" "${ns:+${ns}/}${repo}" | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | uniq || true)
    if [ -z "$tags" ]; then
      echo -e "  ${YELLOW}No version tags found${NC}"
      echo ""
      continue
    fi
    found=1

    local tag
    for tag in $tags; do
      local result
      result=$(check_eol "$product" "$tag")
      local status="${result%%|*}"
      local eol_date="${result#*|}"
      [ "$status" = "$result" ] && eol_date="?"

      case "$status" in
        supported)
          printf "  %-10s %-14s ${GREEN}%s${NC}\n" "$tag" "$eol_date" "✓ supported"
          supported_list+=("${runtime}:${tag}")
          ;;
        eol)
          printf "  %-10s %-14s ${RED}%s${NC}\n" "$tag" "$eol_date" "✗ EOL"
          eol_list+=("${repo}:${tag}")
          ;;
        *)
          printf "  %-10s %-14s %s\n" "$tag" "?" "? unknown"
          ;;
      esac
    done
    echo ""
  done

  if [ "$found" = "0" ]; then
    echo "No ${REGISTRY}/exec-* image tags found."
    exit 1
  fi

  echo -e "${BOLD}── Summary ──${NC}"
  echo -e "  ${GREEN}Supported: ${#supported_list[@]}${NC}"
  echo -e "  ${RED}EOL: ${#eol_list[@]}${NC}"
  echo ""

  if [ "$archive" = "1" ] && [ "${#eol_list[@]}" -gt 0 ]; then
    archive_eol_tags "$yes" "${eol_list[@]}"
  fi
}

# archive_eol_tags <yes> <repo:tag>… — archive the EOL versions (eol_archive_image), after a
# confirmation unless <yes> is 1
archive_eol_tags() {
  local yes="$1" entry repo version digest rc=0 err
  shift
  ghcr_api || exit 1

  if [ "$yes" = "0" ]; then
    echo -e "${YELLOW}These versions will be archived (exec-<runtime>:${ARCHIVE_TAG_PREFIX}<version>, the floating tag removed):${NC}"
    for entry in "$@"; do echo "  - ${REGISTRY}/${entry}"; done
    echo ""
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }
  fi

  for entry in "$@"; do
    repo="${entry%%:*}"
    version="${entry#*:}"
    echo -n "  Archiving ${REGISTRY}/${entry}... "
    err="$(mktemp)"
    if digest=$(eol_archive_image "${repo#exec-}" "$version" 2>"$err"); then
      echo -e "${GREEN}${REGISTRY}/${repo}:${ARCHIVE_TAG_PREFIX}${version} (${digest})${NC}"
    else
      echo -e "${RED}failed${NC}"
      sed 's/^/    /' "$err"
      rc=1
    fi
    rm -f -- "$err"
  done
  echo "The repository's records (runtimes/<runtime>/archived-versions) come with the language bot: ci/lang-bot.sh archive."
  return "$rc"
}

# eol_archive_image RUNTIME VERSION — archives ${REGISTRY}/exec-RUNTIME:VERSION in the registry and
# prints the digest it named. The digest gets the tag eol-VERSION (its patch tags stay on it), then
# the floating tag VERSION goes: GHCR deletes no tag by itself, so the tag moves onto an empty image
# of its own first, whose package version (it carries that tag alone) is deleted through the GitHub
# Packages API. A failure after the move puts the floating tag back. Again on an archived version
# (the floating tag gone, eol-VERSION there): prints its digest, changes nothing. Progress on
# stderr. Needs crane (logged in with write access), GHCR_TOKEN and jq (ghcr_api).
eol_archive_image() {
  local runtime="$1" version="$2" repo ref eol digest moved match tries=0 status work
  repo="${REGISTRY}/exec-${runtime}"
  ref="${repo}:${version}"
  eol="${repo}:${ARCHIVE_TAG_PREFIX}${version}"
  if ! digest="$(crane digest "$ref" 2>/dev/null)" || [ -z "$digest" ]; then
    # archived already (a run that stopped after the registry, or a second one)
    digest="$(crane digest "$eol" 2>/dev/null)" || { echo "${ref} is not there, nor ${eol}: nothing to archive" >&2; return 1; }
    echo "${ref} is gone and ${eol} is ${digest}: archived already" >&2
    echo "$digest"
    return 0
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "${ref}: no digest (${digest})" >&2; return 1; }
  ghcr_api >&2 || return 1
  crane tag "${repo}@${digest}" "${ARCHIVE_TAG_PREFIX}${version}" >&2 || { echo "${eol}: not tagged" >&2; return 1; }
  [ "$(crane digest "$eol" 2>/dev/null)" = "$digest" ] || { echo "${eol} is not ${digest}" >&2; return 1; }
  echo "${eol} is ${digest}" >&2

  # the floating tag onto an empty image of its own
  work="$(mktemp -d)"
  tar -cf "${work}/empty.tar" -T /dev/null
  if ! crane append -f "${work}/empty.tar" -t "$ref" >&2; then
    rm -rf -- "$work"
    echo "${ref}: not moved off ${digest}" >&2
    return 1
  fi
  rm -rf -- "$work"
  moved="$(crane digest "$ref" 2>/dev/null)" || moved=""
  if [ -z "$moved" ] || [ "$moved" = "$digest" ]; then
    echo "${ref}: still ${digest}" >&2
    return 1
  fi
  # its package version, which GHCR lists shortly after the push: that tag alone, then deleted
  while :; do
    match="$(ghcr_tag_version "exec-${runtime}" "$version")"
    [ -z "$match" ] || break
    tries=$((tries + 1))
    [ "$tries" -lt "${EOL_ARCHIVE_TRIES:-6}" ] || break
    sleep "${EOL_ARCHIVE_WAIT:-5}"
  done
  status=""
  if [ -n "$match" ] && [ "${match#* }" = "$version" ]; then
    status="$(ghcr_delete_version "exec-${runtime}" "${match%% *}")"
  fi
  if [ "$status" != 204 ] || crane digest "$ref" >/dev/null 2>&1; then
    echo "${ref}: its package version (${match:-not listed}) was not deleted (HTTP ${status:-none}): the tag goes back to ${digest}" >&2
    crane tag "${repo}@${digest}" "$version" >&2 || echo "${ref}: could not be put back; ${eol} has the image" >&2
    return 1
  fi
  [ "$(crane digest "$eol" 2>/dev/null)" = "$digest" ] || { echo "${eol} is no longer ${digest}" >&2; return 1; }
  echo "${ref} is gone; the image stays as ${eol}" >&2
  echo "$digest"
}
