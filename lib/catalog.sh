# ── The runtime catalog ──
# This file is sourced, so it has no shebang. It uses lib/registry.sh and the schema validator of
# lib/feed.sh.
#
# The manifests of runtimes/<id>/runtime.yaml as one signed JSON document
# (schema/runtime-catalog.v1.json), so a RunR installation learns about a new or changed runtime
# without a RunR release: it reads ${REGISTRY}/runtime-catalog:stable periodically. The catalog is
# an OCI artifact like the patch feed: one layer of application/vnd.runr.runtime-catalog.v1+json
# (at most 8 MiB), an empty config, signed with cosign (the classic sha256-<digest>.sig of its
# manifest, without a transparency log entry).
#
# A publish (ci.sh catalog publish --push):
#   1. builds the catalog from runtimes/ (lib/catalog.py: the rules of RunR's own bundle,
#      BuiltinCatalog::readSources) and checks it against schema/runtime-catalog.v1.json and the
#      rules the schema cannot express (lib/catalog.jq catalog_problems)
#   2. pulls the current stable and verifies its signature (none: the first publish)
#   3. compares the runtimes and patches of both, not generated_at or source.revision: an
#      unchanged catalog is not published again
#   4. pushes the new one as stable-candidate, signs it by digest, verifies the signature with the
#      public key, then tags it stable and <YYYYMMDDHHMM>-<12 hex of the commit> (so stable only
#      ever names a signed catalog, and every published catalog keeps a tag)
# Without --push it is a dry run: it builds, checks, compares and prints the changes.
#
# Signing: the patch feed's key pair. Both artifacts carry the same trust (BRF-Tech/runr-runtimes
# says so), both secrets would live in this repository's Actions anyway, and RunR already pins
# keys/patch-feed.pub; RunR takes a separate catalog key (RUNR_RUNTIME_CATALOG_PUBLIC_KEY) should
# the catalog get its own pair later. CATALOG_SIGNING_KEY is the cosign key reference (default
# env://RUNR_PATCH_FEED_COSIGN_KEY), CATALOG_COSIGN_PASSWORD or RUNR_PATCH_FEED_COSIGN_PASSWORD its
# password, CATALOG_KEY the public key (default keys/patch-feed.pub).

CATALOG_TAG="${CATALOG_TAG:-stable}"
CATALOG_CANDIDATE_TAG="stable-candidate"
CATALOG_MEDIA_TYPE="application/vnd.runr.runtime-catalog.v1+json"
CATALOG_MAX_BYTES=$((8 * 1024 * 1024))
# the files of a dockerfile runtime land in a ConfigMap (RunR's SaveRuntimeRequest::MAX_FILES_BYTES)
CATALOG_FILES_MAX_BYTES=$((900 * 1024))

# catalog_repository — the catalog's repository (CATALOG_REPOSITORY replaces it)
catalog_repository() {
  echo "${CATALOG_REPOSITORY:-${REGISTRY}/runtime-catalog}"
}

# catalog_key — the public key of the catalog's signatures
catalog_key() {
  echo "${CATALOG_KEY:-${SCRIPT_DIR}/keys/patch-feed.pub}"
}

catalog_signing_key() {
  echo "${CATALOG_SIGNING_KEY:-env://RUNR_PATCH_FEED_COSIGN_KEY}"
}

# catalog_key_ready — the public key is one, not a placeholder
catalog_key_ready() {
  grep -q -- '-----BEGIN PUBLIC KEY-----' "$(catalog_key)" 2>/dev/null
}

# catalog_runtimes — the directory of the manifests (RUNTIMES_DIR replaces runtimes/)
catalog_runtimes() {
  echo "${RUNTIMES_DIR:-${SCRIPT_DIR}/runtimes}"
}

catalog_jq() {
  jq -L "${SCRIPT_DIR}/lib" "$@"
}

# catalog_tools MODE — validate: jq; build: also python3 with PyYAML; push: also oras, cosign, a
# JSON Schema validator, the public key and the signing key
catalog_tools() {
  local mode="$1" missing=() signing
  command -v jq >/dev/null 2>&1 || missing+=("jq (https://jqlang.org)")
  if [ "$mode" != validate ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      missing+=("python3")
    elif ! python3 -c 'import yaml' >/dev/null 2>&1; then
      missing+=("PyYAML (pip install pyyaml)")
    fi
  fi
  if [ "$mode" = push ]; then
    command -v oras >/dev/null 2>&1 || missing+=("oras (https://oras.land)")
    command -v cosign >/dev/null 2>&1 || missing+=("cosign (https://docs.sigstore.dev)")
    [ -n "$(feed_schema_validator)" ] || missing+=("check-jsonschema (pip install check-jsonschema)")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo -e "${RED}The runtime catalog needs: ${missing[*]}${NC}"
    return 1
  fi
  if [ "$mode" = push ]; then
    if ! catalog_key_ready; then
      echo -e "${RED}$(catalog_key) is not a public key: the catalog is signed with the patch feed's pair (PACKAGES.md)${NC}"
      return 1
    fi
    signing="$(catalog_signing_key)"
    if [[ "$signing" == env://* ]]; then
      local var="${signing#env://}"
      if [ -z "${!var:-}" ]; then
        echo -e "${RED}The signing key is not set: ${var} (the Actions secret RUNR_PATCH_FEED_COSIGN_KEY), or CATALOG_SIGNING_KEY=<cosign key file>${NC}"
        return 1
      fi
    fi
  fi
}

# catalog_revision — the commit the catalog is built from (CATALOG_REVISION, else the checkout's
# HEAD), 40 hex digits
catalog_revision() {
  local revision="${CATALOG_REVISION:-}"
  if [ -z "$revision" ]; then
    revision=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null) || revision=""
  fi
  if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo -e "${RED}No commit to name as the catalog's source.revision: build in a git checkout, or set CATALOG_REVISION${NC}" >&2
    return 1
  fi
  echo "$revision"
}

# catalog_dirty — the uncommitted changes of the runtimes' directory (git status --porcelain);
# nothing outside a git checkout
catalog_dirty() {
  git -C "$(catalog_runtimes)" status --porcelain -- . 2>/dev/null || true
}

# catalog_now — generated_at: the current time in UTC (CATALOG_NOW replaces it)
catalog_now() {
  echo "${CATALOG_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# catalog_build OUT — the catalog of runtimes/ into OUT (lib/catalog.py), not yet validated
catalog_build() {
  local out="$1" revision
  revision="$(catalog_revision)" || return 1
  if ! python3 "${SCRIPT_DIR}/lib/catalog.py" --runtimes "$(catalog_runtimes)" \
    --repository "${CATALOG_SOURCE:-${IMAGE_SOURCE}}" --revision "$revision" \
    --generated-at "$(catalog_now)" > "$out"; then
    echo -e "  ${RED}the catalog could not be built${NC}"
    return 1
  fi
}

# catalog_validate FILE — FILE is a valid catalog: at most 8 MiB, schema/runtime-catalog.v1.json,
# then the rules the schema cannot express (lib/catalog.jq catalog_problems). Exit 2 without a
# schema validator (the rules are still checked).
catalog_validate() {
  local file="$1" problems bytes schema_rc=0 rc=0
  if [ ! -f "$file" ]; then
    echo -e "  ${RED}${file}: no such file${NC}"
    return 1
  fi
  bytes=$(wc -c < "$file" | tr -d ' ')
  if [ "$bytes" -gt "$CATALOG_MAX_BYTES" ]; then
    echo -e "  ${RED}${file}: ${bytes} bytes (at most ${CATALOG_MAX_BYTES}, 8 MiB)${NC}"
    rc=1
  fi
  if ! problems=$(catalog_jq -r --argjson keep "${PATCH_KEEP:-5}" --argjson files_max "$CATALOG_FILES_MAX_BYTES" \
    'include "catalog"; catalog_problems($keep; $files_max)[]' "$file" 2>&1); then
    echo -e "  ${RED}${file}: not a catalog: ${problems}${NC}"
    return 1
  fi
  if [ -n "$problems" ]; then
    printf "  ${RED}%s${NC}\n" "$problems"
    rc=1
  fi
  json_schema_check "${SCRIPT_DIR}/schema/runtime-catalog.v1.json" "$file" || schema_rc=$?
  case "$schema_rc" in
    0) ;;
    2)
      echo -e "  ${YELLOW}no JSON Schema validator (pip install check-jsonschema): only the catalog's rules were checked${NC}"
      [ "$rc" = 0 ] && rc=2 ;;
    *) rc=1 ;;
  esac
  return "$rc"
}

# catalog_summary FILE — the catalog's runtimes, one per line, and its size
catalog_summary() {
  local file="$1"
  catalog_jq -r 'include "catalog"; "  \(.runtimes | length) runtimes, \(.patches // [] | length) patches, built from \(.source.repository) \(.source.revision[0:12]) at \(.generated_at)"' "$file"
  catalog_jq -r 'include "catalog"; catalog_summary | "    " + .' "$file"
  echo "  $(wc -c < "$file" | tr -d ' ') bytes"
}

# catalog_pull OUT — the current catalog into OUT; CATALOG_DIGEST: the digest of its manifest.
# Exit 3: no catalog (or not readable without credentials), 1: any other failure.
catalog_pull() {
  local out="$1" rc=0
  CATALOG_DIGEST=$(registry_artifact "$(catalog_repository)" "$CATALOG_TAG" "$CATALOG_MEDIA_TYPE" "$out") || rc=$?
  if [ "$rc" != 0 ]; then
    CATALOG_DIGEST=""
    return "$rc"
  fi
  if ! jq -e '.schema == 1' "$out" >/dev/null 2>&1; then
    echo -e "  ${RED}$(catalog_repository):${CATALOG_TAG} is not a schema 1 catalog${NC}" >&2
    return 1
  fi
}

# catalog_verify DIGEST — the catalog DIGEST is signed with the pair of the public key
catalog_verify() {
  local out
  if ! out=$(cosign verify --key "$(catalog_key)" --insecure-ignore-tlog=true "$(catalog_repository)@$1" 2>&1 >/dev/null); then
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  | /' >&2
    return 1
  fi
}

# catalog_version_tag FILE — the immutable tag of a catalog: <YYYYMMDDHHMM of generated_at>-<the
# first 12 hex digits of source.revision>
catalog_version_tag() {
  jq -r '"\(.generated_at | gsub("[^0-9]"; "") | .[0:12])-\(.source.revision[0:12])"' "$1"
}

# catalog_push FILE STARTED_EMPTY — publishes FILE as the catalog: pushed as stable-candidate,
# signed by digest, the signature verified with the public key, then tagged stable and its
# immutable tag. STARTED_EMPTY=1 (no catalog could be read before): a catalog that oras can read
# now is not replaced.
catalog_push() {
  local file="$1" started_empty="$2" repo dir digest tag rc=0
  repo="$(catalog_repository)"
  tag="$(catalog_version_tag "$file")"
  if [ "$started_empty" = 1 ] && oras manifest fetch --descriptor "${repo}:${CATALOG_TAG}" >/dev/null 2>&1; then
    echo -e "  ${RED}${repo}:${CATALOG_TAG} exists, but could not be read before: not replaced (GHCR_USERNAME and GHCR_TOKEN?)${NC}"
    return 1
  fi
  dir="$(mktemp -d)"
  cp -- "$file" "${dir}/runtime-catalog.json"
  echo "==> Pushing ${repo}:${CATALOG_CANDIDATE_TAG}"
  (cd "$dir" && oras push "${repo}:${CATALOG_CANDIDATE_TAG}" \
    --artifact-type "$CATALOG_MEDIA_TYPE" \
    --annotation "org.opencontainers.image.source=${IMAGE_SOURCE}" \
    --annotation "org.opencontainers.image.description=RunR runtime catalog (schema 1)" \
    --annotation "org.opencontainers.image.created=$(jq -r .generated_at runtime-catalog.json)" \
    --annotation "org.opencontainers.image.revision=$(jq -r .source.revision runtime-catalog.json)" \
    "runtime-catalog.json:${CATALOG_MEDIA_TYPE}") || rc=1
  rm -f -- "${dir}/runtime-catalog.json"
  rmdir -- "$dir"
  [ "$rc" = 0 ] || return 1

  digest=$(oras manifest fetch --descriptor "${repo}:${CATALOG_CANDIDATE_TAG}" | jq -r '.digest // empty') || digest=""
  if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo -e "  ${RED}cannot resolve ${repo}:${CATALOG_CANDIDATE_TAG}${NC}"
    return 1
  fi
  echo "==> Signing ${repo}@${digest}"
  COSIGN_PASSWORD="${CATALOG_COSIGN_PASSWORD:-${RUNR_PATCH_FEED_COSIGN_PASSWORD:-${COSIGN_PASSWORD:-}}}" \
    cosign sign --yes --tlog-upload=false --key "$(catalog_signing_key)" "${repo}@${digest}" || return 1
  if ! catalog_verify "$digest"; then
    echo -e "  ${RED}the signature does not verify with $(catalog_key): the signing key is not its pair; ${repo}:${CATALOG_TAG} not moved${NC}"
    return 1
  fi
  oras tag "${repo}@${digest}" "$CATALOG_TAG" "$tag" || return 1
  CATALOG_DIGEST="$digest"
  echo -e "  ${GREEN}✓ ${repo}:${CATALOG_TAG} and :${tag} → ${digest} (signed)${NC}"
}

# catalog_cleanup DIR — removes a work directory of catalog_publish (its files, then itself)
catalog_cleanup() {
  rm -f -- "${1:?}"/*.json
  rmdir -- "$1" 2>/dev/null || true
}

# catalog_publish PUSH OUT — the catalog of runtimes/, compared with the current stable and
# published when its runtimes or patches changed (see the top of this file); OUT receives the new
# catalog (or empty). A dry run without PUSH=1.
catalog_publish() {
  local push="$1" out="$2" work rc=0 started_empty=0 validator_rc=0 dirty changes
  if [ "$push" = 1 ]; then catalog_tools push || return 1; else catalog_tools build || return 1; fi
  work="$(mktemp -d)"

  echo -e "${BOLD}── Runtime catalog: $(catalog_repository):${CATALOG_TAG} ──${NC}"
  catalog_build "${work}/next.json" || { catalog_cleanup "$work"; return 1; }
  catalog_validate "${work}/next.json" || validator_rc=$?
  if [ "$validator_rc" = 1 ] || { [ "$validator_rc" = 2 ] && [ "$push" = 1 ]; }; then
    echo -e "  ${RED}the catalog is not valid: not published${NC}"
    catalog_cleanup "$work"
    return 1
  fi
  catalog_summary "${work}/next.json"
  [ -z "$out" ] || cp -- "${work}/next.json" "$out"
  dirty="$(catalog_dirty)"
  if [ -n "$dirty" ]; then
    if [ "$push" = 1 ]; then
      echo -e "  ${RED}$(catalog_runtimes) has uncommitted changes: a published catalog names the commit it was built from; commit them first${NC}"
      printf '%s\n' "$dirty" | sed 's/^/    /'
      catalog_cleanup "$work"
      return 1
    fi
    echo -e "  ${YELLOW}$(catalog_runtimes) has uncommitted changes: source.revision does not name them${NC}"
  fi

  catalog_pull "${work}/current.json" || rc=$?
  case "$rc" in
    0)
      echo "  current: ${CATALOG_DIGEST} ($(jq -r '"generated \(.generated_at) from \(.source.revision[0:12] // "?"), \(.runtimes | length) runtimes"' "${work}/current.json"))"
      if command -v cosign >/dev/null 2>&1 && catalog_key_ready; then
        if catalog_verify "$CATALOG_DIGEST"; then
          echo "  signature verified ($(catalog_key))"
        elif [ -n "${CATALOG_PREVIOUS_KEY:-}" ] && CATALOG_KEY="$CATALOG_PREVIOUS_KEY" catalog_verify "$CATALOG_DIGEST"; then
          # a key rotation: the current catalog is signed with the previous key (PACKAGES.md)
          echo "  signature verified with the previous key (${CATALOG_PREVIOUS_KEY})"
        else
          echo -e "  ${RED}the current catalog's signature does not verify with $(catalog_key): not published${NC}"
          catalog_cleanup "$work"
          return 1
        fi
      elif [ "$push" = 1 ]; then
        catalog_cleanup "$work"
        return 1
      else
        echo -e "  ${YELLOW}signature not verified (needs cosign and the public key)${NC}"
      fi ;;
    3)
      echo "  no catalog published yet (or not readable without GHCR_USERNAME and GHCR_TOKEN): this is the first one"
      echo '{"runtimes": [], "patches": []}' > "${work}/current.json"
      started_empty=1 ;;
    *)
      echo -e "  ${RED}cannot read the current catalog: not published${NC}"
      catalog_cleanup "$work"
      return 1 ;;
  esac

  if [ "$started_empty" = 0 ] \
    && [ "$(catalog_jq -cS 'include "catalog"; catalog_content' "${work}/current.json")" \
       = "$(catalog_jq -cS 'include "catalog"; catalog_content' "${work}/next.json")" ]; then
    echo "  the catalog is up to date: nothing to publish"
    catalog_cleanup "$work"
    return 0
  fi
  changes=$(catalog_jq -r --slurpfile old "${work}/current.json" 'include "catalog"; catalog_changes($old[0])[]' "${work}/next.json")
  echo "  changes:"
  printf '%s\n' "${changes:-  ~ the order of the runtimes}"
  if [ "$push" = 1 ]; then
    catalog_push "${work}/next.json" "$started_empty" || { catalog_cleanup "$work"; return 1; }
  else
    echo -e "  ${YELLOW}dry run: not published (--push publishes it as ${CATALOG_TAG} and $(catalog_version_tag "${work}/next.json"))${NC}"
  fi
  catalog_cleanup "$work"
}

# cmd_catalog — the runtime catalog: build, validate, publish (ci.sh help)
cmd_catalog() {
  local sub="${1:-}" push=0 out="" file rc=0 work validator_rc=0 fd=1
  shift || true
  case "$sub" in
    validate)
      [ "$#" -gt 0 ] || { echo -e "${RED}ci.sh catalog validate FILE...${NC}"; return 1; }
      catalog_tools validate || return 1
      for file in "$@"; do
        if catalog_validate "$file"; then echo -e "${GREEN}✓ ${file}${NC}"; else rc=1; fi
      done
      return "$rc" ;;
    build|publish) ;;
    *) echo -e "${RED}ci.sh catalog build|validate|publish (ci.sh help)${NC}"; return 1 ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$sub $1" in
      "publish --push") push=1; shift ;;
      "build --out"|"publish --out")
        [ "$#" -ge 2 ] || { echo -e "${RED}$1 needs a file${NC}"; return 1; }
        out="$2"; shift 2 ;;
      *) echo -e "${RED}unknown argument: $1 (ci.sh help)${NC}"; return 1 ;;
    esac
  done

  if [ "$sub" = publish ]; then
    catalog_publish "$push" "$out"
    return
  fi

  # build: the catalog, checked, its summary; --out - writes the catalog to stdout, the rest to stderr
  catalog_tools build || return 1
  work="$(mktemp -d)"
  [ "$out" != - ] || fd=2
  {
    echo -e "${BOLD}── Runtime catalog of $(catalog_runtimes) ──${NC}"
    if catalog_build "${work}/catalog.json"; then
      catalog_validate "${work}/catalog.json" || validator_rc=$?
      [ "$validator_rc" != 1 ] || rc=1
      catalog_summary "${work}/catalog.json"
      [ -z "$(catalog_dirty)" ] || echo -e "  ${YELLOW}$(catalog_runtimes) has uncommitted changes: source.revision does not name them${NC}"
    else
      rc=1
    fi
  } >&"$fd"
  if [ "$rc" = 0 ] && [ -n "$out" ]; then
    if [ "$out" = - ]; then cat -- "${work}/catalog.json"; else cp -- "${work}/catalog.json" "$out"; fi
  fi
  catalog_cleanup "$work"
  return "$rc"
}
