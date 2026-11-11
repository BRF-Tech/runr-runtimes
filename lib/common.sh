# ── Shared variables and functions ──
# This file is sourced, so it has no shebang.

REGISTRY="${REGISTRY:-ghcr.io/brf-tech/runr}"
EOL_API="https://endoflife.date/api"
# Every image carries it (do_build): GHCR links a package to this repository through it
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/BRF-Tech/runr-runtimes}"

# runtime_dir ID — the directory of a built-in runtime of RunR's catalog: runtimes/<id>/
# (runtime.yaml, Dockerfile, the language's handler server) under SCRIPT_DIR, the repository root
# ci.sh sets; RUNTIMES_DIR replaces runtimes/
runtime_dir() {
  echo "${RUNTIMES_DIR:-${SCRIPT_DIR}/runtimes}/$1"
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# The language runtimes: `ci.sh build` discovers their versions, builds exec-<id>:<major.minor> on
# the base image of each (mirrored by `ci.sh mirror-bases`), the patch feed lists their patches.
#   id|upstream image|tag suffix|lowest version|tag depth|filter|endoflife.date product
# - upstream image: a Docker Hub repository (library/python, oven/bun) or one with its registry
#   (mcr.microsoft.com/dotnet/sdk); its tags <version><suffix> are the versions
# - tag depth: major.minor (python:3.13-slim) or major (eclipse-temurin:21-jdk); a major version
#   is the runtime version <major>.0 (exec-java:21.0, and eclipse-temurin:21.0-jdk on the reqs
#   mirror), since RunR's versions and the patch tags are <major>.<minor>
# - filter: lts-even-major (the newest minor of each even major: Node.js LTS lines), lts (the
#   cycles endoflife.date marks LTS), released (the cycles endoflife.date lists: no previews or
#   release candidates), newest-minor (the newest minor of each major: Bun supports only its
#   latest release); none: every version from the lowest on
# - endoflife.date product: the EOL check's (default: the id)
RUNTIME_DEFS=(
  "python|library/python|-slim|3.10|major.minor||python"
  "nodejs|library/node|-slim|20.0|major.minor|lts-even-major|nodejs"
  "go|library/golang|-alpine|1.22|major.minor||go"
  "php|library/php|-cli-alpine|8.2|major.minor||php"
  "java|library/eclipse-temurin|-jdk|21|major|lts|eclipse-temurin"
  "dotnet|mcr.microsoft.com/dotnet/sdk||10.0|major.minor|released|dotnet"
  "ruby|library/ruby|-slim|3.3|major.minor||ruby"
  "bun|oven/bun|-slim|1.4|major.minor|newest-minor|bun"
)

# The Ubuntu release of the chiseled runtime-deps image .NET functions run on
# (mcr.microsoft.com/dotnet/runtime-deps:<version>-<distro>-chiseled-extra, mirrored as
# dotnet-runtime-deps:<version>-chiseled-extra)
DOTNET_RUN_DISTRO="${DOTNET_RUN_DISTRO:-resolute}"

# runtime_ids — the ids of the language runtimes, blank-separated
runtime_ids() {
  local def ids=""
  for def in "${RUNTIME_DEFS[@]}"; do
    ids="${ids:+${ids} }${def%%|*}"
  done
  echo "$ids"
}

# runtime_def ID — the RUNTIME_DEFS entry of a language runtime (status 1: none)
runtime_def() {
  local def
  for def in "${RUNTIME_DEFS[@]}"; do
    if [ "${def%%|*}" = "$1" ]; then
      echo "$def"
      return 0
    fi
  done
  return 1
}

# runtime_product ID — the endoflife.date product of a language runtime
runtime_product() {
  local def runtime repo suffix min_ver depth filter product
  def="$(runtime_def "$1")" || { echo "$1"; return 0; }
  IFS='|' read -r runtime repo suffix min_ver depth filter product <<< "$def"
  echo "${product:-$runtime}"
}

# The versions of a language runtime past their end of life that the language bot archived
# (ci/lang-bot.sh archive): runtimes/<runtime>/archived-versions, one "<major.minor> <end of life>
# <digest>" per line. The image stays as exec-<runtime>:eol-<major.minor> (and its patch tags); its
# floating tag is gone. The build, the watch and the patch feed leave such a version out.
ARCHIVE_TAG_PREFIX="eol-"

# archived_versions RUNTIME — the archived versions of RUNTIME, one per line
archived_versions() {
  local file
  file="$(runtime_dir "$1")/archived-versions"
  [ -f "$file" ] || return 0
  awk '!/^#/ && NF >= 1 { print $1 }' "$file"
}

# is_archived RUNTIME VERSION — whether the bot archived VERSION of RUNTIME
is_archived() {
  archived_versions "$1" | grep -qxF -- "$2"
}

# base_mirror_name REPO — the name of an upstream image on the reqs mirror: the repository's last
# segment for Docker Hub (library/python → python, oven/bun → bun), the path with "-" for "/" for
# an image with its registry (mcr.microsoft.com/dotnet/sdk → dotnet-sdk)
base_mirror_name() {
  if registry_qualified "$1"; then
    local path="${1#*/}"
    echo "${path//\//-}"
  else
    echo "${1##*/}"
  fi
}

# runtime_base_images ID VERSION — the base images of a language runtime version on the reqs
# mirror, one "target|source" per line (the form of REQS_IMAGES): the image its Dockerfile builds
# on, and for .NET the runtime-deps image its functions run on
runtime_base_images() {
  local def runtime repo suffix min_ver depth filter product upstream
  def="$(runtime_def "$1")" || return 1
  IFS='|' read -r runtime repo suffix min_ver depth filter product <<< "$def"
  upstream="$2"
  if [ "$depth" = major ]; then
    upstream="${2%%.*}"
  fi
  echo "$(base_mirror_name "$repo"):${2}${suffix}|${repo#library/}:${upstream}${suffix}"
  if [ "$runtime" = dotnet ]; then
    echo "dotnet-runtime-deps:${2}-chiseled-extra|mcr.microsoft.com/dotnet/runtime-deps:${2}-${DOTNET_RUN_DISTRO}-chiseled-extra"
  fi
}

# fetch_tags REPO [SUFFIX] — the tags of an upstream image, blank-separated: from its registry's
# OCI API for an image with its registry (registry_tags of lib/registry.sh), else from Docker Hub's
# API (the tags whose name contains SUFFIX, up to 10 pages of 100)
fetch_tags() {
  local repo="$1" suffix="${2:-}"
  local page=1
  local all_tags=""

  if registry_qualified "$repo"; then
    registry_tags "$(registry_api_host "$repo")" "${repo#*/}" | tr '\n' ' '
    return 0
  fi

  while true; do
    local url="https://hub.docker.com/v2/repositories/${repo}/tags/?page=${page}&page_size=100${suffix:+&name=${suffix}}"
    local response
    response=$(curl -sf "$url" 2>/dev/null) || break

    local tags
    tags=$(echo "$response" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//') || true
    [ -z "$tags" ] && break
    all_tags="${all_tags} ${tags}"

    echo "$response" | grep -q '"next":null' && break
    page=$((page + 1))
    [ "$page" -gt 10 ] && break
  done

  echo "$all_tags"
}

version_gte() {
  local lower
  lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)
  [ "$lower" = "$2" ]
}

discover_versions() {
  local repo="$1" suffix="$2" min_ver="$3" depth="$4"
  local raw_tags matched=""

  raw_tags=$(fetch_tags "$repo" "$suffix")

  for tag in $raw_tags; do
    [[ "$tag" == *"${suffix}" ]] || continue
    local ver="${tag%${suffix}}"
    [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue

    case "$depth" in
      major)       [[ "$ver" =~ ^[0-9]+$ ]] || continue ;;
      major.minor) [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue ;;
    esac

    version_gte "$ver" "$min_ver" || continue
    matched="${matched} ${ver}"
  done

  echo "$matched" | tr ' ' '\n' | grep -v '^$' | sort -V | uniq
}

filter_nodejs_lts() {
  local versions="$1"
  local -A latest_minor

  for ver in $versions; do
    local major="${ver%%.*}"
    (( major % 2 != 0 )) && continue
    if [ -z "${latest_minor[$major]:-}" ] || version_gte "$ver" "${latest_minor[$major]}"; then
      latest_minor[$major]="$ver"
    fi
  done

  for major in $(echo "${!latest_minor[@]}" | tr ' ' '\n' | sort -n); do
    echo "${latest_minor[$major]}"
  done
}

# filter_newest_minor VERSIONS — the newest minor of each major (Bun: only its latest release is
# supported)
filter_newest_minor() {
  local versions="$1" ver major
  local -A newest=()
  for ver in $versions; do
    major="${ver%%.*}"
    if [ -z "${newest[$major]:-}" ] || version_gte "$ver" "${newest[$major]}"; then
      newest[$major]="$ver"
    fi
  done
  for major in $(echo "${!newest[@]}" | tr ' ' '\n' | sort -n); do
    echo "${newest[$major]}"
  done
}

# eol_cycle PRODUCT VERSION — endoflife.date's JSON of the release cycle of VERSION: its
# major.minor, else its major (eclipse-temurin 21.0 is cycle 21, dotnet 10.0 cycle 10); nothing
# when it has none
eol_cycle() {
  local product="$1" version="$2" cycle response
  cycle=$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+') || true
  if [ -n "$cycle" ]; then
    response=$(curl -sf "${EOL_API}/${product}/${cycle}.json" 2>/dev/null) || true
    if [ -n "$response" ]; then
      echo "$response"
      return 0
    fi
  fi
  curl -sf "${EOL_API}/${product}/${version%%.*}.json" 2>/dev/null || true
}

# filter_lts PRODUCT VERSIONS — the versions whose cycle endoflife.date marks LTS ("lts": true, or
# the date it became one)
filter_lts() {
  local product="$1" ver
  for ver in $2; do
    if eol_cycle "$product" "$ver" | grep -qE '"lts" *: *(true|"[0-9])'; then
      echo "$ver"
    fi
  done
}

# filter_released PRODUCT VERSIONS — the versions whose cycle endoflife.date lists: a preview or
# release candidate has none yet (mcr.microsoft.com/dotnet/sdk:11.0 before .NET 11 is out)
filter_released() {
  local product="$1" ver
  for ver in $2; do
    if [ -n "$(eol_cycle "$product" "$ver")" ]; then
      echo "$ver"
    fi
  done
}

# runtime_versions ID — the versions of a language runtime that its upstream image has (from the
# lowest on, its filter applied), as RunR's runtime versions: major.minor, <major>.0 for a major
# tag (eclipse-temurin:21-jdk → 21.0); one per line, oldest first. The EOL check is the build's
# (discover_language_versions).
runtime_versions() {
  local def runtime repo suffix min_ver depth filter product versions ver
  def="$(runtime_def "$1")" || return 1
  IFS='|' read -r runtime repo suffix min_ver depth filter product <<< "$def"
  product="${product:-$runtime}"
  versions=$(discover_versions "$repo" "$suffix" "$min_ver" "$depth")
  [ -n "$versions" ] || return 0
  case "$filter" in
    lts-even-major) versions=$(filter_nodejs_lts "$versions") ;;
    newest-minor) versions=$(filter_newest_minor "$versions") ;;
    lts) versions=$(filter_lts "$product" "$versions") ;;
    released) versions=$(filter_released "$product" "$versions") ;;
  esac
  for ver in $versions; do
    if [ "$depth" = major ]; then
      echo "${ver}.0"
    else
      echo "$ver"
    fi
  done
}

# ── Docker Hub and Dockerfile base images ──

# registry_qualified REF — does an image reference name its registry? Its first path segment is a
# registry host when it has a "." or a ":" or is localhost (ghcr.io/…, quay.io/…,
# registry.local:5000/…, localhost/…); alpine:3.21 and grafana/k6:1.8.2 are Docker Hub's
registry_qualified() {
  case "$1" in
    */*) ;;
    *) return 1 ;;
  esac
  case "${1%%/*}" in
    localhost|*.*|*:*) return 0 ;;
  esac
  return 1
}

# dockerhub_path SOURCE — the Docker Hub repository path of an image: alpine:3.21 →
# library/alpine:3.21; tinygo/tinygo:0.42.0 and a tag@digest stay as they are. A reference with
# its registry (registry_qualified) is no Docker Hub image: no output, status 1.
dockerhub_path() {
  registry_qualified "$1" && return 1
  case "${1%%[:@]*}" in
    */*) echo "$1" ;;
    *) echo "library/$1" ;;
  esac
}

# dockerhub_digest PATH — Docker Hub's digest of a repository path (library/alpine:3.21; a
# path@sha256:… is its own digest), read with a HEAD request, which the anonymous pull limit does
# not count: crane when it is installed, otherwise curl against the registry API. A reference with
# its registry (registry_qualified) is no Docker Hub image: no request, no output, status 1.
dockerhub_digest() {
  local path="$1" repo ref token digest
  registry_qualified "$path" && return 1
  case "$path" in
    *@sha256:*) echo "${path##*@}"; return 0 ;;
  esac
  if command -v crane >/dev/null 2>&1; then
    crane digest "docker.io/${path}" 2>/dev/null
    return
  fi
  repo="${path%:*}"
  ref="${path##*:}"
  token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
  digest=$(curl -fsSI -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/${ref}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }')
  [ -n "$digest" ] && echo "$digest"
}

# dockerfile_bases DOCKERFILE [NAME=VALUE...] — the base image of every stage of a Dockerfile,
# ${NAME} replaced by the build argument given or by the default of its ARG before the first FROM.
# Stage names, scratch and references that stay variable (cross-${TARGETARCH}) are left out.
dockerfile_bases() {
  local file="$1"
  shift
  awk -v overrides="$*" '
    BEGIN {
      n = split(overrides, kv, " ")
      for (i = 1; i <= n; i++) {
        eq = index(kv[i], "=")
        if (eq) given[substr(kv[i], 1, eq - 1)] = substr(kv[i], eq + 1)
      }
    }
    function subst(s,   out, m, name, val) {
      out = ""
      while (match(s, /[$]([{][A-Za-z_][A-Za-z0-9_]*[}]|[A-Za-z_][A-Za-z0-9_]*)/)) {
        m = substr(s, RSTART, RLENGTH)
        name = m
        gsub(/[${}]/, "", name)
        if (name in given) val = given[name]
        else if (name in args) val = args[name]
        else { unresolved = 1; val = m }
        out = out substr(s, 1, RSTART - 1) val
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    toupper($1) == "ARG" && !from {
      eq = index($2, "=")
      if (eq) {
        val = substr($2, eq + 1)
        gsub(/^["\047]|["\047]$/, "", val)
        args[substr($2, 1, eq - 1)] = val
      }
    }
    toupper($1) == "FROM" {
      from = 1
      i = 2
      while ($i ~ /^--/) i++
      unresolved = 0
      ref = subst($i)
      if (!unresolved && ref != "scratch" && !(tolower(ref) in stages)) print ref
      if (tolower($(i + 1)) == "as") stages[tolower($(i + 2))] = 1
    }
  ' "$file"
}


is_past_date() {
  local date_str="$1"
  local today
  today=$(date +%Y-%m-%d)
  [[ "$date_str" < "$today" || "$date_str" == "$today" ]]
}

check_eol() {
  local runtime="$1" tag="$2"

  local cycle
  cycle=$(echo "$tag" | grep -oE '^[0-9]+\.[0-9]+') || true

  if [ -n "$cycle" ]; then
    local response
    response=$(curl -sf "${EOL_API}/${runtime}/${cycle}.json" 2>/dev/null) || true
    if [ -n "$response" ]; then
      parse_eol_response "$response"
      return
    fi
  fi

  local major="${tag%%.*}"
  local response
  response=$(curl -sf "${EOL_API}/${runtime}/${major}.json" 2>/dev/null) || true
  if [ -n "$response" ]; then
    parse_eol_response "$response"
    return
  fi

  echo "unknown"
}

parse_eol_response() {
  local response="$1"
  local eol_field
  eol_field=$(echo "$response" | grep -o '"eol":[^,}]*' | head -1 | sed 's/"eol"://') || true

  if [[ "$eol_field" =~ ^\"[0-9]{4}-[0-9]{2}-[0-9]{2}\" ]]; then
    local eol_date
    eol_date=$(echo "$eol_field" | tr -d '"')
    if is_past_date "$eol_date"; then
      echo "eol|${eol_date}"
    else
      echo "supported|${eol_date}"
    fi
  elif [ "$eol_field" = "true" ]; then
    echo "eol|true"
  elif [ "$eol_field" = "false" ]; then
    echo "supported|false"
  else
    echo "unknown"
  fi
}
