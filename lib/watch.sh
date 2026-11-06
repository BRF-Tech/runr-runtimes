# ── The upstream releases the images follow ──
# This file is sourced, so it has no shebang.
#
# cmd_watch — `ci.sh watch [--report=DIR]`: every upstream release the images of this repository
# should follow and do not yet, each one a finding. Printed, and with --report written to DIR: a
# Markdown file per finding whose first line is its title. .github/workflows/lang-releases.yml files
# an issue for each title no issue has yet, and .github/workflows/lang-test.yml tests the ones it
# can (the language runtimes and the ML frameworks).
#
#   lang: <runtime> <X.Y.Z> released          python, nodejs, go, php: a new patch release of a
#                                             published version, or a new version (Node.js: the
#                                             newest minor of an even major) not yet published
#   lang: <runtime> <X.Y> end of life <date>  a published version whose end of life
#                                             (endoflife.date) is past or within WATCH_EOL_DAYS
#                                             (default 60); the weekly build already stops
#                                             building it once it is past
#   lang: pytorch|tensorflow <X.Y.Z> released a framework release newer than its pin
#                                             (requirements-torch.txt, requirements-cpu.txt)
#   lang: <tool> <version> released           a toolchain of the WebAssembly images newer than its
#                                             ARG in runtimes/wasm-*/Dockerfile: spin, tinygo,
#                                             wasi-sdk, wasm-tools, zig, componentize-py, spin-sdk,
#                                             rust
#
# The upstreams: Docker Hub's tags of the base images (RUNTIME_DEFS), the published tags of
# ${REGISTRY}/exec-<runtime> (the patch tags <full>-r<n> name the upstream version a tag runs),
# endoflife.date, PyPI, GitHub releases (GH_TOKEN raises GitHub's rate limit) and ziglang.org.
# WATCH_FIXTURES=DIR answers every request from DIR (the tests): the file named after the URL with
# every character but [A-Za-z0-9._-] as _.
# An upstream that does not answer fails the watch, after the others were checked.

WATCH_EOL_DAYS="${WATCH_EOL_DAYS:-60}"
WATCH_HUB="https://hub.docker.com/v2/repositories"

# watch_get URL — the body of URL (or its fixture)
watch_get() {
  local url="$1"
  if [ -n "${WATCH_FIXTURES:-}" ]; then
    local file="${WATCH_FIXTURES}/${url//[^A-Za-z0-9._-]/_}"
    [ -f "$file" ] || return 1
    cat "$file"
    return 0
  fi
  if [[ "$url" == https://api.github.com/* ]] && [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H 'Accept: application/vnd.github+json' "$url"
  else
    curl -fsSL "$url"
  fi
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

# watch_eol RUNTIME VERSION — "eol|DATE", "supported|DATE", "supported|false" or "unknown", as
# check_eol of lib/common.sh asks endoflife.date: the cycle major.minor, else the major (Node.js)
watch_eol() {
  local cycle body
  for cycle in "$2" "${2%%.*}"; do
    body="$(watch_get "${EOL_API}/$1/${cycle}.json" 2>/dev/null | jq -c . 2>/dev/null)" || body=""
    if [ -n "$body" ]; then
      parse_eol_response "$body"
      return 0
    fi
  done
  echo unknown
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
  local today
  today="${WATCH_TODAY:-$(date -u +%Y-%m-%d)}"
  echo $(( ( $(date -u -d "$1" +%s) - $(date -u -d "$today" +%s) ) / 86400 ))
}

# watch_languages — the four language runtimes: new versions, new patch releases, end of life
watch_languages() {
  local def runtime repo suffix min_ver depth hub upstream minors published floating ver minor full have eol status date days latest
  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime repo suffix min_ver depth <<< "$def"
    echo -e "${BOLD}── ${runtime} ──${NC}"
    if ! hub="$(watch_hub_tags "$repo")"; then
      echo -e "  ${RED}✗ Docker Hub's tags of ${repo} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    if ! published="$(watch_published_tags "$runtime")"; then
      echo -e "  ${RED}✗ the tags of ${REGISTRY}/exec-${runtime} cannot be read${NC}"
      WATCH_FAILED=$((WATCH_FAILED + 1))
      continue
    fi
    # the upstream releases X.Y.Z of the base image, at or above the minimum
    upstream="$(sed -n "s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)${suffix}$/\1/p" <<< "$hub" | sort -V -u)"
    minors="$(sed -n "s/^\([0-9][0-9]*\.[0-9][0-9]*\)${suffix}$/\1/p" <<< "$hub" | sort -V -u)"
    minors="$(while read -r ver; do if [ -n "$ver" ] && version_gte "$ver" "$min_ver"; then echo "$ver"; fi; done <<< "$minors")"
    if [ "$runtime" = nodejs ]; then
      minors="$(filter_nodejs_lts "$minors")"
    fi
    floating="$(grep -xE '[0-9]+\.[0-9]+' <<< "$published" | sort -V -u || true)"

    for minor in $minors; do
      latest="$(grep -E "^${minor//./\\.}\.[0-9]+$" <<< "$upstream" | sort -V | tail -n 1 || true)"
      [ -n "$latest" ] || continue
      if grep -qxF "$minor" <<< "$floating"; then
        # the upstream version the tag runs: its newest patch tag <full>-r<n>
        have="$(sed -n "s/^\(${minor//./\\.}\.[0-9][0-9]*\)-r[0-9][0-9]*$/\1/p" <<< "$published" | sort -V | tail -n 1)"
        if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$latest" | sort -V | tail -n 1)" != "$have" ]; then
          watch_report "${runtime}-${latest}" "lang: ${runtime} ${latest} released" \
"A new patch release of ${runtime} ${minor}: **${latest}** (Docker Hub \`${repo}:${latest}${suffix}\`). \`${REGISTRY}/exec-${runtime}:${minor}\` runs ${have}.

The language bot (lang-test.yml) builds \`exec-${runtime}:${minor}\` on it, runs this repository's tests and RunR's e2e on the image, and on success lists ${latest} in \`runtimes/${runtime}/tested-versions\`: the publish workflow then publishes it. Until then the weekly publish holds it.

Reported by ci.sh watch."
        else
          echo -e "  ${GREEN}✓ ${minor}: publishes ${have:-${latest}}, upstream's newest is ${latest}${NC}"
        fi
      else
        status="$(watch_eol "$runtime" "$minor")"
        [ "${status%%|*}" = eol ] && continue
        watch_report "${runtime}-${latest}" "lang: ${runtime} ${latest} released" \
"A new version of ${runtime}: **${minor}** (${latest}, Docker Hub \`${repo}:${minor}${suffix}\`), not published yet.

The language bot (lang-test.yml) builds \`exec-${runtime}:${minor}\`, runs this repository's tests and RunR's e2e on the image, and on success lists ${latest} in \`runtimes/${runtime}/tested-versions\`: the publish workflow then publishes the new tag, and RunR offers it (as its default, being the newest) once \`executor:sync\` finds it. Until then the weekly publish holds it.

Reported by ci.sh watch."
      fi
    done

    for minor in $floating; do
      eol="$(watch_eol "$runtime" "$minor")"
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

The language bot (lang-test.yml) moves the pin, builds and smoke-tests the CPU image and, on success, commits the pin: the publish workflow publishes the CPU image, the heavy-images workflow the GPU one.

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

A person moves it: $([ "$tool" = spin ] && echo "the images carry the Spin CLI of the Spin runtime RunR's shim embeds (BRF-Tech/runr \`runtime/wasm-shim-spin\`), so the shim moves first; then" || echo "a toolchain change needs the new download checksums (and a mirrored base image for rust and tinygo); then") raise the runtimes' \`version\` when installs should get it as a new version, and RunR's \`WASM_RUNTIME_VERSION\` and \`builtin.json\` follow (README.md, How CI publishes). The language bot labels this issue \`needs attention\`.

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
