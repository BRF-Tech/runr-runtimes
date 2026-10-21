# cmd_eol — EOL report of the runtime images + optional prune
#
# The images are the ones `ci.sh build --push` publishes: ${REGISTRY}/exec-<runtime> for the
# runtimes in RUNTIME_DEFS (REGISTRY defaults to ghcr.io/brf-tech/runr). Their tags are read from that
# registry through the OCI distribution API (GET /v2/<repo>/tags/list with the registry's token
# service), not from Docker Hub — Docker Hub only hosts the upstream base images.
#
# --prune deletes the EOL versions through the GitHub Packages API (GHCR has no tag delete in the
# OCI API): GHCR_TOKEN needs delete:packages; GHCR_OWNER_KIND=users for a user-owned namespace.
# GHCR_USERNAME + GHCR_TOKEN also authenticate the tag listing of private packages.
# The registry and GHCR helpers (registry_tags, ghcr_*) are in lib/registry.sh.

cmd_eol() {
  local prune=0 yes=0
  for arg in "$@"; do
    case "$arg" in
      --prune) prune=1 ;;
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

  local def runtime rest
  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime rest <<< "$def"
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
      result=$(check_eol "$runtime" "$tag")
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

  if [ "$prune" = "1" ] && [ "${#eol_list[@]}" -gt 0 ]; then
    prune_eol_tags "$yes" "${eol_list[@]}"
  fi
}

# prune_eol_tags <yes> <repo:tag>… — delete the EOL versions of ghcr.io/<owner>[/<path>]/<repo>.
# The GitHub package of ghcr.io/brf-tech/runr/exec-python is "runr/exec-python" of the owner
# brf-tech. A package version is one manifest: it is deleted only when every tag it carries is EOL.
prune_eol_tags() {
  local yes="$1"
  shift
  ghcr_api || exit 1

  if [ "$yes" = "0" ]; then
    echo -e "${YELLOW}These tags will be deleted:${NC}"
    local e
    for e in "$@"; do echo "  - ${REGISTRY}/${e}"; done
    echo ""
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }
  fi

  # the EOL tags of each repository, deleted together
  local entry repo repos=() tags
  for entry in "$@"; do
    repo="${entry%%:*}"
    [[ " ${repos[*]-} " == *" ${repo} "* ]] || repos+=("$repo")
  done
  for repo in "${repos[@]}"; do
    tags=()
    for entry in "$@"; do
      if [ "${entry%%:*}" = "$repo" ]; then tags+=("${entry#*:}"); fi
    done
    ghcr_delete_tags "$repo" "${tags[@]}" || true
  done
}
