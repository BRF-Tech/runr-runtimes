# ── The patch feed ──
# This file is sourced, so it has no shebang.
#
# One JSON document (schema/patch-feed.v1.json) tells every RunR instance which patches of the
# runtime images exist (lib/patch.sh) and which RunR platform releases carry a level. It is an OCI
# artifact, ${REGISTRY}/runtime-patches:feed: one layer of application/vnd.runr.patch-feed.v1+json,
# signed with cosign (the key pair of keys/patch-feed.pub; the signature is the classic
# sha256-<digest>.sig of the feed's manifest, without a transparency log entry).
#
# Every update (ci.sh feed update, feed platform, patch) is a new version of the previous feed:
#   1. the current feed is pulled and its signature verified (none: an empty one)
#   2. what the registry has and the feed lacks is added: the newest patch tags of every
#      exec-<runtime>:<major.minor>, from their sh.runr.patch.* annotations (a publish whose feed
#      update did not run). The results of this run's builds (--results) add their patches and
#      promote an unchanged image's patch to the level of a patch request.
#   3. per floating tag the newest PATCH_KEEP (5) patches, newest first; the newest 10 platform
#      releases
#   4. checked against schema/patch-feed.v1.json and the rules the schema cannot express
#   5. --push: pushed as feed-candidate, signed by digest, the signature verified with
#      keys/patch-feed.pub, then tagged feed (so feed only ever names a signed feed)
#   6. retention: patch tags beyond the newest PATCH_KEEP of their floating tag, and not in the
#      feed, are deleted from the registry (--push), never a floating tag
# Without --push it is a dry run: it prints the changes and what retention would delete.
#
# Signing: PATCH_FEED_SIGNING_KEY is the cosign key reference (default
# env://RUNR_PATCH_FEED_COSIGN_KEY: the private key in that variable), RUNR_PATCH_FEED_COSIGN_PASSWORD
# its password.

PATCH_FEED_TAG="${PATCH_FEED_TAG:-feed}"
PATCH_FEED_CANDIDATE_TAG="feed-candidate"
PATCH_FEED_MEDIA_TYPE="application/vnd.runr.patch-feed.v1+json"
PATCH_FEED_PLATFORM_KEEP=10

# feed_repository — the feed's repository (PATCH_FEED_REPOSITORY replaces it)
feed_repository() {
  echo "${PATCH_FEED_REPOSITORY:-${REGISTRY}/runtime-patches}"
}

# feed_key — the public key of the feed's signatures
feed_key() {
  echo "${PATCH_FEED_KEY:-${SCRIPT_DIR}/keys/patch-feed.pub}"
}

feed_signing_key() {
  echo "${PATCH_FEED_SIGNING_KEY:-env://RUNR_PATCH_FEED_COSIGN_KEY}"
}

# feed_key_ready — keys/patch-feed.pub is a public key, not the placeholder
feed_key_ready() {
  grep -q -- '-----BEGIN PUBLIC KEY-----' "$(feed_key)" 2>/dev/null
}

# feed_schema_validator — the JSON Schema validator found: check-jsonschema, or python3 with the
# jsonschema module; nothing without one
feed_schema_validator() {
  if command -v check-jsonschema >/dev/null 2>&1; then
    echo check-jsonschema
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    echo python3
  fi
}

# feed_tools PUSH — jq; a schema validator; with PUSH=1 also oras, cosign, the public key and the
# signing key
feed_tools() {
  local push="$1" missing=() signing
  command -v jq >/dev/null 2>&1 || missing+=("jq (https://jqlang.org)")
  if [ "$push" = 1 ]; then
    command -v oras >/dev/null 2>&1 || missing+=("oras (https://oras.land)")
    command -v cosign >/dev/null 2>&1 || missing+=("cosign (https://docs.sigstore.dev)")
    [ -n "$(feed_schema_validator)" ] || missing+=("check-jsonschema (pip install check-jsonschema)")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo -e "${RED}The patch feed needs: ${missing[*]}${NC}"
    return 1
  fi
  if [ "$push" = 1 ]; then
    if ! feed_key_ready; then
      echo -e "${RED}$(feed_key) is not a public key (the placeholder?): the owner generates the feed's key pair first (PACKAGES.md)${NC}"
      return 1
    fi
    signing="$(feed_signing_key)"
    if [[ "$signing" == env://* ]]; then
      local var="${signing#env://}"
      if [ -z "${!var:-}" ]; then
        echo -e "${RED}The signing key is not set: ${var} (the Actions secret RUNR_PATCH_FEED_COSIGN_KEY), or PATCH_FEED_SIGNING_KEY=<cosign key file>${NC}"
        return 1
      fi
    fi
  fi
}

# feed_validate FILE — FILE is a valid feed: schema/patch-feed.v1.json, then the rules the schema
# cannot express (lib/feed.jq feed_problems). Exit 2 without a schema validator (the rules are
# still checked).
feed_validate() {
  local file="$1" problems validator rc=0
  if ! problems=$(patch_jq -r --argjson keep "$PATCH_KEEP" --argjson pkeep "$PATCH_FEED_PLATFORM_KEEP" \
    'include "feed"; feed_problems($keep; $pkeep)[]' "$file" 2>&1); then
    echo -e "  ${RED}${file}: not a feed: ${problems}${NC}"
    return 1
  fi
  if [ -n "$problems" ]; then
    printf "  ${RED}%s${NC}\n" "$problems"
    rc=1
  fi
  validator="$(feed_schema_validator)"
  case "$validator" in
    check-jsonschema)
      check-jsonschema --schemafile "${SCRIPT_DIR}/schema/patch-feed.v1.json" "$file" || rc=1 ;;
    python3)
      python3 - "${SCRIPT_DIR}/schema/patch-feed.v1.json" "$file" <<'PY' || rc=1
import json
import sys

import jsonschema

schema = json.load(open(sys.argv[1], encoding="utf-8"))
document = json.load(open(sys.argv[2], encoding="utf-8"))
validator = jsonschema.validators.validator_for(schema)
validator.check_schema(schema)
errors = sorted(validator(schema, format_checker=jsonschema.FormatChecker()).iter_errors(document),
                key=lambda e: [str(p) for p in e.path])
for error in errors:
    print("  %s: %s" % ("/".join(str(p) for p in error.path) or "(root)", error.message))
sys.exit(1 if errors else 0)
PY
      ;;
    *)
      echo -e "  ${YELLOW}no JSON Schema validator (pip install check-jsonschema): only the feed's rules were checked${NC}"
      [ "$rc" = 0 ] && rc=2 ;;
  esac
  return "$rc"
}

# feed_pull OUT — the current feed into OUT; FEED_DIGEST: the digest of its manifest. Exit 3: no
# feed (or not readable without credentials: GHCR answers the same for a missing and a private
# package), 1: any other failure.
feed_pull() {
  local out="$1" manifest rc=0 layer
  manifest=$(mktemp)
  FEED_DIGEST=$(registry_manifest "$(feed_repository):${PATCH_FEED_TAG}" "$manifest") || rc=$?
  case "$rc" in
    0) ;;
    3|4) rm -f -- "$manifest"; FEED_DIGEST=""; return 3 ;;
    *) rm -f -- "$manifest"; FEED_DIGEST=""; return 1 ;;
  esac
  layer=$(jq -r --arg mt "$PATCH_FEED_MEDIA_TYPE" \
    '[.layers[]? | select(.mediaType == $mt)] | if length == 1 then .[0].digest else empty end' "$manifest" 2>/dev/null || true)
  rm -f -- "$manifest"
  if [ -z "$layer" ]; then
    echo -e "  ${RED}$(feed_repository):${PATCH_FEED_TAG} is not a patch feed (no single ${PATCH_FEED_MEDIA_TYPE} layer)${NC}" >&2
    return 1
  fi
  registry_blob "$(feed_repository)" "$layer" "$out" || return 1
  if ! jq -e '.schema == 1' "$out" >/dev/null 2>&1; then
    echo -e "  ${RED}$(feed_repository):${PATCH_FEED_TAG} is not a schema 1 feed${NC}" >&2
    return 1
  fi
}

# feed_verify DIGEST — the feed DIGEST is signed with the pair of keys/patch-feed.pub
feed_verify() {
  local out
  if ! out=$(cosign verify --key "$(feed_key)" --insecure-ignore-tlog=true "$(feed_repository)@$1" 2>&1 >/dev/null); then
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  | /' >&2
    return 1
  fi
}

# feed_push FILE STARTED_EMPTY — publishes FILE as the feed: pushed as feed-candidate, signed by
# digest, the signature verified with keys/patch-feed.pub, then tagged feed. STARTED_EMPTY=1 (no
# feed could be read before): a feed that oras can read now is not replaced.
feed_push() {
  local file="$1" started_empty="$2" repo dir digest rc=0
  repo="$(feed_repository)"
  if [ "$started_empty" = 1 ] && oras manifest fetch --descriptor "${repo}:${PATCH_FEED_TAG}" >/dev/null 2>&1; then
    echo -e "  ${RED}${repo}:${PATCH_FEED_TAG} exists, but could not be read before: not replaced (GHCR_USERNAME and GHCR_TOKEN?)${NC}"
    return 1
  fi
  dir="$(mktemp -d)"
  cp -- "$file" "${dir}/patch-feed.json"
  echo "==> Pushing ${repo}:${PATCH_FEED_CANDIDATE_TAG}"
  (cd "$dir" && oras push "${repo}:${PATCH_FEED_CANDIDATE_TAG}" \
    --artifact-type "$PATCH_FEED_MEDIA_TYPE" \
    --annotation "org.opencontainers.image.source=${IMAGE_SOURCE}" \
    --annotation "org.opencontainers.image.description=RunR runtime patch feed (schema 1)" \
    --annotation "org.opencontainers.image.created=$(jq -r .generated_at patch-feed.json)" \
    "patch-feed.json:${PATCH_FEED_MEDIA_TYPE}") || rc=1
  rm -f -- "${dir}/patch-feed.json"
  rmdir -- "$dir"
  [ "$rc" = 0 ] || return 1

  digest=$(oras manifest fetch --descriptor "${repo}:${PATCH_FEED_CANDIDATE_TAG}" | jq -r '.digest // empty') || digest=""
  if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo -e "  ${RED}cannot resolve ${repo}:${PATCH_FEED_CANDIDATE_TAG}${NC}"
    return 1
  fi
  echo "==> Signing ${repo}@${digest}"
  COSIGN_PASSWORD="${RUNR_PATCH_FEED_COSIGN_PASSWORD:-${COSIGN_PASSWORD:-}}" \
    cosign sign --yes --tlog-upload=false --key "$(feed_signing_key)" "${repo}@${digest}" || return 1
  if ! feed_verify "$digest"; then
    echo -e "  ${RED}the signature does not verify with $(feed_key): the signing key is not its pair; ${repo}:${PATCH_FEED_TAG} not moved${NC}"
    return 1
  fi
  oras tag "${repo}@${digest}" "$PATCH_FEED_TAG" || return 1
  FEED_DIGEST="$digest"
  echo -e "  ${GREEN}✓ ${repo}:${PATCH_FEED_TAG} → ${digest} (signed)${NC}"
}

# feed_tags_json TAGS — the tags (one per line) as a JSON array
feed_tags_json() {
  jq -Rnc '[inputs | select(length > 0)]' <<< "$1"
}

# feed_registry_entries FEED RUNTIME — the feed entries (one per line) of the newest patch tags of
# ${REGISTRY}/exec-RUNTIME that FEED does not list, from their annotations
feed_registry_entries() {
  local feed="$1" runtime="$2" repo tags tag manifest digest entry
  repo="${REGISTRY}/exec-${runtime}"
  tags=$(registry_tags_checked "$repo") || return 1
  manifest=$(mktemp)
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if ! digest=$(registry_manifest "${repo}:${tag}" "$manifest"); then
      echo -e "  ${RED}cannot read ${repo}:${tag}${NC}" >&2
      rm -f -- "$manifest"
      return 1
    fi
    entry=$(patch_jq -c --arg image "$repo" --arg digest "$digest" \
      'include "feed"; entry_from_annotations($image; $digest)' "$manifest" 2>/dev/null || true)
    if [ -n "$entry" ]; then
      echo "$entry"
    else
      echo -e "  ${YELLOW}${repo}:${tag} has no patch annotations: left out of the feed${NC}" >&2
    fi
  done < <(patch_jq -r --argjson tags "$(feed_tags_json "$tags")" --arg runtime "$runtime" --argjson keep "$PATCH_KEEP" \
    'include "feed"; unlisted_patch_tags($tags; $runtime; $keep)[]' "$feed")
  rm -f -- "$manifest"
}

# feed_prune PUSH FEED — retention: the patch tags of every language runtime beyond the newest
# PATCH_KEEP of their floating tag and not in FEED; deleted with PUSH=1 (GitHub Packages API),
# listed otherwise
feed_prune() {
  local push="$1" feed="$2" runtime repo tags expired=() rc=0 api=0
  for runtime in $PATCH_LANGUAGE_RUNTIMES; do
    repo="exec-${runtime}"
    if ! tags=$(registry_tags_checked "${REGISTRY}/${repo}"); then
      rc=1
      continue
    fi
    mapfile -t expired < <(patch_jq -r --argjson tags "$(feed_tags_json "$tags")" --arg runtime "$runtime" \
      --argjson keep "$PATCH_KEEP" 'include "feed"; retention($tags; $runtime; $keep)[]' "$feed")
    [ "${#expired[@]}" -gt 0 ] || continue
    if [ "$push" != 1 ]; then
      echo -e "  ${YELLOW}dry run: retention would delete ${REGISTRY}/${repo}: ${expired[*]}${NC}"
      continue
    fi
    echo "Retention (the newest ${PATCH_KEEP} patches of each version): ${REGISTRY}/${repo}"
    if [ "$api" = 0 ]; then
      ghcr_api || return 1
      api=1
    fi
    ghcr_delete_tags "$repo" "${expired[@]}" || rc=1
  done
  return "$rc"
}

# feed_cleanup DIR — removes a work directory of feed_update (its files, then itself)
feed_cleanup() {
  rm -f -- "${1:?}"/*.json "${1:?}"/*.jsonl
  rmdir -- "$1" 2>/dev/null || true
}

# feed_update PUSH PLATFORM OUT [--results FILE]... — the next feed (see the top of this file):
# PLATFORM a platform release entry to add (JSON, or empty), OUT a file that receives the next feed
# (or empty), the results of patch builds (patch_publish_image's PATCH_RESULTS). PUSH=1 publishes it
# and applies retention; a dry run otherwise.
feed_update() {
  local push="$1" platform="$2" out="$3" results=() work rc=0 started_empty=0 runtime now validator_rc=0
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --results) [ -n "${2:-}" ] && results+=("$2"); shift 2 ;;
      *) echo -e "${RED}feed_update: unknown argument $1${NC}"; return 1 ;;
    esac
  done
  feed_tools "$push" || return 1
  work="$(mktemp -d)"
  now="$(patch_now)"

  echo -e "${BOLD}── Patch feed: $(feed_repository):${PATCH_FEED_TAG} ──${NC}"
  feed_pull "${work}/current.json" || rc=$?
  case "$rc" in
    0)
      echo "  current: ${FEED_DIGEST} ($(jq -r '"generated \(.generated_at), \(.patches | length) patches, \(.platform | length) platform releases"' "${work}/current.json"))"
      if command -v cosign >/dev/null 2>&1 && feed_key_ready; then
        if feed_verify "$FEED_DIGEST"; then
          echo "  signature verified ($(feed_key))"
        elif [ -n "${PATCH_FEED_PREVIOUS_KEY:-}" ] && PATCH_FEED_KEY="$PATCH_FEED_PREVIOUS_KEY" feed_verify "$FEED_DIGEST"; then
          # a key rotation: the current feed is signed with the previous key (PACKAGES.md)
          echo "  signature verified with the previous key (${PATCH_FEED_PREVIOUS_KEY})"
        else
          echo -e "  ${RED}the current feed's signature does not verify with $(feed_key): not updated${NC}"
          feed_cleanup "$work"
          return 1
        fi
      elif [ "$push" = 1 ]; then
        feed_cleanup "$work"
        return 1
      else
        echo -e "  ${YELLOW}signature not verified (needs cosign and the public key)${NC}"
      fi ;;
    3)
      echo "  no feed published yet (or not readable without GHCR_USERNAME and GHCR_TOKEN): starting an empty one"
      echo '{}' > "${work}/current.json"
      started_empty=1 ;;
    *)
      echo -e "  ${RED}cannot read the current feed: not updated${NC}"
      feed_cleanup "$work"
      return 1 ;;
  esac

  # the results of this run's builds
  if [ "${#results[@]}" -gt 0 ]; then
    cat -- "${results[@]}" | jq -sc '.' > "${work}/results.json" || { feed_cleanup "$work"; return 1; }
  else
    echo '[]' > "${work}/results.json"
  fi
  # the patches the registry has and the feed lacks
  : > "${work}/found.jsonl"
  for runtime in $PATCH_LANGUAGE_RUNTIMES; do
    if ! feed_registry_entries "${work}/current.json" "$runtime" >> "${work}/found.jsonl"; then
      echo -e "  ${RED}cannot read the patches of exec-${runtime}: not updated${NC}"
      feed_cleanup "$work"
      return 1
    fi
  done
  jq -sc '.' "${work}/found.jsonl" > "${work}/found.json"
  if [ -n "$platform" ]; then
    jq -c '[.]' <<< "$platform" > "${work}/platform.json"
  else
    echo '[]' > "${work}/platform.json"
  fi

  patch_jq -n \
    --slurpfile cur "${work}/current.json" \
    --slurpfile results "${work}/results.json" \
    --slurpfile found "${work}/found.json" \
    --slurpfile platform "${work}/platform.json" \
    --arg now "$now" --argjson keep "$PATCH_KEEP" --argjson pkeep "$PATCH_FEED_PLATFORM_KEEP" \
    'include "feed"; $cur[0] | feed_merge($results[0]; $found[0]; $platform[0]; $now; $keep; $pkeep)' \
    > "${work}/next.json" || { feed_cleanup "$work"; return 1; }

  feed_validate "${work}/next.json" || validator_rc=$?
  if [ "$validator_rc" = 1 ] || { [ "$validator_rc" = 2 ] && [ "$push" = 1 ]; }; then
    echo -e "  ${RED}the next feed is not valid: not published${NC}"
    feed_cleanup "$work"
    return 1
  fi
  if [ -n "$out" ]; then
    cp -- "${work}/next.json" "$out"
  fi

  local changes
  changes=$(patch_jq -r --slurpfile old "${work}/current.json" 'include "feed"; feed_changes($old[0])[]' "${work}/next.json")
  if [ "$started_empty" = 0 ] && [ -z "$changes" ] \
    && [ "$(jq -cS 'del(.generated_at)' "${work}/current.json")" = "$(jq -cS 'del(.generated_at)' "${work}/next.json")" ]; then
    echo "  the feed is up to date: nothing to publish"
  else
    echo "  changes:"
    printf '%s\n' "${changes:-  (none, a new feed)}"
    if [ "$push" = 1 ]; then
      feed_push "${work}/next.json" "$started_empty" || { feed_cleanup "$work"; return 1; }
    else
      echo -e "  ${YELLOW}dry run: the feed is not published (--push publishes it)${NC}"
    fi
  fi

  rc=0
  feed_prune "$push" "${work}/next.json" || rc=1
  feed_cleanup "$work"
  return "$rc"
}

# feed_show [--verify] — the current feed on stdout (its reference and digest on stderr);
# --verify checks its signature first
feed_show() {
  local verify=0 arg file rc=0
  for arg in "$@"; do
    case "$arg" in
      --verify) verify=1 ;;
      *) echo -e "${RED}unknown argument: ${arg} (--verify)${NC}"; return 1 ;;
    esac
  done
  feed_tools 0 || return 1
  file="$(mktemp)"
  feed_pull "$file" || rc=$?
  if [ "$rc" = 3 ]; then
    echo "No patch feed at $(feed_repository):${PATCH_FEED_TAG} (not published yet, or private: GHCR_USERNAME and GHCR_TOKEN)" >&2
  fi
  if [ "$rc" != 0 ]; then
    rm -f -- "$file"
    return 1
  fi
  echo "# $(feed_repository):${PATCH_FEED_TAG} ${FEED_DIGEST}" >&2
  if [ "$verify" = 1 ]; then
    if ! command -v cosign >/dev/null 2>&1 || ! feed_key_ready; then
      echo -e "${RED}--verify needs cosign and the public key ($(feed_key))${NC}" >&2
      rm -f -- "$file"
      return 1
    fi
    if ! feed_verify "$FEED_DIGEST"; then
      echo -e "${RED}the signature does not verify with $(feed_key)${NC}" >&2
      rm -f -- "$file"
      return 1
    fi
    echo "# signature verified with $(feed_key)" >&2
  fi
  jq . "$file"
  rm -f -- "$file"
}

# feed_platform_entry VERSION LEVEL REASON_EN REASON_TR URL — a platform release entry (JSON),
# checked: a release version, the level, a reason in both languages, an https URL
feed_platform_entry() {
  local version="$1" level="$2" en tr url problems=()
  en="$(patch_one_line "$3")"
  tr="$(patch_one_line "$4")"
  url="$(patch_one_line "$5")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || problems+=("version: '${version}' is not a RunR release (0.5.11)")
  patch_level_valid "$level" || problems+=("level: '${level}' (routine, security, critical, zero-day)")
  [ -n "$en" ] && [ "${#en}" -le 300 ] || problems+=("reason (en): required, at most 300 characters")
  [ -n "$tr" ] && [ "${#tr}" -le 300 ] || problems+=("reason (tr): required, at most 300 characters")
  if [ -n "$url" ] && ! [[ "$url" =~ ^https://[^[:space:]]+$ ]]; then
    problems+=("url: '${url}' is not an https:// URL")
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    printf "${RED}  %s${NC}\n" "${problems[@]}" >&2
    return 1
  fi
  patch_jq -cn --arg version "$version" --arg level "$level" --arg en "$en" --arg tr "$tr" --arg url "$url" \
    --arg published "$(patch_now)" \
    'include "feed"; {version: $version, level: $level, reason: {en: $en, tr: $tr}, url: $url, published_at: $published} | normalize_platform'
}

# cmd_feed — the patch feed: show, update, platform, validate (ci.sh help)
cmd_feed() {
  local sub="${1:-}" push=0 out="" results=() version="${PLATFORM_VERSION:-}" level="${PLATFORM_LEVEL:-}"
  local en="${PLATFORM_REASON_EN:-}" tr="${PLATFORM_REASON_TR:-}" url="${PLATFORM_URL:-}" entry file rc=0
  shift || true
  case "$sub" in
    show) feed_show "$@"; return ;;
    validate)
      [ "$#" -gt 0 ] || { echo -e "${RED}ci.sh feed validate FILE...${NC}"; return 1; }
      feed_tools 0 || return 1
      for file in "$@"; do
        if feed_validate "$file"; then echo -e "${GREEN}✓ ${file}${NC}"; else rc=1; fi
      done
      return "$rc" ;;
    update|platform) ;;
    *) echo -e "${RED}ci.sh feed show|update|platform|validate (ci.sh help)${NC}"; return 1 ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --push) push=1; shift; continue ;;
    esac
    [ "$#" -ge 2 ] || { echo -e "${RED}unknown argument or missing value: $1 (ci.sh help)${NC}"; return 1; }
    case "$sub $1" in
      "update --results") results+=(--results "$2") ;;
      "update --out"|"platform --out") out="$2" ;;
      "platform --version") version="$2" ;;
      "platform --level") level="$2" ;;
      "platform --reason-en") en="$2" ;;
      "platform --reason-tr") tr="$2" ;;
      "platform --url") url="$2" ;;
      *) echo -e "${RED}unknown argument: $1 (ci.sh help)${NC}"; return 1 ;;
    esac
    shift 2
  done

  patch_tools || return 1
  if [ "$sub" = platform ]; then
    entry="$(feed_platform_entry "$version" "$level" "$en" "$tr" "$url")" || return 1
    echo "Platform release: ${entry}"
    feed_update "$push" "$entry" "$out"
  else
    feed_update "$push" "" "$out" ${results[@]+"${results[@]}"}
  fi
}
