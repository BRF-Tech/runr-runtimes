# ── Patches of the runtime images ──
# This file is sourced, so it has no shebang.
#
# Every published build of a language runtime (exec-<runtime>:<major.minor>) is a patch: the
# floating tag moves to it, and it also gets an immutable tag <full upstream version>-r<n>
# (8.3.36-r1, 22.11.0-r1, 3.12.7-r2). n counts the builds of one upstream version that published a
# different image (base image, OS packages, our sources, the packages the Dockerfile installs). A
# build that is the image already published publishes nothing.
#
# "The same image": the builds are reproducible. Every patch build runs with SOURCE_DATE_EPOCH (the
# time of the last commit of the image's directory) and rewrite-timestamp=true, so the same
# sources on the same base give the same image digests. The image is first built without pushing
# (multi-arch, no patch annotations); the digest of that image index is its build digest. The
# published index carries it as sh.runr.patch.build: when a new build has the build digest of the
# floating tag's patch, nothing is published. Otherwise the same build (from the builder's cache)
# is pushed with the patch annotations, tagged <major.minor> and <full>-r<n>.
#
# The patch annotations (sh.runr.patch.*, on the image index; the image manifests stay as built):
#   id runtime version tag level reason.en reason.tr cves url upstream published_at deadline_at
#   build (the build digest) base (the base image and its digest)
# The feed entry of a patch (lib/feed.sh) has the same fields, with the index digest.
#
# Levels: routine | security | critical | zero-day. critical and zero-day patches have a deadline
# (default 72 hours for zero-day, 168 for critical). A routine patch without a reason gets one from
# what changed: "Upstream <runtime> <version>", "Base image refresh" or "Runtime update".
#
# A request above routine whose build is unchanged publishes nothing either: upstream may not have
# the fix yet, or an earlier build already has it, which only a person can tell. The image's
# current patch takes the request's level, reason, CVEs and deadline in the feed only when the
# request says so (PATCH_REQ_PROMOTE=1: --promote-unchanged, the patch workflow's
# promote_unchanged); otherwise it is reported.
#
# Other images adopt patches by calling patch_publish_image from their push with an upstream full
# version (README.md: "Other images").

PATCH_KEEP="${PATCH_KEEP:-5}"
PATCH_LANGUAGE_RUNTIMES="python nodejs go php"

# The request of the patches being built (patch_request_reset / cmd_patch, patch_request_check)
PATCH_REQ_LEVEL=""
PATCH_REQ_REASON_EN=""
PATCH_REQ_REASON_TR=""
PATCH_REQ_CVES=""
PATCH_REQ_URL=""
PATCH_REQ_DEADLINE_HOURS=""
PATCH_REQ_DEADLINE_AT=""
PATCH_REQ_PROMOTE=0

# patch_tools — the tools a patch push needs besides Docker: jq
patch_tools() {
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}patches need jq (https://jqlang.org)${NC}"
    return 1
  fi
}

# patch_warning MESSAGE — a warning; a workflow annotation in GitHub Actions
patch_warning() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::warning::$1"
  else
    echo -e "  ${YELLOW}warning: $1${NC}"
  fi
}

# patch_jq ARG... — jq with the functions of lib/feed.jq ('include "feed"; …')
patch_jq() {
  jq -L "${SCRIPT_DIR}/lib" "$@"
}

# patch_now — the current time in UTC (PATCH_NOW replaces it)
patch_now() {
  echo "${PATCH_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# patch_time_valid TIME — YYYY-MM-DDTHH:MM:SSZ
patch_time_valid() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# patch_time_plus TIME HOURS — TIME plus HOURS, in the same form (GNU or BSD date)
patch_time_plus() {
  local epoch
  epoch=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || return 1
  epoch=$((epoch + $2 * 3600))
  date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

patch_level_valid() {
  case "$1" in
    routine|security|critical|zero-day) return 0 ;;
  esac
  return 1
}

# patch_full_version_valid VERSION FULL — FULL is a release of VERSION (major.minor): 8.3.36 of
# 8.3, 3.15.0rc1 of 3.15
patch_full_version_valid() {
  [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-z]+[0-9]*)?$ ]] && [[ "$2" == "$1."* ]]
}

# patch_next_tag FULL [TAG...] — <FULL>-r<n>: one more than the highest n of FULL among the TAGs
# (the tags of the image), r1 when there is none
patch_next_tag() {
  local full="$1" tag n max=0
  shift
  for tag in "$@"; do
    [[ "$tag" == "${full}-r"* ]] || continue
    n="${tag#"${full}-r"}"
    [[ "$n" =~ ^[1-9][0-9]{0,8}$ ]] || continue
    if (( n > max )); then max=$n; fi
  done
  echo "${full}-r$((max + 1))"
}

# patch_upstream RUNTIME FULL — the upstream release: "PHP 8.3.36"
patch_upstream() {
  case "$1" in
    php) echo "PHP $2" ;;
    nodejs) echo "Node.js $2" ;;
    python) echo "Python $2" ;;
    go) echo "Go $2" ;;
    *) echo "$1 $2" ;;
  esac
}

# patch_request_reset LEVEL — a request of LEVEL without reason, CVEs, advisory or deadline (the
# routine patches of ci.sh build --push)
patch_request_reset() {
  PATCH_REQ_LEVEL="$1"
  PATCH_REQ_REASON_EN=""
  PATCH_REQ_REASON_TR=""
  PATCH_REQ_CVES=""
  PATCH_REQ_URL=""
  PATCH_REQ_DEADLINE_HOURS=""
  PATCH_REQ_DEADLINE_AT=""
  PATCH_REQ_PROMOTE=0
}

# patch_one_line TEXT — TEXT on one line, blanks collapsed, trimmed
patch_one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

# patch_request_check — checks and normalizes the request (PATCH_REQ_*): the level; a reason in
# English and Turkish unless routine (one line, at most 300 characters); CVE and GHSA ids; an
# https advisory URL; the deadline (PATCH_REQ_DEADLINE_AT, or now + PATCH_REQ_DEADLINE_HOURS, or
# the level's default: 72 hours for zero-day, 168 for critical). Prints every problem.
patch_request_check() {
  local problems=() id ids=() hours
  if ! patch_level_valid "$PATCH_REQ_LEVEL"; then
    problems+=("level: '${PATCH_REQ_LEVEL}' (routine, security, critical, zero-day)")
  fi

  PATCH_REQ_REASON_EN="$(patch_one_line "$PATCH_REQ_REASON_EN")"
  PATCH_REQ_REASON_TR="$(patch_one_line "$PATCH_REQ_REASON_TR")"
  if [ -n "$PATCH_REQ_REASON_EN$PATCH_REQ_REASON_TR" ] || [ "$PATCH_REQ_LEVEL" != routine ]; then
    [ -n "$PATCH_REQ_REASON_EN" ] || problems+=("reason (en): required for a ${PATCH_REQ_LEVEL} patch, and with a Turkish one")
    [ -n "$PATCH_REQ_REASON_TR" ] || problems+=("reason (tr): required for a ${PATCH_REQ_LEVEL} patch, and with an English one")
  fi
  [ "${#PATCH_REQ_REASON_EN}" -le 300 ] || problems+=("reason (en): longer than 300 characters")
  [ "${#PATCH_REQ_REASON_TR}" -le 300 ] || problems+=("reason (tr): longer than 300 characters")

  for id in ${PATCH_REQ_CVES//,/ }; do
    case "$id" in
      cve-*|Cve-*) id="CVE-${id#*-}" ;;
    esac
    if [[ "$id" =~ ^CVE-[0-9]{4}-[0-9]{4,}$ ]] || [[ "$id" =~ ^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$ ]]; then
      [[ " ${ids[*]-} " == *" ${id} "* ]] || ids+=("$id")
    else
      problems+=("cves: '${id}' is neither CVE-YYYY-NNNN nor GHSA-xxxx-xxxx-xxxx")
    fi
  done
  PATCH_REQ_CVES="$(IFS=,; echo "${ids[*]-}")"

  PATCH_REQ_URL="$(patch_one_line "$PATCH_REQ_URL")"
  if [ -n "$PATCH_REQ_URL" ] && ! [[ "$PATCH_REQ_URL" =~ ^https://[^[:space:]]+$ ]]; then
    problems+=("url: '${PATCH_REQ_URL}' is not an https:// URL")
  fi

  if [ -n "$PATCH_REQ_DEADLINE_AT" ]; then
    patch_time_valid "$PATCH_REQ_DEADLINE_AT" || problems+=("deadline: '${PATCH_REQ_DEADLINE_AT}' is not YYYY-MM-DDTHH:MM:SSZ")
  else
    hours="$PATCH_REQ_DEADLINE_HOURS"
    if [ -z "$hours" ]; then
      case "$PATCH_REQ_LEVEL" in
        zero-day) hours=72 ;;
        critical) hours=168 ;;
      esac
    fi
    if [ -n "$hours" ]; then
      if [[ "$hours" =~ ^[1-9][0-9]{0,3}$ ]]; then
        PATCH_REQ_DEADLINE_AT="$(patch_time_plus "$(patch_now)" "$hours")" || problems+=("deadline: cannot compute now + ${hours} hours")
      else
        problems+=("deadline hours: '${hours}' (1 to 9999)")
      fi
    fi
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    printf "${RED}  %s${NC}\n" "${problems[@]}"
    return 1
  fi
}

# patch_request_json — the request (after patch_request_check) as JSON: level, reason (null for a
# routine patch without one), cves, url, deadline_at
patch_request_json() {
  jq -cn \
    --arg level "$PATCH_REQ_LEVEL" \
    --arg en "$PATCH_REQ_REASON_EN" \
    --arg tr "$PATCH_REQ_REASON_TR" \
    --arg cves "$PATCH_REQ_CVES" \
    --arg url "$PATCH_REQ_URL" \
    --arg deadline "$PATCH_REQ_DEADLINE_AT" \
    '{level: $level,
      reason: (if $en == "" then null else {en: $en, tr: $tr} end),
      cves: ($cves | split(",") | map(select(length > 0))),
      url: (if $url == "" then null else $url end),
      deadline_at: (if $deadline == "" then null else $deadline end)}'
}

# patch_entry_json RUNTIME VERSION TAG IMAGE DIGEST UPSTREAM PUBLISHED_AT REASON_EN REASON_TR — the
# feed entry of a patch of the request
patch_entry_json() {
  patch_jq -cn \
    --arg runtime "$1" --arg version "$2" --arg tag "$3" --arg image "$4" --arg digest "$5" \
    --arg upstream "$6" --arg published "$7" --arg en "$8" --arg tr "$9" \
    --arg level "$PATCH_REQ_LEVEL" --arg cves "$PATCH_REQ_CVES" --arg url "$PATCH_REQ_URL" \
    --arg deadline "$PATCH_REQ_DEADLINE_AT" \
    'include "feed";
     {id: "\($runtime)-\($version)-\($tag)", runtime: $runtime, version: $version, tag: $tag,
      image: $image, digest: $digest, level: $level, reason: {en: $en, tr: $tr},
      cves: ($cves | split(",") | map(select(length > 0))), url: $url, upstream: $upstream,
      published_at: $published, deadline_at: $deadline} | normalize_entry'
}

# patch_result KIND ENTRY — a line of PATCH_RESULTS (JSON lines, read by ci.sh feed update
# --results): {result: new|unchanged|planned, entry, request}
patch_result() {
  [ -n "${PATCH_RESULTS:-}" ] || return 0
  jq -cn --arg result "$1" --argjson entry "$2" --argjson request "$(patch_request_json)" \
    --arg promote "$PATCH_REQ_PROMOTE" \
    '{result: $result, entry: $entry, request: $request} + (if $result == "unchanged" then {promote: ($promote == "1")} else {} end)' \
    >> "$PATCH_RESULTS"
}

# patch_source_epoch CONTEXT — SOURCE_DATE_EPOCH of a build: the time of the last commit of the
# build context (0 outside a git checkout). A shallow checkout knows only its last commit: an
# unchanged image would get another epoch, so it is reported (the workflows fetch the history).
patch_source_epoch() {
  local epoch
  if [ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null || true)" = true ]; then
    echo -e "  ${YELLOW}shallow checkout: SOURCE_DATE_EPOCH is the time of its last commit, so an unchanged image looks changed (fetch the history)${NC}" >&2
  fi
  epoch=$(git -C "$1" log -1 --format=%ct -- . 2>/dev/null || true)
  echo "${epoch:-0}"
}

# patch_base CONTEXT [FLAG...] — the base image of CONTEXT's Dockerfile (its last FROM, with the
# --build-arg values among FLAG) with its digest: ghcr.io/…/reqs/php:8.3-cli-alpine@sha256:…;
# nothing when it cannot be read
patch_base() {
  local context="$1" args=() prev="" flag base digest manifest
  shift
  for flag in "$@"; do
    if [ "$prev" = --build-arg ]; then args+=("$flag"); fi
    prev="$flag"
  done
  base=$(dockerfile_bases "${context}/Dockerfile" ${args[@]+"${args[@]}"} | tail -n 1)
  [ -n "$base" ] || return 0
  manifest=$(mktemp)
  digest=$(registry_manifest "$base" "$manifest" 2>/dev/null) || digest=""
  rm -f -- "$manifest"
  if [ -n "$digest" ]; then echo "${base%@*}@${digest}"; fi
  return 0
}

# patch_buildx CONTEXT EPOCH METADATA OUTPUT [FLAG...] — the reproducible multi-arch build of a
# patch in ci.sh's builder (BUILDER_NAME): PLATFORMS, its base images pulled, no provenance or SBOM
# (they carry build times), SOURCE_DATE_EPOCH and rewrite-timestamp=true (file times clamped to
# it). OUTPUT is the exporter (type=image,push=false or type=image,push=true); METADATA receives
# buildx's metadata (containerimage.digest).
patch_buildx() {
  local context="$1" epoch="$2" metadata="$3" output="$4"
  shift 4
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --pull \
    --platform "${PLATFORMS}" \
    --provenance=false \
    --sbom=false \
    --label "org.opencontainers.image.source=${IMAGE_SOURCE}" \
    --build-arg "SOURCE_DATE_EPOCH=${epoch}" \
    --metadata-file "$metadata" \
    "$@" \
    --output "${output},oci-mediatypes=true,rewrite-timestamp=true" \
    "${context}"
}

# patch_metadata_digest METADATA — containerimage.digest of a buildx metadata file
patch_metadata_digest() {
  local digest
  digest=$(jq -r '."containerimage.digest" // empty' "$1" 2>/dev/null || true)
  if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo -e "  ${RED}no image digest in buildx's metadata (${1})${NC}" >&2
    return 1
  fi
  echo "$digest"
}

# patch_publish_image PUSH RUNTIME VERSION FULL CONTEXT [FLAG...] — publishes the build of
# ${REGISTRY}/exec-RUNTIME:VERSION (FULL: the upstream version it runs, CONTEXT and the build FLAGs)
# as a patch of the request (PATCH_REQ_*), after its smoke test:
#   1. the multi-arch build without pushing: the build digest
#   2. the floating tag's patch has that build digest: unchanged, nothing is pushed
#   3. otherwise the next patch tag of FULL; PUSH=1 pushes the build tagged VERSION and the patch
#      tag, with the patch annotations; PUSH=0 prints what it would publish
# Adds a line to PATCH_RESULTS (new, unchanged or planned) and counts PATCH_PUBLISHED and
# PATCH_UNCHANGED.
patch_publish_image() {
  local push="$1" runtime="$2" version="$3" full="$4" context="$5"
  shift 5
  local repo="${REGISTRY}/exec-${runtime}"
  local floating="${repo}:${version}"
  local work epoch build_digest current_digest="" rc=0 current_tag="" current_build="" current_base=""
  local tags tag base upstream published reason_en reason_tr entry digest annotations=() line

  if ! patch_full_version_valid "$version" "$full"; then
    echo -e "  ${RED}${floating}: '${full}' is not a release of ${version} (the smoke test reports it)${NC}"
    return 1
  fi
  work="$(mktemp -d)"

  epoch="$(patch_source_epoch "$context")"
  echo "==> ${floating}: build (${PLATFORMS}, SOURCE_DATE_EPOCH=${epoch}), not pushed"
  if ! patch_buildx "$context" "$epoch" "${work}/build.json" "type=image,push=false" -t "$floating" "$@"; then
    patch_cleanup "$work"
    return 1
  fi
  build_digest=$(patch_metadata_digest "${work}/build.json") || { patch_cleanup "$work"; return 1; }
  echo "  build digest: ${build_digest}"

  # the patch the floating tag points to
  current_digest=$(registry_manifest "$floating" "${work}/current.json") || rc=$?
  case "$rc" in
    0)
      current_tag=$(jq -r '.annotations["sh.runr.patch.tag"] // empty' "${work}/current.json")
      current_build=$(jq -r '.annotations["sh.runr.patch.build"] // empty' "${work}/current.json")
      current_base=$(jq -r '.annotations["sh.runr.patch.base"] // empty' "${work}/current.json") ;;
    3) current_digest="" ;;
    *)
      echo -e "  ${RED}cannot read ${floating} (a private package needs GHCR_USERNAME and GHCR_TOKEN)${NC}"
      patch_cleanup "$work"
      return 1 ;;
  esac

  if [ -n "$current_tag" ] && [ "$current_build" = "$build_digest" ]; then
    entry=$(patch_jq -c --arg image "$repo" --arg digest "$current_digest" \
      'include "feed"; entry_from_annotations($image; $digest)' "${work}/current.json")
    echo -e "  ${GREEN}unchanged: ${floating} is ${current_tag} (${current_digest}), the same image; no new patch${NC}"
    if [ -n "$entry" ]; then patch_result unchanged "$entry"; fi
    PATCH_UNCHANGED=$(( ${PATCH_UNCHANGED:-0} + 1 ))
    if [ "$PATCH_REQ_LEVEL" = routine ]; then
      PATCH_SUMMARY+=("${floating}  unchanged  ${current_tag}")
    elif [ "$PATCH_REQ_PROMOTE" = 1 ]; then
      echo "  ${current_tag} takes the request's level (${PATCH_REQ_LEVEL}) in the feed: it carries the fix (--promote-unchanged)"
      PATCH_SUMMARY+=("${floating}  unchanged  ${current_tag} → ${PATCH_REQ_LEVEL} in the feed")
    else
      patch_warning "${floating}: the build is unchanged, so no ${PATCH_REQ_LEVEL} patch was published and ${current_tag} keeps its level. Upstream may not have the fix yet (run again later); if ${current_tag} already carries it, run again with promote_unchanged (--promote-unchanged)."
      PATCH_SUMMARY+=("${floating}  unchanged  ${current_tag} (not a ${PATCH_REQ_LEVEL} patch: see the warning)")
    fi
    patch_cleanup "$work"
    return 0
  fi

  tags=$(registry_tags_checked "$repo") || { patch_cleanup "$work"; return 1; }
  # shellcheck disable=SC2086 # the tags, one per word
  tag=$(patch_next_tag "$full" $tags)
  base=$(patch_base "$context" "$@")
  upstream=$(patch_upstream "$runtime" "$full")
  published=$(patch_now)
  reason_en="$PATCH_REQ_REASON_EN"
  reason_tr="$PATCH_REQ_REASON_TR"
  if [ -z "$reason_en" ]; then
    # a routine patch: what changed since the floating tag's patch
    if [ -z "$current_tag" ] || [ "${current_tag%-r*}" != "$full" ]; then
      reason_en="Upstream ${upstream}"
      reason_tr="${upstream} sürümüne güncellendi"
    elif [ -n "$base" ] && [ "$base" != "$current_base" ]; then
      reason_en="Base image refresh"
      reason_tr="Temel imaj yenilendi"
    else
      reason_en="Runtime update"
      reason_tr="Çalışma ortamı güncellendi"
    fi
  fi

  entry=$(patch_entry_json "$runtime" "$version" "$tag" "$repo" "$build_digest" "$upstream" "$published" "$reason_en" "$reason_tr")
  while IFS= read -r line; do
    annotations+=(--annotation "$line")
  done < <(patch_jq -r --arg build "$build_digest" --arg base "$base" \
    'include "feed"; patch_annotations($build; $base)' <<< "$entry")

  echo "  patch: ${repo}:${tag} (${PATCH_REQ_LEVEL}: ${reason_en})${current_tag:+, after ${current_tag}}"
  if [ "$push" != "1" ]; then
    echo -e "  ${YELLOW}dry run: would push ${floating} and ${repo}:${tag} with${NC}"
    printf '    %s\n' "${annotations[@]}" | grep -v '^    --annotation$' || true
    patch_result planned "$entry"
    PATCH_SUMMARY+=("${floating}  would publish  ${tag}")
    patch_cleanup "$work"
    return 0
  fi

  # a patch tag is never overwritten
  rc=0
  registry_manifest "${repo}:${tag}" "${work}/exists.json" >/dev/null || rc=$?
  if [ "$rc" != 3 ]; then
    echo -e "  ${RED}${repo}:${tag} exists already or cannot be checked (another publish of ${runtime}?): not pushed${NC}"
    patch_cleanup "$work"
    return 1
  fi

  echo "==> Pushing ${floating} and ${repo}:${tag} (${PLATFORMS})"
  if ! patch_buildx "$context" "$epoch" "${work}/push.json" "type=image,push=true" \
    -t "$floating" -t "${repo}:${tag}" "${annotations[@]}" "$@"; then
    patch_cleanup "$work"
    return 1
  fi
  digest=$(patch_metadata_digest "${work}/push.json") || { patch_cleanup "$work"; return 1; }
  entry=$(jq -c --arg digest "$digest" '.digest = $digest' <<< "$entry")
  echo -e "  ${GREEN}✓ ${repo}:${tag} (${digest})${NC}"
  patch_result new "$entry"
  PATCH_PUBLISHED=$(( ${PATCH_PUBLISHED:-0} + 1 ))
  PATCH_SUMMARY+=("${floating}  new  ${tag}")
  patch_cleanup "$work"
}

# patch_cleanup DIR — removes a work directory of patch_publish_image (its files, then itself)
patch_cleanup() {
  rm -f -- "${1:?}"/*.json
  rmdir -- "$1" 2>/dev/null || true
}

# patch_push_images PUSH ENTRY... — patch_publish_image of every ENTRY
# ("runtime|version|full version|context|build flag|…") in ci.sh's buildx builder, removed
# afterwards; prints what was published
patch_push_images() {
  local push="$1" entry fields runtime version full context rc=0
  shift
  PATCH_PUBLISHED=0
  PATCH_UNCHANGED=0
  PATCH_SUMMARY=()
  ensure_buildx
  for entry in "$@"; do
    IFS='|' read -r -a fields <<< "$entry"
    runtime="${fields[0]}"
    version="${fields[1]}"
    full="${fields[2]}"
    context="${fields[3]}"
    fields=("${fields[@]:4}")
    patch_publish_image "$push" "$runtime" "$version" "$full" "$context" ${fields[@]+"${fields[@]}"} || { rc=1; break; }
    echo ""
  done
  cleanup_buildx
  if [ "${#PATCH_SUMMARY[@]}" -gt 0 ]; then
    echo -e "${BOLD}── Patches ──${NC}"
    printf '  %s\n' "${PATCH_SUMMARY[@]}"
    echo ""
  fi
  return "$rc"
}

# patch_versions_check SPEC RUNTIME... — SPEC is "all" or versions (major.minor, blank- or
# comma-separated); plain versions for one runtime only, runtime:version for several; every
# runtime gets at least one
patch_versions_check() {
  local spec="${1//,/ }" item runtime problems=() named=()
  shift
  [ -n "${spec// /}" ] || spec="all"
  [ "$spec" = all ] && return 0
  for item in $spec; do
    if [[ "$item" == *:* ]]; then
      runtime="${item%%:*}"
      [[ " $* " == *" ${runtime} "* ]] || problems+=("versions: ${item} names a runtime that is not patched (${*})")
      named+=("$runtime")
      item="${item#*:}"
    elif [ "$#" -gt 1 ]; then
      problems+=("versions: ${item}: with several runtimes, name the runtime (php:8.3) or patch all versions")
    fi
    [[ "$item" =~ ^[0-9]+\.[0-9]+$ ]] || problems+=("versions: '${item}' is not major.minor")
  done
  if [ "$#" -gt 1 ]; then
    for runtime in "$@"; do
      [[ " ${named[*]-} " == *" ${runtime} "* ]] || problems+=("versions: no version of ${runtime}")
    done
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    printf "${RED}  %s${NC}\n" "${problems[@]}"
    return 1
  fi
}

# patch_versions_for RUNTIME SPEC — the versions SPEC names for RUNTIME (after
# patch_versions_check), "all" for every current version
patch_versions_for() {
  local runtime="$1" spec="${2//,/ }" item picked=()
  [ -n "${spec// /}" ] || spec="all"
  if [ "$spec" = all ]; then echo all; return 0; fi
  for item in $spec; do
    if [[ "$item" == *:* ]]; then
      [ "${item%%:*}" = "$runtime" ] && picked+=("${item#*:}")
    else
      picked+=("$item")
    fi
  done
  echo "${picked[*]-}"
}

# cmd_patch — patch language runtime images on request (the patch workflow, or an operator's
# shell): build and smoke-test the versions named, publish each changed one as a patch of the
# request, update the patch feed. A dry run without --push.
cmd_patch() {
  local push=0 check=0 feed=1 results="" only="" versions="${PATCH_VERSIONS:-all}" runtimes=() arg word
  PATCH_REQ_LEVEL="${PATCH_LEVEL:-}"
  PATCH_REQ_REASON_EN="${PATCH_REASON_EN:-}"
  PATCH_REQ_REASON_TR="${PATCH_REASON_TR:-}"
  PATCH_REQ_CVES="${PATCH_CVES:-}"
  PATCH_REQ_URL="${PATCH_URL:-}"
  PATCH_REQ_DEADLINE_HOURS="${PATCH_DEADLINE_HOURS:-}"
  PATCH_REQ_DEADLINE_AT="${PATCH_DEADLINE_AT:-}"
  case "${PATCH_PROMOTE_UNCHANGED:-}" in
    1|true) PATCH_REQ_PROMOTE=1 ;;
    *) PATCH_REQ_PROMOTE=0 ;;
  esac

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --push) push=1 ;;
      --check) check=1 ;;
      --no-feed) feed=0 ;;
      --promote-unchanged) PATCH_REQ_PROMOTE=1 ;;
      --results|--only|--versions|--level|--reason-en|--reason-tr|--cves|--url|--deadline-hours|--deadline-at)
        [ "$#" -ge 2 ] || { echo -e "${RED}${arg} needs a value${NC}"; return 1; }
        case "$arg" in
          --results) results="$2" ;;
          --only) only="$2" ;;
          --versions) versions="$2" ;;
          --level) PATCH_REQ_LEVEL="$2" ;;
          --reason-en) PATCH_REQ_REASON_EN="$2" ;;
          --reason-tr) PATCH_REQ_REASON_TR="$2" ;;
          --cves) PATCH_REQ_CVES="$2" ;;
          --url) PATCH_REQ_URL="$2" ;;
          --deadline-hours) PATCH_REQ_DEADLINE_HOURS="$2"; PATCH_REQ_DEADLINE_AT="" ;;
          --deadline-at) PATCH_REQ_DEADLINE_AT="$2" ;;
        esac
        shift ;;
      -*) echo -e "${RED}unknown argument: ${arg} (ci.sh help)${NC}"; return 1 ;;
      *) runtimes+=("$arg") ;;
    esac
    shift
  done
  [ "${#runtimes[@]}" -gt 0 ] || runtimes=("${PATCH_RUNTIMES:-}")

  patch_tools || return 1
  # the runtimes named (blank- or comma-separated, "all"), each once
  local selected=() words=() expanded=() every=() named
  named="${runtimes[*]}"
  read -r -a words <<< "${named//,/ }"
  read -r -a every <<< "$PATCH_LANGUAGE_RUNTIMES"
  for word in ${words[@]+"${words[@]}"}; do
    if [ "$word" = all ]; then
      expanded+=("${every[@]}")
    else
      expanded+=("$word")
    fi
  done
  for word in ${expanded[@]+"${expanded[@]}"}; do
    case "$word" in
      python|nodejs|go|php) [[ " ${selected[*]-} " == *" ${word} "* ]] || selected+=("$word") ;;
      *) echo -e "${RED}unknown runtime: ${word} (python, nodejs, go, php, all)${NC}"; return 1 ;;
    esac
  done
  if [ "${#selected[@]}" -eq 0 ]; then
    echo -e "${RED}no runtime to patch (python, nodejs, go, php, all)${NC}"
    return 1
  fi

  echo -e "${BOLD}Patch request${NC}" >&2
  local ok=0
  patch_request_check >&2 || ok=1
  patch_versions_check "$versions" "${selected[@]}" >&2 || ok=1
  if [ -n "$only" ] && [[ " ${selected[*]} " != *" ${only} "* ]]; then
    echo -e "${RED}  --only ${only}: not a runtime of the request (${selected[*]})${NC}" >&2
    ok=1
  fi
  [ "$ok" = 0 ] || return 1

  if [ "$check" = 1 ]; then
    jq -cn --argjson request "$(patch_request_json)" --arg versions "$versions" --arg promote "$PATCH_REQ_PROMOTE" \
      --args '{runtimes: $ARGS.positional, versions: $versions} + $request + {promote_unchanged: ($promote == "1")}' \
      "${selected[@]}"
    return 0
  fi
  # one runtime of the request (a job of the patch workflow)
  if [ -n "$only" ]; then
    selected=("$only")
  fi
  if [ "$push" = 1 ] && [ "$feed" = 1 ]; then
    feed_tools 1 || return 1
  fi

  local results_file="$results"
  if [ -z "$results_file" ]; then
    results_file="$(mktemp)"
  fi
  : > "$results_file"
  PATCH_RESULTS="$results_file"

  discover_language_versions "${selected[@]}"

  local runtime wanted version built=() tag dir current
  for runtime in "${selected[@]}"; do
    current=" ${DISCOVERED[$runtime]:-} "
    wanted="$(patch_versions_for "$runtime" "$versions")"
    if [ "$wanted" = all ]; then wanted="${DISCOVERED[$runtime]:-}"; fi
    if [ -z "${wanted// /}" ]; then
      echo -e "${RED}${runtime}: no current version found (Docker Hub, endoflife.date)${NC}"
      return 1
    fi
    for version in $wanted; do
      if [[ "$current" != *" ${version} "* ]]; then
        echo -e "${RED}${runtime} ${version} is not a current version (current:${DISCOVERED[$runtime]:- none})${NC}"
        return 1
      fi
    done
    dir="$(runtime_dir "$runtime")"
    for version in $wanted; do
      tag="${REGISTRY}/exec-${runtime}:${version}"
      echo "==> Building ${tag}"
      SMOKE_FULL_VERSION=""
      do_build "${tag}" "${dir}" 0 --build-arg "VERSION=${version}" || return 1
      runtime_smoke "$tag" "$runtime" "$version" || return 1
      built+=("${runtime}|${version}|${SMOKE_FULL_VERSION}|${dir}|--build-arg|VERSION=${version}")
      echo ""
    done
  done

  patch_push_images "$push" "${built[@]}" || return 1

  if [ "$feed" = 1 ]; then
    feed_update "$push" "" "" --results "$results_file" || return 1
  fi
  if [ -z "$results" ]; then
    rm -f -- "$results_file"
  fi
  if [ "$push" != 1 ]; then
    echo "Dry run: nothing was pushed. To publish: the same command with --push."
  fi
}
