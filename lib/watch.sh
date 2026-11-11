# ── The upstream releases the images follow ──
# This file is sourced, so it has no shebang.
#
# cmd_watch — `ci.sh watch [--report=DIR]`: every upstream release the images of this repository
# should follow and do not yet, each one a finding. Printed, and with --report written to DIR: a
# Markdown file per finding whose first line is its title. .github/workflows/lang-releases.yml files
# an issue for each title no issue has yet, and .github/workflows/lang-test.yml tests the ones it
# can (the language runtimes, the tools their images pin and the ML frameworks).
#
#   lang: <runtime> <X.Y.Z> released          a language runtime of RUNTIME_DEFS (lib/common.sh):
#                                             a new patch release of a published version, or a new
#                                             version not yet published, as `ci.sh build` would
#                                             discover it (its filter: Node.js the newest minor of
#                                             an even major, Java the LTS majors, .NET the released
#                                             versions, Bun the newest minor). Not one the language
#                                             bot tested already (runtimes/<runtime>/tested-versions):
#                                             the next publish publishes that one
#   lang: <runtime> <X.Y> end of life <date>  a published version whose end of life
#                                             (endoflife.date) is past or within WATCH_EOL_DAYS
#                                             (default 60); the weekly build already stops
#                                             building it once it is past. Checked whatever the
#                                             upstream images answer
#   lang: <tool> <X.Y.Z> released             a tool a language image pins (WATCH_TOOL_DEFS: Maven
#                                             and its dependency plugin in exec-java) newer than
#                                             its ARG, in the pin's major line
#   lang: pytorch|tensorflow <X.Y.Z> released a framework release newer than its pin
#                                             (requirements-torch.txt, requirements-cpu.txt)
#   lang: <tool> <version> released           a toolchain of the WebAssembly images newer than its
#                                             ARG in runtimes/wasm-*/Dockerfile: spin, tinygo,
#                                             wasi-sdk, wasm-tools, zig, componentize-py, spin-sdk,
#                                             rust
#
# The upstreams: the tags of the base images (RUNTIME_DEFS: Docker Hub, or the image's registry:
# mcr.microsoft.com), the published tags of ${REGISTRY}/exec-<runtime> (the patch tags <full>-r<n>
# name the upstream version a tag runs), endoflife.date, Maven Central, PyPI, GitHub releases
# (GH_TOKEN raises GitHub's rate limit) and ziglang.org.
# WATCH_FIXTURES=DIR answers every request from DIR (the tests): the file named after the URL with
# every character but [A-Za-z0-9._-] as _; none is a 404, the name with @500 a server error.
# An upstream that does not answer fails the watch, after the others were checked; endoflife.date's
# 404 for a cycle it does not list (Node.js 24.22: its cycles are majors) is an answer.

WATCH_EOL_DAYS="${WATCH_EOL_DAYS:-60}"
WATCH_HUB="https://hub.docker.com/v2/repositories"

# watch_get URL — the body of URL (or its fixture). Status 3: HTTP 404, 1: any other failure (after
# curl's retries of a timeout and of an HTTP 408, 429 or 5xx answer)
watch_get() {
  local url="$1"
  if [ -n "${WATCH_FIXTURES:-}" ]; then
    local file="${WATCH_FIXTURES}/${url//[^A-Za-z0-9._-]/_}"
    if [ -f "$file" ]; then
      cat "$file"
      return 0
    fi
    [ -f "${file}@500" ] && return 1
    return 3
  fi
  local auth=() body status
  if [[ "$url" == https://api.github.com/* ]] && [ -n "${GH_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H 'Accept: application/vnd.github+json')
  fi
  body="$(mktemp)"
  status="$(curl -sSL --retry 3 --retry-delay 5 --connect-timeout 30 ${auth[@]+"${auth[@]}"} -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || status="${status:-000}"
  status="${status: -3}"
  case "$status" in
    200) cat "$body"; rm -f -- "$body"; return 0 ;;
    404) rm -f -- "$body"; return 3 ;;
    *) rm -f -- "$body"; return 1 ;;
  esac
}

# watch_digest ALGORITHM URL — the sha256 or sha512 of a download (or of its fixture), downloaded
# with fetch_download (lib/fetch.sh: retries, a GitHub release asset through the API)
watch_digest() {
  local sum file
  if [ -n "${WATCH_FIXTURES:-}" ]; then
    file="${WATCH_FIXTURES}/${2//[^A-Za-z0-9._-]/_}"
    [ -f "$file" ] || return 1
    sum="$("${1}sum" "$file")"
  else
    file="$(mktemp)"
    if ! fetch_download "$2" "$file"; then
      rm -f -- "$file"
      return 1
    fi
    sum="$("${1}sum" "$file")"
    rm -f -- "$file"
  fi
  echo "${sum%% *}"
}

# watch_sha256 URL — the SHA256 of a download (or of its fixture)
watch_sha256() {
  watch_digest sha256 "$1"
}

# watch_hub_tags REPO — the tags of a Docker Hub repository (library/python), one per line: the
# newest WATCH_HUB_PAGES pages of 100 (default 10, as fetch_tags reads them; Docker Hub lists the
# tags updated last first and refuses many pages in a row). A page after the first that does not
# answer ends the list there.
watch_hub_tags() {
  local url="${WATCH_HUB}/${1}/tags/?page_size=100" page=0 body
  while [ -n "$url" ] && [ "$url" != null ] && [ "$page" -lt "${WATCH_HUB_PAGES:-10}" ]; do
    if ! body="$(watch_get "$url")"; then
      [ "$page" -gt 0 ] && return 0
      return 1
    fi
    jq -r '.results[]?.name' <<< "$body"
    url="$(jq -r '.next // empty' <<< "$body")"
    page=$((page + 1))
  done
}

# watch_published_tags RUNTIME — the tags of ${REGISTRY}/exec-RUNTIME (registry_tags, anonymous)
watch_published_tags() {
  local host ns
  if [ -n "${WATCH_FIXTURES:-}" ]; then
    watch_get "published-exec-$1"
    return
  fi
  host=$(registry_api_host "$REGISTRY")
  ns=$(registry_namespace "$REGISTRY")
  registry_tags "$host" "${ns:+${ns}/}exec-$1"
}

# watch_eol_json PRODUCT VERSION — endoflife.date's JSON of the cycle of VERSION, as check_eol of
# lib/common.sh asks it: the cycle major.minor, else the major (Node.js, Temurin, .NET, Bun).
# Status 3: endoflife.date lists neither, 1: it did not answer
watch_eol_json() {
  local cycle body rc
  for cycle in "$2" "${2%%.*}"; do
    rc=0
    body="$(watch_get "${EOL_API}/$1/${cycle}.json")" || rc=$?
    case "$rc" in
      0) jq -c . <<< "$body" 2>/dev/null || return 1; return 0 ;;
      3) ;;
      *) return 1 ;;
    esac
  done
  return 3
}

# watch_eol PRODUCT VERSION — "eol|DATE", "supported|DATE", "supported|false" or "unknown" (no cycle
# on endoflife.date); status 1 when endoflife.date did not answer
watch_eol() {
  local body rc=0
  body="$(watch_eol_json "$1" "$2")" || rc=$?
  case "$rc" in
    0) parse_eol_response "$body" ;;
    3) echo unknown ;;
    *) return 1 ;;
  esac
}

# watch_report NAME TITLE BODY — one finding (WATCH_REPORT_DIR/NAME.md, its first line the title)
watch_report() {
  echo "▶ $2"
  WATCH_FOUND=$((WATCH_FOUND + 1))
  [ -n "${WATCH_REPORT_DIR:-}" ] || return 0
  mkdir -p "$WATCH_REPORT_DIR"
  printf '%s\n\n%s\n' "$2" "$3" > "${WATCH_REPORT_DIR}/$1.md"
}

# watch_days_until DATE — whole days from today to DATE (YYYY-MM-DD; negative when past)
watch_days_until() {
  echo $(( ( $(date -u -d "$1" +%s) - $(date -u -d "$(watch_today)" +%s) ) / 86400 ))
}

# watch_today — today (UTC, YYYY-MM-DD; WATCH_TODAY in the tests)
watch_today() {
  echo "${WATCH_TODAY:-$(date -u +%Y-%m-%d)}"
}

# watch_tags REPO — the tags of an upstream image, one per line: Docker Hub's (watch_hub_tags), or
# for an image with its registry (mcr.microsoft.com/dotnet/sdk) that registry's tags/list
watch_tags() {
  if ! registry_qualified "$1"; then
    watch_hub_tags "$1"
    return
  fi
  if [ -n "${WATCH_FIXTURES:-}" ]; then
    watch_get "https://${1%%/*}/v2/${1#*/}/tags/list" | jq -r '.tags[]?'
    return
  fi
  local tags
  tags="$(registry_tags "$(registry_api_host "$1")" "${1#*/}")"
  [ -n "$tags" ] || return 1
  echo "$tags"
}

# watch_release_source RUNTIME REPO SUFFIX — "image|tag suffix" whose tags name the runtime's
# releases: its upstream image, but for .NET the runtime-deps image its functions run on (the SDK
# image's tags are SDK versions, 10.0.403; runtime-deps's are the runtime's, 10.0.14, which the
# smoke test reads)
watch_release_source() {
  case "$1" in
    dotnet) echo "mcr.microsoft.com/dotnet/runtime-deps|-${DOTNET_RUN_DISTRO}-chiseled-extra" ;;
    *) echo "${2}|${3}" ;;
  esac
}

# watch_releases RUNTIME SUFFIX — the releases X.Y.Z in the tags on stdin, oldest first:
# <X.Y.Z><suffix>, for Java Temurin's <X.Y.Z>[.<n>]_<build><suffix> (21.0.13_9-jdk; a GA is
# <X>_<build>, 27_35-jdk: 27.0.0; 21.0.12.1_1-jdk is 21.0.12, the version the JVM reports)
watch_releases() {
  case "$1" in
    java) sed -En "s/^([0-9]+)(\.[0-9]+\.[0-9]+)?(\.[0-9]+)?_[0-9]+${2}$/\1\2/p" | awk -F. 'NF == 1 { $0 = $0 ".0.0" } { print }' ;;
    *) sed -En "s/^([0-9]+\.[0-9]+\.[0-9]+)${2}$/\1/p" ;;
  esac | sort -V -u
}

# watch_release_tag RUNTIME RELEASE SUFFIX — the upstream tag of RELEASE in the tags on stdin
# (Temurin's newest build of it: 21.0.13_9-jdk, 29_30-jdk for 29.0.0)
watch_release_tag() {
  local re
  case "$1" in
    java)
      re="${2//./\\.}(\\.[0-9]+)?"
      if [[ "$2" == *.0.0 ]]; then re="(${2//./\\.}|${2%%.*})"; fi
      grep -E "^${re}_[0-9]+${3}$" | sort -V | tail -n 1 ;;
    *) echo "${2}${3}" ;;
  esac
}

# watch_minors DEPTH SUFFIX MIN — RunR's versions in the tags on stdin, at or above MIN, oldest
# first: <X.Y><suffix>, or <X><suffix> as X.0 (depth major: eclipse-temurin:21-jdk is 21.0)
watch_minors() {
  local ver
  if [ "$1" = major ]; then
    sed -En "s/^([0-9]+)${2}$/\1.0/p"
  else
    sed -En "s/^([0-9]+\.[0-9]+)${2}$/\1/p"
  fi | sort -V -u | while read -r ver; do
    if [ -n "$ver" ] && version_gte "$ver" "$3"; then echo "$ver"; fi
  done
}

# watch_filter FILTER PRODUCT — the versions on stdin the build's filter keeps (runtime_versions of
# lib/common.sh): lts-even-major, newest-minor, lts (the cycles endoflife.date marks LTS), released
# (the cycles it lists whose release date has come: not a preview or release candidate). Status 1:
# endoflife.date did not answer
watch_filter() {
  local filter="$1" product="$2" versions ver json rc
  versions="$(cat)"
  case "$filter" in
    lts-even-major) filter_nodejs_lts "$versions" ;;
    newest-minor) filter_newest_minor "$versions" ;;
    lts|released)
      for ver in $versions; do
        rc=0
        json="$(watch_eol_json "$product" "$ver")" || rc=$?
        case "$rc" in
          0) ;;
          3) continue ;;
          *) return 1 ;;
        esac
        if [ "$filter" = lts ]; then
          if jq -e '.lts == true or ((.lts | type) == "string")' <<< "$json" >/dev/null; then echo "$ver"; fi
        elif jq -e --arg today "$(watch_today)" '(.releaseDate // "") <= $today' <<< "$json" >/dev/null; then
          echo "$ver"
        fi
      done ;;
    *) if [ -n "$versions" ]; then printf '%s\n' "$versions"; fi ;;
  esac
}

# watch_languages — the language runtimes of RUNTIME_DEFS: new versions, new patch releases, end of
# life
watch_languages() {
  local def runtime repo suffix min_ver depth filter product tags reltags relsrc source_repo source_suffix
  local upstream minors published floating ver minor have eol status date days latest tested
  local ok rc older lifecycle
  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime repo suffix min_ver depth filter product <<< "$def"
    product="${product:-$runtime}"
    echo -e "${BOLD}── ${runtime} ──${NC}"
    if ! published="$(watch_published_tags "$runtime")"; then
      echo -e "  ${RED}✗ the tags of ${REGISTRY}/exec-${runtime} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    floating="$(grep -xE '[0-9]+\.[0-9]+' <<< "$published" | sort -V -u || true)"

    # the upstream: its versions (RunR's major.minor, the build's filter) and its releases X.Y.Z
    ok=1
    reltags=""
    relsrc="$(watch_release_source "$runtime" "$repo" "$suffix")"
    source_repo="${relsrc%%|*}"
    source_suffix="${relsrc#*|}"
    if ! tags="$(watch_tags "$repo")"; then
      echo -e "  ${RED}✗ the tags of ${repo} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      ok=0
    elif [ "$source_repo" = "$repo" ]; then
      reltags="$tags"
    elif ! reltags="$(watch_tags "$source_repo")"; then
      echo -e "  ${RED}✗ the tags of ${source_repo} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      ok=0
    fi
    upstream="$(watch_releases "$runtime" "$source_suffix" <<< "$reltags")"
    minors=""
    if [ "$ok" = 1 ]; then
      minors="$(watch_minors "$depth" "$suffix" "$min_ver" <<< "$tags")"
      if ! minors="$(watch_filter "$filter" "$product" <<< "$minors")"; then
        echo -e "  ${RED}✗ endoflife.date (${product}) cannot be read: the ${filter} versions are unknown${NC}"
        WATCH_FAILED=$((WATCH_FAILED + 1))
        minors=""
      fi
    fi

    for minor in $minors; do
      latest="$(grep -E "^${minor//./\\.}\.[0-9]+$" <<< "$upstream" | sort -V | tail -n 1 || true)"
      [ -n "$latest" ] || continue
      tested="$(patch_tested "$runtime" "$minor")"
      if grep -qxF "$minor" <<< "$floating"; then
        # the upstream version the tag runs: its newest patch tag <full>-r<n>
        have="$(sed -n "s/^\(${minor//./\\.}\.[0-9][0-9]*\)-r[0-9][0-9]*$/\1/p" <<< "$published" | sort -V | tail -n 1)"
        if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$latest" | sort -V | tail -n 1)" != "$have" ]; then
          if [ "$tested" = "$latest" ]; then
            echo -e "  ${GREEN}✓ ${minor}: publishes ${have}; ${latest} is tested (tested-versions), the next publish publishes it${NC}"
            continue
          fi
          watch_report "${runtime}-${latest}" "lang: ${runtime} ${latest} released" \
"A new patch release of ${runtime} ${minor}: **${latest}** (\`${source_repo}:$(watch_release_tag "$runtime" "$latest" "$source_suffix" <<< "$reltags")\`). \`${REGISTRY}/exec-${runtime}:${minor}\` runs ${have}.

The language bot (lang-test.yml) builds \`exec-${runtime}:${minor}\` on it, runs this repository's tests and RunR's e2e on the image, and on success lists ${latest} in \`runtimes/${runtime}/tested-versions\`: the publish workflow then publishes it. Until then the weekly publish holds it.

Reported by ci.sh watch."
        else
          echo -e "  ${GREEN}✓ ${minor}: publishes ${have:-${latest}}, upstream's newest is ${latest}${NC}"
        fi
      else
        rc=0
        status="$(watch_eol "$product" "$minor")" || rc=$?
        if [ "$rc" != 0 ]; then
          echo -e "  ${RED}✗ ${minor}: endoflife.date (${product}) cannot be read${NC}"
          WATCH_FAILED=$((WATCH_FAILED + 1))
          continue
        fi
        [ "${status%%|*}" = eol ] && continue
        if [ "$tested" = "$latest" ]; then
          echo -e "  ${GREEN}✓ ${minor}: ${latest} is tested (tested-versions), not published yet: the next publish publishes it${NC}"
          continue
        fi
        # Bun supports only its newest release: the bot deprecates the published versions below it
        lifecycle=""
        if [ "$filter" = newest-minor ]; then
          older="$(while read -r ver; do if [ -n "$ver" ] && [ "$ver" != "$minor" ] && version_gte "$minor" "$ver"; then echo "$ver"; fi; done <<< "$floating")"
          if [ -n "$older" ]; then
            lifecycle=" It also deprecates ${runtime} $(echo "$older" | paste -sd ' ' - | sed 's/ /, /g') with a sunset date (\`versionDiscovery.lifecycle\` of \`runtimes/${runtime}/runtime.yaml\`): ${runtime} supports only its newest release."
          fi
        fi
        watch_report "${runtime}-${latest}" "lang: ${runtime} ${latest} released" \
"A new version of ${runtime}: **${minor}** (${latest}, \`${repo}:$([ "$depth" = major ] && echo "${minor%%.*}" || echo "$minor")${suffix}\`), not published yet.

The language bot (lang-test.yml) builds \`exec-${runtime}:${minor}\`, runs this repository's tests and RunR's e2e on the image, and on success lists ${latest} in \`runtimes/${runtime}/tested-versions\`: the publish workflow then publishes the new tag, and RunR offers it (as its default, being the newest) once \`executor:sync\` finds it.${lifecycle} Until then the weekly publish holds it.

Reported by ci.sh watch."
      fi
    done

    # the end of life of every published version, whatever the upstream images answered
    for minor in $floating; do
      rc=0
      eol="$(watch_eol "$product" "$minor")" || rc=$?
      if [ "$rc" != 0 ]; then
        echo -e "  ${RED}✗ ${minor}: endoflife.date (${product}) cannot be read${NC}"
        WATCH_FAILED=$((WATCH_FAILED + 1))
        continue
      fi
      status="${eol%%|*}"
      date="${eol#*|}"
      [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
      days="$(watch_days_until "$date")"
      [ "$days" -le "$WATCH_EOL_DAYS" ] || continue
      watch_report "${runtime}-${minor}-eol" "lang: ${runtime} ${minor} end of life ${date}" \
"${runtime} ${minor} $([ "$status" = eol ] && echo "reached its end of life on ${date}" || echo "reaches its end of life on ${date}, in ${days} days") (endoflife.date). \`${REGISTRY}/exec-${runtime}:${minor}\` is published.

- The weekly build stops building it once that date is past; its published tags stay until \`ci.sh eol --prune\`.
- RunR shows the date (\`executor:sync\` reads it from endoflife.date) and its e2e no longer deploys an end-of-life version.
- [ ] Tell the users of ${runtime} ${minor} (RunR's console shows the date), and decide when to prune the tag.

Reported by ci.sh watch."
    done
  done
}

# The tools the language images pin, an ARG of runtimes/<runtime>/Dockerfile, each a Maven Central
# artifact: TOOL|runtime|ARG|groupId:artifactId. A release in the pin's major line is a finding; a
# new major (Maven 4) is a person's change
WATCH_TOOL_DEFS=(
  "maven|java|MAVEN_VERSION|org.apache.maven:apache-maven"
  "maven-dependency-plugin|java|MAVEN_DEPENDENCY_PLUGIN|org.apache.maven.plugins:maven-dependency-plugin"
)

# watch_maven GROUP:ARTIFACT MAJOR — the newest release X.Y.Z of MAJOR on Maven Central (its
# maven-metadata.xml; no alpha, beta or release candidate)
watch_maven() {
  local group="${1%%:*}" artifact="${1#*:}" body
  body="$(watch_get "https://repo.maven.apache.org/maven2/${group//.//}/${artifact}/maven-metadata.xml")" || return 1
  grep -oE '<version>[0-9]+\.[0-9]+\.[0-9]+</version>' <<< "$body" | sed -E 's:</?version>::g' | grep -E "^${2}\." | sort -V | tail -n 1
}

# watch_tools — the tools of the language images against their ARGs
watch_tools() {
  local def tool runtime arg coords pin latest
  for def in "${WATCH_TOOL_DEFS[@]}"; do
    IFS='|' read -r tool runtime arg coords <<< "$def"
    pin="$(sed -n "s/^ARG ${arg}=\([0-9][0-9.]*\)$/\1/p" "$(runtime_dir "$runtime")/Dockerfile" 2>/dev/null | head -n 1)"
    [ -n "$pin" ] || { echo -e "  ${RED}✗ ${tool}: no ARG ${arg} in runtimes/${runtime}/Dockerfile${NC}"; WATCH_FAILED=$((WATCH_FAILED + 1)); continue; }
    latest="$(watch_maven "$coords" "${pin%%.*}")" || latest=""
    if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo -e "  ${RED}✗ ${tool}: its releases on Maven Central (${coords}) cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    if [ "$latest" = "$pin" ] || [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -n 1)" = "$pin" ]; then
      echo -e "  ${GREEN}✓ ${tool}: ${arg}=${pin}, the newest ${pin%%.*}.x is ${latest}${NC}"
      continue
    fi
    watch_report "${tool}-${latest}" "lang: ${tool} ${latest} released" \
"A new release of ${tool}: **${latest}** (Maven Central \`${coords}\`). \`runtimes/${runtime}/Dockerfile\` pins \`ARG ${arg}=${pin}\`.

The language bot (lang-test.yml) moves the ARG$([ "$tool" = maven ] && echo " and the SHA-512 of its download (checked against the one Maven Central publishes)"), builds and smoke-tests every version of \`exec-${runtime}\`, runs this repository's tests and RunR's e2e on the newest one, and on success commits the change: the publish workflow then publishes \`exec-${runtime}\`.

Reported by ci.sh watch."
  done
}

# watch_pypi PACKAGE — the newest release of a PyPI package
watch_pypi() {
  watch_get "https://pypi.org/pypi/$1/json" | jq -r '.info.version // empty'
}

# watch_ml — the frameworks of the ML runtimes against their pins
watch_ml() {
  local def runtime file pkg pin latest
  for def in "pytorch|requirements-torch.txt|torch" "tensorflow|requirements-cpu.txt|tensorflow-cpu"; do
    IFS='|' read -r runtime file pkg <<< "$def"
    pin="$(sed -n "s/^${pkg}==\([0-9][0-9.]*\)$/\1/p" "$(runtime_dir "$runtime")/${file}" | head -n 1)"
    if ! latest="$(watch_pypi "$pkg")" || [ -z "$latest" ] || [ -z "$pin" ]; then
      echo -e "  ${RED}✗ ${runtime}: ${pkg} on PyPI or its pin in ${file} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$latest" = "$pin" ] || [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -n 1)" = "$pin" ]; then
      echo -e "  ${GREEN}✓ ${runtime}: ${pkg} ${pin}, PyPI's newest is ${latest}${NC}"
      continue
    fi
    watch_report "${runtime}-${latest}" "lang: ${runtime} ${latest} released" \
"A new release of ${pkg}: **${latest}** (PyPI). \`runtimes/${runtime}/${file}\` pins ${pin}: \`exec-${runtime}:${pin%.*}\`$([ "${latest%.*}" != "${pin%.*}" ] && echo ", a new tag \`exec-${runtime}:${latest%.*}\`").

The language bot (lang-test.yml) moves the pin, builds and smoke-tests the CPU image, runs RunR's ML e2e case on it (a function doing a tensor operation, once RunR's release has the case) and, on success, commits the pin: the publish workflow publishes the CPU image, the heavy-images workflow the GPU one.

Reported by ci.sh watch."
  done
}

# watch_arg NAME — the value of ARG NAME in the WebAssembly Dockerfiles (the highest, when they differ)
watch_arg() {
  sed -n "s/^ARG $1=\([0-9][0-9.]*\)$/\1/p" "${RUNTIMES_DIR:-${SCRIPT_DIR}/runtimes}"/wasm-*/Dockerfile | sort -V | tail -n 1
}

# watch_github REPO — the tag of the newest release of a GitHub repository
watch_github() {
  watch_get "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty'
}

# watch_wasm — the toolchains of the WebAssembly images against their ARGs
watch_wasm() {
  local def tool arg source pin latest raw
  for def in "spin|SPIN_VERSION|github:spinframework/spin" "tinygo|TINYGO_VERSION|github:tinygo-org/tinygo" \
    "wasi-sdk|WASI_SDK_VERSION|github:WebAssembly/wasi-sdk" "wasm-tools|WASM_TOOLS_VERSION|github:bytecodealliance/wasm-tools" \
    "zig|ZIG_VERSION|zig" "componentize-py|COMPONENTIZE_PY_VERSION|pypi:componentize-py" "spin-sdk|SPIN_SDK_VERSION|pypi:spin-sdk" \
    "rust|RUST_VERSION|hub:library/rust"; do
    IFS='|' read -r tool arg source <<< "$def"
    pin="$(watch_arg "$arg")"
    [ -n "$pin" ] || { echo -e "  ${RED}✗ ${tool}: no ARG ${arg} in runtimes/wasm-*/Dockerfile${NC}"; WATCH_FAILED=$((WATCH_FAILED + 1)); continue; }
    raw=""
    case "$source" in
      github:*) raw="$(watch_github "${source#github:}")" || raw="" ;;
      pypi:*) raw="$(watch_pypi "${source#pypi:}")" || raw="" ;;
      zig) raw="$(watch_get "https://ziglang.org/download/index.json" | jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' | sort -V | tail -n 1)" || raw="" ;;
      hub:*) raw="$(watch_hub_tags "${source#hub:}" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-slim-bookworm$/\1/p' | sort -V | tail -n 1)" || raw="" ;;
    esac
    latest="${raw#v}"
    latest="${latest#wasi-sdk-}"
    if ! [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      echo -e "  ${RED}✗ ${tool}: the newest release cannot be read (${source})${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    if [ "$latest" = "$pin" ] || [ "$(printf '%s\n%s\n' "$pin" "$latest" | sort -V | tail -n 1)" = "$pin" ]; then
      echo -e "  ${GREEN}✓ ${tool}: ${arg}=${pin}, the newest is ${latest}${NC}"
      continue
    fi
    watch_report "${tool}-${latest}" "lang: ${tool} ${latest} released" \
"A new release of ${tool}: **${latest}** (${source}). The WebAssembly images pin \`ARG ${arg}=${pin}\` (\`runtimes/wasm-*/Dockerfile\`).

The language bot (lang-test.yml) moves the ARG with its download checksums$([ "$tool" = rust ] || [ "$tool" = tinygo ] && echo " and the mirrored base image"), builds and smoke-tests the images that have it, and runs RunR's e2e suites that deploy them$([ "$tool" = spin ] && echo " (they also show whether RunR's Spin shim runs what the new Spin CLI builds)"). On success it commits the change: the publish workflow then publishes the images under their version, as before.

Reported by ci.sh watch."
  done
}

cmd_watch() {
  local arg
  WATCH_FOUND=0
  WATCH_FAILED=0
  for arg in "$@"; do
    case "$arg" in
      --report=*) WATCH_REPORT_DIR="${arg#--report=}" ;;
      *) echo -e "${RED}unknown argument: ${arg} (--report=DIR)${NC}"; return 1 ;;
    esac
  done
  echo -e "${BOLD}Upstream releases of the images ($(date -u +%Y-%m-%d))${NC}"
  echo ""
  watch_languages
  echo -e "${BOLD}── Tools of the language images ──${NC}"
  watch_tools
  echo -e "${BOLD}── ML frameworks ──${NC}"
  watch_ml
  echo -e "${BOLD}── WebAssembly toolchains ──${NC}"
  watch_wasm
  echo ""
  echo "${WATCH_FOUND} finding(s)."
  if [ "$WATCH_FAILED" -gt 0 ]; then
    echo -e "${RED}${WATCH_FAILED} upstream(s) could not be read: see above.${NC}"
    return 1
  fi
}
