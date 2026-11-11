#!/usr/bin/env bash
# The language bot (.github/workflows/lang-test.yml): the parts of its run that are more than a
# command, tested by test/lang_bot_test.sh.
#
#   ci/lang-bot.sh plan ISSUES.json [--only=N,…]
#       which issues of lang-releases.yml (`ci.sh watch`) this run tests: JSON {tests: [{issue,
#       kind, runtime, version, full, key, suites, outage}], archive: [{issue, runtime, version,
#       eol}], superseded: [{issue, by}], retrigger: [issue], skipped: [{issue, reason}],
#       attention: []}. kind "language" (the runtimes of RUNTIME_DEFS
#       in lib/common.sh: python, nodejs, go, php, java, dotnet, ruby, bun; version is the
#       major.minor, full the release), "tool" (a tool a language image pins, LANG_TOOL_DEFS:
#       maven, maven-dependency-plugin; version and full its release), "ml" (pytorch, tensorflow:
#       the framework release; version its major.minor, the image's tag) or "wasm" (a toolchain of
#       the WebAssembly images: spin, tinygo, wasi-sdk, wasm-tools, zig, componentize-py, spin-sdk,
#       rust). suites: RunR's e2e suites the test runs. Of several open issues of one image (a
#       language version, a tool, an ML runtime, a toolchain) the newest is tested, the older ones
#       superseded. An end-of-life notice of a language version is for people until its date
#       (skipped: RunR's reminders count down), archived once the date is past (archive: land,
#       ci/lang-bot.sh archive); an issue labelled "lang: passed"
#       is done, one labelled "needs attention" waits unless the run names it (--only), which takes
#       the label off. One labelled "lang: upstream outage" is tested again (outage: true): the run
#       before failed on an upstream server's 5xx alone.
#   ci/lang-bot.sh ml-bump RUNTIME VERSION
#       the framework pin of an ML runtime moved to VERSION in this checkout: torch with the
#       torchvision pip installs next to it, the newest release whose torch requirement admits it
#       (PyPI: torch==X up to torchvision 0.29.0, a range like torch>=2.14.0 since 0.29.1), both
#       built on the CUDA wheel index of the -gpu image (Dockerfile.gpu), tensorflow-cpu with
#       tensorflow[and-cuda]. Exit 4, held: the release has no wheel on that CUDA index (torch, or
#       every torchvision that admits it); the CPU and GPU images stay on their pin together and
#       nobody is asked (the land closes the issue as held). Exit 2: no torchvision admits it
#   ci/lang-bot.sh wasm-bump TOOL VERSION
#       a toolchain of the WebAssembly images moved to VERSION in this checkout: its ARG in every
#       Dockerfile that has it, the SHA256 of its downloads (Spin, wasi-sdk, wasm-tools: of the
#       release assets; zig: ziglang.org's index), the reqs mirror's base image (rust, tinygo:
#       REQS_IMAGES of lib/mirror.sh). Prints JSON {pin, images, mirror}: the images (keys of
#       ci/images.sh) it changes, the reqs images to mirror before they build
#   ci/lang-bot.sh tool-bump TOOL VERSION
#       a tool of a language image moved to VERSION in this checkout: its ARG in
#       runtimes/<image>/Dockerfile and, for a download, the SHA-512 of it, which must be the one
#       published next to it (<download>.sha512). Prints JSON {pin, image, images}
#   ci/lang-bot.sh tested RUNTIME VERSION FULL
#       "VERSION FULL" into runtimes/RUNTIME/tested-versions (the publish gate, lib/patch.sh)
#   ci/lang-bot.sh lifecycle RUNTIME VERSION
#       VERSION deprecated from today (LANG_TODAY) with its sunset LANG_SUNSET_DAYS later (default
#       91: 13 weeks, when RunR sends its first reminder), in versionDiscovery.lifecycle of
#       runtimes/RUNTIME/runtime.yaml; prints "VERSION: deprecated DATE, sunset DATE". Exit 3: the
#       version has an entry already, which stays. The landing runs it for the published versions
#       below a new one of a runtime that supports only its newest release (filter newest-minor:
#       Bun)
#   ci/lang-bot.sh archive RUNTIME VERSION EOL DIGEST
#       the records of a version past its end of life EOL whose image DIGEST the registry keeps as
#       exec-RUNTIME:eol-VERSION (lib/eol.sh eol_archive_image): "VERSION EOL DIGEST" into
#       runtimes/RUNTIME/archived-versions, VERSION out of tested-versions and of a Dockerfile's
#       *_FIXED_RELEASES (exec-php), and {eol: EOL} for it in versionDiscovery.lifecycle of
#       runtime.yaml (RunR keeps the end of life of its projects' version whatever endoflife.date
#       says). The build, the watch and the patch feed leave an archived version out
#   ci/lang-bot.sh catalog RUNR RUNTIME VERSION IMAGE
#       a checkout of BRF-Tech/runr (RUNR) offers RUNTIME at VERSION alone, with IMAGE (its
#       built-in catalog api/resources/runtimes/builtin.json), and no other runtime but Python
#       (EXECUTOR_RUNTIMES of api/.env.docker): RunR's main e2e then deploys its functions on the
#       candidate image. Exit 3: RunR's catalog has no RUNTIME (a release before the runtime's)
#   ci/lang-bot.sh check-e2e RESULTS.md RUNTIME VERSION [--ml]
#       the e2e's results show the xaas cases of RUNTIME at VERSION (--ml: its ML case), and none
#       of them failed
#   ci/lang-bot.sh upstream LOG
#       the lines (at most 5) of a test job's LOG that show an outage, not the release's fault:
#       an upstream server's HTTP 500, 502, 503 or 504 of a public https URL on a line that says
#       it failed (helm's "failed to fetch https://…: 504 Gateway Timeout", the "download failed:
#       URL (HTTP 504)" of lib/fetch.sh and of the WebAssembly Dockerfiles), curl's "(22) The
#       requested URL returned error: 504" in an image build's RUN step, or the registry inside
#       RunR's e2e cluster that did not answer (a private address's /v2/ with "unable to complete
#       operation after N attempts", "synchronization failed", "connection refused" or "i/o
#       timeout"). Any other local or private address is the candidate's, never an outage. When
#       the log has RunR's e2e summary ("── Failures ──"), every failed case there must be one:
#       a case that failed for its own reason (a compile error, its own output) makes it none.
#       Exit 1: none
#   ci/lang-bot.sh runr-pins RUNR RUNTIME
#       what a checkout of RunR (its last release) pins of RUNTIME's versions: "discovered" (exit 0:
#       RunR finds them in the registry, nothing to move), or the pins (exit 2: a person moves them);
#       exit 3: that release has no RUNTIME yet
#   ci/lang-bot.sh land DIR RUN_URL
#       after the test jobs (DIR/tests.json, their results in DIR/results/<artifact>/, RunR's pins
#       in DIR/pins/<runtime>): every green test is committed on top of main, one after the other
#       (the version into tested-versions, or the ML, tool or toolchain pin), and pushed as
#       `git push origin HEAD:refs/heads/main`, a fast-forward, as LANG_BOT_NAME <LANG_BOT_EMAIL>
#       with the trailer "RunR-Lang-Bot: <name> <version>". A new version of a runtime that
#       supports only its newest release also deprecates the published ones below it (lifecycle).
#       A green test waits for the next run when main changed its images since the tested commit by
#       a commit that is not one of the bot's (the trailer). When its patch no longer applies
#       because this run's landings moved the lines around it, the same bump is made again on the
#       new main and committed only when it changes the very lines the tested patch changed; else
#       it waits for the next run. A red test is labelled "needs attention" with the end of the
#       failed jobs' logs, unless each of its failures is an outage (their result's upstream file:
#       lang-bot.sh upstream): then it is labelled "lang: upstream outage" and the next run tests
#       it again; a second outage in a row is "needs attention". Each test lands in a process of
#       its own: one that fails is reported ("needs attention", with its log) and the others still
#       land. A test its bump held (ml-bump exit 4: build status "held") is closed as not planned
#       with the reason, nobody asked. Then every version of DIR/archive.json past its end of life
#       is archived, each in a process of its own (archive-one): the registry (the image as
#       eol-<version>, the floating tag gone), its records on main (archive), the issue closed;
#       LANG_ARCHIVE_IMAGE replaces the registry step (the tests). DIR/actions: what the issues
#       get, one action per line (comment ISSUE FILE, label ISSUE LABEL, unlabel ISSUE LABEL, close
#       ISSUE [REASON]), and at the end one publish IMAGES for the main the run left: every image a
#       landed test or an archive touched, once
#
# Needs bash, jq, curl (ml-bump, wasm-bump, tool-bump), sha256sum, sha512sum and GNU sed, sort and
# date.
set -euo pipefail

# the checkout the bot reads and writes: its own, or LANG_BOT_ROOT (land runs a copy of the bot
# taken when it started on the checkout it moves along main)
ROOT="${LANG_BOT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# the trailer of the bot's commits on main: "RunR-Lang-Bot: <name> <version>"
LANG_TRAILER="RunR-Lang-Bot"
PASSED_LABEL="${LANG_PASSED_LABEL:-lang: passed}"
ATTENTION_LABEL="${LANG_ATTENTION_LABEL:-needs attention}"
OUTAGE_LABEL="${LANG_OUTAGE_LABEL:-lang: upstream outage}"
# the language runtimes: RUNTIME_DEFS of lib/common.sh, as ci.sh builds them
SCRIPT_DIR="$ROOT"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
LANGUAGES=" $(runtime_ids) "
ML=" pytorch tensorflow "

# A tool a language image pins: TOOL|image (a language runtime)|ARG|checksum ARG (- none)|download,
# {V} the version (- none)|RunR suites. A download's SHA-512 is checked against <download>.sha512.
# The suite deploys the image's newest version: RunR's main e2e.
LANG_TOOL_DEFS=(
  "maven|java|MAVEN_VERSION|MAVEN_SHA512|https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/{V}/apache-maven-{V}-bin.tar.gz|test"
  "maven-dependency-plugin|java|MAVEN_DEPENDENCY_PLUGIN|-|-|test"
)

# A toolchain of the WebAssembly images: TOOL|ARG|SHA256 ARG prefix (- none)|download amd64|arm64|
# reqs image (- none)|RunR suites. {V} is the version. The suites deploy the images it changes:
# test-wasm the Rust and JavaScript examples (wasm-rust, wasm-js), test-images wasm-exec's C and
# Q; RunR's e2e has no case of wasm-go and wasm-python, whose images only their smoke test checks.
TOOLCHAIN_DEFS=(
  "spin|SPIN_VERSION|SPIN_SHA256|https://github.com/spinframework/spin/releases/download/v{V}/spin-v{V}-static-linux-amd64.tar.gz|https://github.com/spinframework/spin/releases/download/v{V}/spin-v{V}-static-linux-aarch64.tar.gz|-|test-wasm test-images"
  "wasi-sdk|WASI_SDK_VERSION|WASI_SDK_SHA256|https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{V}/wasi-sdk-{V}.0-x86_64-linux.tar.gz|https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{V}/wasi-sdk-{V}.0-arm64-linux.tar.gz|-|test-images"
  "wasm-tools|WASM_TOOLS_VERSION|WASM_TOOLS_SHA256|https://github.com/bytecodealliance/wasm-tools/releases/download/v{V}/wasm-tools-{V}-x86_64-linux.tar.gz|https://github.com/bytecodealliance/wasm-tools/releases/download/v{V}/wasm-tools-{V}-aarch64-linux.tar.gz|-|test-images"
  "zig|ZIG_VERSION|ZIG_SHA256|zig:x86_64-linux|zig:aarch64-linux|-|test-images"
  "componentize-py|COMPONENTIZE_PY_VERSION|-|-|-|-|"
  "spin-sdk|SPIN_SDK_VERSION|-|-|-|-|"
  "tinygo|TINYGO_VERSION|-|-|-|tinygo:{V}=tinygo/tinygo:{V}|test-images"
  "rust|RUST_VERSION|-|-|-|rust:{V}-slim-bookworm=rust:{V}-slim-bookworm|test-wasm"
)

newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }
# vcmp A B — -1, 0 or 1 as PEP 440 orders two releases (2.15 = 2.15.0)
vcmp() {
  local a="$1" b="$2"
  while [ "$(tr -cd . <<< "$a" | wc -c)" -lt 3 ]; do a="${a}.0"; done
  while [ "$(tr -cd . <<< "$b" | wc -c)" -lt 3 ]; do b="${b}.0"; done
  if [ "$a" = "$b" ]; then echo 0
  elif [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" = "$a" ]; then echo -1
  else echo 1
  fi
}
# admits SPEC RELEASE — a version specifier of a Requires-Dist (">=2.14.0", "==2.15.0",
# ">=2.14,<2.17", "~=2.14.0", "==2.15.*") admits RELEASE (X.Y.Z)
admits() {
  local re='^(===|==|!=|~=|>=|<=|>|<)([0-9][0-9.]*(\.\*)?)$' clause op want c
  local -a clauses
  IFS=',' read -ra clauses <<< "$1"
  [ "${#clauses[@]}" -gt 0 ] || return 1
  for clause in "${clauses[@]}"; do
    [[ "$clause" =~ $re ]] || return 1
    op="${BASH_REMATCH[1]}" want="${BASH_REMATCH[2]}"
    if [[ "$want" == *'.*' ]]; then
      case "$op" in
        ==) [[ "${2}." == "${want%'*'}"* ]] ;;
        !=) [[ "${2}." != "${want%'*'}"* ]] ;;
        *) false ;;
      esac || return 1
      continue
    fi
    c="$(vcmp "$2" "$want")"
    case "$op" in
      ==|===) [ "$c" = 0 ] ;;
      !=) [ "$c" != 0 ] ;;
      '>=') [ "$c" != -1 ] ;;
      '<=') [ "$c" != 1 ] ;;
      '>') [ "$c" = 1 ] ;;
      '<') [ "$c" = -1 ] ;;
      '~=') [ "$c" != -1 ] && [[ "${2}." == "${want%.*}."* ]] ;;
    esac || return 1
  done
}
json_list() { if [ "$#" -gt 0 ]; then printf '%s\n' "$@" | jq -s -c .; else echo '[]'; fi; }
json_strings() { if [ "$#" -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -s -c .; else echo '[]'; fi; }
toolchain() { local d; for d in "${TOOLCHAIN_DEFS[@]}"; do [ "${d%%|*}" = "$1" ] && { echo "$d"; return 0; }; done; return 1; }
lang_tool() { local d; for d in "${LANG_TOOL_DEFS[@]}"; do [ "${d%%|*}" = "$1" ] && { echo "$d"; return 0; }; done; return 1; }
# filter_of RUNTIME — the version filter of a language runtime (RUNTIME_DEFS)
filter_of() { local def; def="$(runtime_def "$1")" || return 0; IFS='|' read -r _ _ _ _ _ def _ <<< "$def"; echo "$def"; }

cmd_plan() {
  local issues="${1:?usage: lang-bot.sh plan ISSUES.json [--only=N,…]}" only="" arg
  for arg in "${@:2}"; do
    case "$arg" in
      --only=*) only="${arg#--only=}" ;;
      *) echo "unknown argument: ${arg}" >&2; return 1 ;;
    esac
  done
  [[ "$only" =~ ^[0-9,]*$ ]] || { echo "--only: issue numbers separated by commas" >&2; return 1; }
  only=" ${only//,/ } "
  local number title labels runtime version kind key full suites def outage date today
  local -A newest=() newest_issue=()
  local rows=() tests=() superseded=() retrigger=() skipped=() archive=()
  today="${LANG_TODAY:-$(date -u +%Y-%m-%d)}"
  while IFS=$'\t' read -r number title labels; do
    [ -n "$number" ] || continue
    # an end of life: a notice for people until its date (RunR's reminders count down), archived
    # by the bot once the date is past
    if [[ "$title" =~ ^lang:\ ([a-z0-9-]+)\ ([0-9]+\.[0-9]+)\ end\ of\ life\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] \
      && [[ "$LANGUAGES" == *" ${BASH_REMATCH[1]} "* ]] && [[ "${BASH_REMATCH[3]}" < "$today" ]]; then
      if [ "$only" != "  " ] && [[ "$only" != *" ${number} "* ]]; then
        skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "not named in this run"}')")
      else
        archive+=("$(jq -nc --argjson i "$number" --arg r "${BASH_REMATCH[1]}" --arg v "${BASH_REMATCH[2]}" --arg d "${BASH_REMATCH[3]}" \
          '{issue: $i, runtime: $r, version: $v, eol: $d}')")
      fi
      continue
    fi
    if [[ "$title" =~ ^lang:\ [a-z0-9-]+\ [0-9.]+\ end\ of\ life ]]; then
      skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "an end-of-life notice, for people until its date"}')")
      continue
    fi
    [[ "$title" =~ ^lang:\ ([a-z0-9-]+)\ ([0-9]+(\.[0-9]+)*)\ released$ ]] || continue
    runtime="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    if [[ "$labels" == *"|${PASSED_LABEL}|"* ]]; then
      skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "passed already"}')")
      continue
    fi
    full="$version"
    if [[ "$LANGUAGES" == *" ${runtime} "* ]]; then
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "a language release is X.Y.Z"}')"); continue; }
      kind=language
      version="${full%.*}"
      key="${runtime}-${version}"
      suites="test"
    elif [[ "$ML" == *" ${runtime} "* ]]; then
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "a framework release is X.Y.Z"}')"); continue; }
      kind=ml
      version="${full%.*}"
      key="$runtime"
      suites="test-ml"
    elif def="$(lang_tool "$runtime")"; then
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "a tool release is X.Y.Z"}')"); continue; }
      kind=tool
      IFS='|' read -r _ key _ <<< "$def"
      key="${key}-${runtime}"
      suites="${def##*|}"
      suites="${suites:--}"
    elif def="$(toolchain "$runtime")"; then
      kind=wasm
      key="wasm-${runtime}"
      # none: "-" (read with a tab IFS joins empty fields)
      suites="${def##*|}"
      suites="${suites:--}"
    else
      skipped+=("$(jq -nc --argjson i "$number" --arg r "$runtime" '{issue: $i, reason: ("the bot does not know " + $r)}')")
      continue
    fi
    rows+=("${number}"$'\t'"${kind}"$'\t'"${runtime}"$'\t'"${version}"$'\t'"${full}"$'\t'"${key}"$'\t'"${suites}"$'\t'"${labels}")
    if [ -z "${newest[$key]:-}" ] || newer "$full" "${newest[$key]}" \
      || { [ "$full" = "${newest[$key]}" ] && [ "$number" -gt "${newest_issue[$key]}" ]; }; then
      newest[$key]="$full"
      newest_issue[$key]="$number"
    fi
  done < <(jq -r '.[] | [.number, .title, ("|" + ([.labels[]?.name] | join("|")) + "|")] | @tsv' "$issues")

  local row
  for row in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r number kind runtime version full key suites labels <<< "$row"
    if [ "$number" != "${newest_issue[$key]}" ]; then
      superseded+=("$(jq -nc --argjson i "$number" --argjson b "${newest_issue[$key]}" --arg f "${newest[$key]}" '{issue: $i, by: $b, version: $f}')")
      continue
    fi
    if [ "$only" != "  " ] && [[ "$only" != *" ${number} "* ]]; then
      skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "not named in this run"}')")
      continue
    fi
    if [[ "$labels" == *"|${ATTENTION_LABEL}|"* ]]; then
      if [[ "$only" != *" ${number} "* ]]; then
        skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "waits for a person; run the workflow with this issue number to test it again"}')")
        continue
      fi
      retrigger+=("$number")
    fi
    # the run before hit an upstream outage (land): this run is its second chance
    outage=false
    [[ "$labels" != *"|${OUTAGE_LABEL}|"* ]] || outage=true
    tests+=("$(jq -nc --argjson i "$number" --arg k "$kind" --arg r "$runtime" --arg v "$version" --arg f "$full" --arg key "$key" --arg s "$suites" --argjson o "$outage" \
      '{issue: $i, kind: $k, runtime: $r, version: $v, full: $f, key: $key, suites: ($s | split(" ") | map(select(. != "" and . != "-"))), outage: $o}')")
  done
  jq -nc --argjson tests "$(json_list ${tests[@]+"${tests[@]}"})" --argjson superseded "$(json_list ${superseded[@]+"${superseded[@]}"})" \
    --argjson retrigger "$(json_list ${retrigger[@]+"${retrigger[@]}"})" --argjson skipped "$(json_list ${skipped[@]+"${skipped[@]}"})" \
    --argjson archive "$(json_list ${archive[@]+"${archive[@]}"})" \
    '{tests: ($tests | sort_by(.key)), archive: ($archive | sort_by(.runtime, .version)), superseded: $superseded, retrigger: $retrigger, attention: [], skipped: $skipped}'
}

# the watch's fetch (lib/watch.sh: WATCH_FIXTURES answers in the tests)
watch_lib() {
  # shellcheck source=../lib/common.sh
  source "${ROOT}/lib/common.sh"
  # shellcheck source=../lib/fetch.sh
  source "${ROOT}/lib/fetch.sh"
  # shellcheck source=../lib/watch.sh
  source "${ROOT}/lib/watch.sh"
}

cmd_ml_bump() {
  local runtime="${1:?usage: lang-bot.sh ml-bump RUNTIME VERSION}" version="${2:?}" dir vision
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${version}: not a release X.Y.Z" >&2; return 1; }
  dir="${ROOT}/runtimes/${runtime}"
  watch_lib
  case "$runtime" in
    pytorch)
      # the -gpu image installs the same pins from its CUDA wheel index (Dockerfile.gpu), which the
      # bot does not build: a release without a wheel there is held (exit 4), the CPU and GPU images
      # stay on their pin together, and a newer release (or patch) with the wheel moves them
      local index cuda="" torch_wheels="" vision_wheels="" current
      current="$(sed -n 's/^torch==//p' "${dir}/requirements-torch.txt" | head -n 1)"
      index="$(grep -oE 'https://download\.pytorch\.org/whl/cu[0-9]+' "${dir}/Dockerfile.gpu" 2>/dev/null | head -n 1)"
      if [ -n "$index" ]; then
        cuda="${index##*/}"
        torch_wheels="$(watch_get "${index}/torch/")" || { echo "could not read ${index}/torch/" >&2; return 2; }
        vision_wheels="$(watch_get "${index}/torchvision/")" || { echo "could not read ${index}/torchvision/" >&2; return 2; }
        grep -qF -e "torch-${version}%2B${cuda}-" -e "torch-${version}+${cuda}-" <<< "$torch_wheels" || {
          echo "held: no ${cuda} wheel of torch ${version} (${index}/torch/, the -gpu image's index); CPU and GPU stay on torch ${current}" >&2
          return 4
        }
      fi
      # the torchvision pip installs next to this torch: the newest release whose torch requirement
      # (its Requires-Dist) admits it, an exact pin (torch==2.14.0, up to 0.29.0) or a range
      # (torch>=2.14.0 since 0.29.1, which builds on torch's stable ABI), with a build on the -gpu
      # image's CUDA index too
      vision=""
      local v spec admitted=""
      for v in $(watch_get "https://pypi.org/pypi/torchvision/json" | jq -r '.releases | keys[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r | head -n 12); do
        spec="$(watch_get "https://pypi.org/pypi/torchvision/${v}/json" | jq -r '
          [.info.requires_dist[]? | select(test("^torch *[(=<>!~]") and (test("extra *==") | not))
            | split(";")[0] | gsub("[ ()]"; "") | ltrimstr("torch")] | first // empty')" || spec=""
        [ -n "$spec" ] && admits "$spec" "$version" || continue
        admitted="${admitted:+${admitted}, }${v}"
        if [ -z "$cuda" ] || grep -qF -e "torchvision-${v}%2B${cuda}-" -e "torchvision-${v}+${cuda}-" <<< "$vision_wheels"; then
          vision="$v"
          break
        fi
      done
      [ -n "$admitted" ] || { echo "no torchvision release on PyPI admits torch ${version} (its torch requirement)" >&2; return 2; }
      [ -n "$vision" ] || { echo "held: no ${cuda} wheel of a torchvision that admits torch ${version} (${admitted}; ${index}/torchvision/, the -gpu image's index); CPU and GPU stay on torch ${current}" >&2; return 4; }
      sed -i -E "s/^torch==[0-9.]+$/torch==${version}/; s/^torchvision==[0-9.]+$/torchvision==${vision}/" "${dir}/requirements-torch.txt"
      echo "torch ${version}, torchvision ${vision}" ;;
    tensorflow)
      sed -i -E "s/^tensorflow-cpu==[0-9.]+$/tensorflow-cpu==${version}/" "${dir}/requirements-cpu.txt"
      sed -i -E "s/^tensorflow\[and-cuda\]==[0-9.]+$/tensorflow[and-cuda]==${version}/" "${dir}/requirements-cuda.txt"
      echo "tensorflow ${version} (CPU and CUDA)" ;;
    *) echo "${runtime}: not an ML runtime (pytorch, tensorflow)" >&2; return 1 ;;
  esac
}

# sha_of SOURCE VERSION — the SHA256 of a download (its URL, {V} the version) or zig's index entry
# (zig:ARCH)
sha_of() {
  local source="${1//\{V\}/$2}" sum
  case "$source" in
    zig:*)
      sum="$(watch_get "https://ziglang.org/download/index.json" | jq -r --arg v "$2" --arg a "${source#zig:}" '.[$v][$a].shasum // empty')" ;;
    *)
      sum="$(watch_sha256 "$source")" ;;
  esac
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "no SHA256 of ${source}" >&2; return 1; }
  echo "$sum"
}

cmd_wasm_bump() {
  local tool="${1:?usage: lang-bot.sh wasm-bump TOOL VERSION}" version="${2:?}" def arg sha amd64 arm64 reqs file old images=() mirror=() sum_amd64="" sum_arm64=""
  def="$(toolchain "$tool")" || { echo "${tool}: no toolchain of the WebAssembly images" >&2; return 1; }
  IFS='|' read -r _ arg sha amd64 arm64 reqs _ <<< "$def"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "${version}: not a release" >&2; return 1; }
  watch_lib
  if [ "$sha" != "-" ]; then
    sum_amd64="$(sha_of "$amd64" "$version")" || return 2
    sum_arm64="$(sha_of "$arm64" "$version")" || return 2
  fi
  old=""
  for file in "${ROOT}"/runtimes/wasm-*/Dockerfile; do
    grep -qE "^ARG ${arg}=" "$file" || continue
    old="$(sed -n "s/^ARG ${arg}=//p" "$file" | head -n 1)"
    sed -i -E "s/^ARG ${arg}=.*/ARG ${arg}=${version}/" "$file"
    if [ "$sha" != "-" ]; then
      sed -i -E "s/^ARG ${sha}_AMD64=.*/ARG ${sha}_AMD64=${sum_amd64}/; s/^ARG ${sha}_ARM64=.*/ARG ${sha}_ARM64=${sum_arm64}/" "$file"
    fi
    images+=("$(basename "$(dirname "$file")")")
  done
  [ "${#images[@]}" -gt 0 ] || { echo "no Dockerfile of runtimes/wasm-* has ARG ${arg}" >&2; return 1; }
  if [ "$reqs" != "-" ]; then
    # the base image of the reqs mirror: its REQS_IMAGES line follows the ARG (the old line goes)
    local name="${reqs%%=*}" source="${reqs#*=}" was="${reqs%%=*}"
    name="${name//\{V\}/$version}"
    source="${source//\{V\}/$version}"
    was="${was//\{V\}/$old}"
    grep -qF "\"${was}|" "${ROOT}/lib/mirror.sh" || { echo "no REQS_IMAGES line ${was} in lib/mirror.sh" >&2; return 1; }
    sed -i "s#^\(  *\)\"${was}|[^\"]*\"#\1\"${name}|${source}\"#" "${ROOT}/lib/mirror.sh"
    mirror+=("$name")
  fi
  jq -nc --arg pin "${tool} ${version} (was ${old})" --argjson images "$(json_strings "${images[@]}")" --argjson mirror "$(json_strings ${mirror[@]+"${mirror[@]}"})" \
    '{pin: $pin, images: $images, mirror: $mirror}'
}

cmd_tool_bump() {
  local tool="${1:?usage: lang-bot.sh tool-bump TOOL VERSION}" version="${2:?}" def image arg sha url file old sum="" published
  def="$(lang_tool "$tool")" || { echo "${tool}: no tool of a language image" >&2; return 1; }
  IFS='|' read -r _ image arg sha url _ <<< "$def"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${version}: not a release X.Y.Z" >&2; return 1; }
  file="${ROOT}/runtimes/${image}/Dockerfile"
  old="$(sed -n "s/^ARG ${arg}=//p" "$file" 2>/dev/null | head -n 1)"
  [ -n "$old" ] || { echo "no ARG ${arg} in runtimes/${image}/Dockerfile" >&2; return 1; }
  watch_lib
  if [ "$sha" != "-" ]; then
    url="${url//\{V\}/$version}"
    sum="$(watch_digest sha512 "$url")" || sum=""
    [[ "$sum" =~ ^[0-9a-f]{128}$ ]] || { echo "no SHA-512 of ${url}" >&2; return 2; }
    published="$(watch_get "${url}.sha512" | awk '{ print $1; exit }')" || published=""
    [ "$sum" = "$published" ] || { echo "${url}: its SHA-512 is not the one published next to it (${published:-none})" >&2; return 2; }
  fi
  sed -i -E "s/^ARG ${arg}=.*/ARG ${arg}=${version}/" "$file"
  if [ "$sha" != "-" ]; then
    sed -i -E "s/^ARG ${sha}=.*/ARG ${sha}=${sum}/" "$file"
  fi
  jq -nc --arg pin "${tool} ${version} (was ${old})" --arg image "$image" '{pin: $pin, image: $image, images: [$image]}'
}

cmd_lifecycle() {
  local runtime="${1:?usage: lang-bot.sh lifecycle RUNTIME VERSION}" version="${2:?}" file today sunset out rc=0
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "${version}: not a version X.Y" >&2; return 1; }
  file="${ROOT}/runtimes/${runtime}/runtime.yaml"
  grep -q '^versionDiscovery:' "$file" 2>/dev/null || { echo "runtimes/${runtime}/runtime.yaml has no versionDiscovery" >&2; return 1; }
  today="${LANG_TODAY:-$(date -u +%Y-%m-%d)}"
  sunset="$(date -u -d "${today} + ${LANG_SUNSET_DAYS:-91} days" +%Y-%m-%d)"
  out="$(mktemp)"
  # the entry at the end of versionDiscovery.lifecycle (the block made when it has none)
  awk -v v="$version" -v entry="    \"${version}\": {deprecated: \"${today}\", sunset: \"${sunset}\"}" '
    function add() { if (!done) { if (!lc) print "  lifecycle:"; print entry; done = 1 } }
    state == "lc" && !/^    / { add(); state = /^[^ #]/ ? "" : "vd" }
    state == "vd" && /^[^ #]/ { add(); state = "" }
    /^versionDiscovery:/ { state = "vd"; print; next }
    state == "vd" && /^  lifecycle:/ { lc = 1; state = "lc"; print; next }
    state == "lc" && index($0, "    \"" v "\":") == 1 { done = 1; kept = 1 }
    { print }
    END { if (state != "") add(); if (kept) exit 3 }
  ' "$file" > "$out" || rc=$?
  if [ "$rc" = 3 ]; then
    rm -f -- "$out"
    echo "${version}: kept, runtimes/${runtime}/runtime.yaml has its lifecycle"
    return 3
  fi
  [ "$rc" = 0 ] || { rm -f -- "$out"; return 1; }
  cat "$out" > "$file"
  rm -f -- "$out"
  echo "${version}: deprecated ${today}, sunset ${sunset}"
}

cmd_archive() {
  local runtime="${1:?usage: lang-bot.sh archive RUNTIME VERSION EOL DIGEST}" version="${2:?}" eol="${3:?}" digest="${4:?}"
  local dir file out
  [[ "$LANGUAGES" == *" ${runtime} "* ]] || { echo "${runtime}: not a language runtime" >&2; return 1; }
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "${version}: not a version X.Y" >&2; return 1; }
  [[ "$eol" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "${eol}: not a date" >&2; return 1; }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "${digest}: not a digest" >&2; return 1; }
  dir="${ROOT}/runtimes/${runtime}"
  [ -f "${dir}/runtime.yaml" ] || { echo "no runtimes/${runtime}/runtime.yaml" >&2; return 1; }
  out="$(mktemp)"

  # the record: archived-versions, one line per version, the header first
  file="${dir}/archived-versions"
  if [ ! -f "$file" ]; then
    cat > "$file" <<EOF
# The versions of this runtime past their end of life that the language bot archived
# (ci/lang-bot.sh archive, .github/workflows/lang-test.yml): "<major.minor> <end of life> <digest>".
# The image stays as ghcr.io/brf-tech/runr/exec-${runtime}:${ARCHIVE_TAG_PREFIX}<major.minor> with its
# patch tags; its floating tag is gone, so RunR's discovery no longer offers it (its projects keep
# the version, locked as end-of-life) and the build, the watch and the patch feed leave it out.
EOF
  fi
  awk -v v="$version" '/^#/ || NF == 0 || $1 != v' "$file" > "$out"
  echo "${version} ${eol} ${digest}" >> "$out"
  { grep '^#' "$out" || true; grep -v '^#' "$out" | grep -v '^$' | sort -V || true; } > "$file"

  # tested-versions: no current version any more
  file="${dir}/tested-versions"
  if [ -f "$file" ]; then
    awk -v v="$version" '/^#/ || NF == 0 || $1 != v' "$file" > "$out"
    cat "$out" > "$file"
  fi

  # a Dockerfile's fixed releases of its versions (exec-php's PHP_FIXED_RELEASES): not this one
  file="${dir}/Dockerfile"
  if [ -f "$file" ] && grep -qE '^ARG [A-Z_]*_FIXED_RELEASES=' "$file"; then
    awk -v v="${version}." '
      /^ARG [A-Z_]*_FIXED_RELEASES="/ {
        name = $0; sub(/=.*/, "", name)
        list = $0; sub(/^[^"]*"/, "", list); sub(/".*$/, "", list)
        n = split(list, w, " "); kept = ""
        for (i = 1; i <= n; i++) if (index(w[i], v) != 1) kept = kept (kept == "" ? "" : " ") w[i]
        print name "=\"" kept "\""; next
      }
      { print }
    ' "$file" > "$out"
    cat "$out" > "$file"
  fi

  # RunR: the version's end of life from the manifest (versionDiscovery.lifecycle), whatever
  # endoflife.date answers (RuntimeLifecycle::apply sets it on the version's executor_images row)
  file="${dir}/runtime.yaml"
  awk -v v="$version" -v d="$eol" '
    function add() { if (!done) { if (!lc) print "  lifecycle:"; print "    \"" v "\": {eol: \"" d "\"}"; done = 1 } }
    state == "lc" && !/^    / { add(); state = /^[^ #]/ ? "" : "vd" }
    state == "vd" && /^[^ #]/ { add(); state = "" }
    /^versionDiscovery:/ { state = "vd"; print; next }
    state == "vd" && /^  lifecycle:/ { lc = 1; state = "lc"; print; next }
    state == "lc" && index($0, "    \"" v "\":") == 1 {
      done = 1
      line = $0
      if (line ~ /eol: *"[^"]*"/) sub(/eol: *"[^"]*"/, "eol: \"" d "\"", line)
      else if (line ~ /\{ *\}/) sub(/\{ *\}/, "{eol: \"" d "\"}", line)
      else sub(/\} *$/, ", eol: \"" d "\"}", line)
      print line; next
    }
    { print }
    END { if (state != "") add() }
  ' "$file" > "$out"
  grep -q '^versionDiscovery:' "$out" || { rm -f -- "$out"; echo "runtimes/${runtime}/runtime.yaml has no versionDiscovery" >&2; return 1; }
  cat "$out" > "$file"
  rm -f -- "$out"
  echo "${runtime} ${version}: archived (${digest}, end of life ${eol})"
}

cmd_tested() {
  local runtime="${1:?usage: lang-bot.sh tested RUNTIME VERSION FULL}" version="${2:?}" full="${3:?}" file out
  [[ "$LANGUAGES" == *" ${runtime} "* ]] || { echo "${runtime}: not a language runtime" >&2; return 1; }
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] && [[ "$full" == "${version}."* ]] || { echo "${full} is no release of ${version}" >&2; return 1; }
  file="${ROOT}/runtimes/${runtime}/tested-versions"
  [ -f "$file" ] || { echo "no ${file}" >&2; return 1; }
  out="$(mktemp)"
  awk -v v="$version" -v f="$full" '
    /^#/ || NF == 0 { print; next }
    $1 == v { if (!done) print v " " f; done = 1; next }
    { print }
    END { if (!done) print v " " f }
  ' "$file" > "$out"
  # the versions in order, the comments first
  { grep '^#' "$out" || true; grep -v '^#' "$out" | grep -v '^$' | sort -V || true; } > "$file"
  rm -f -- "$out"
}

cmd_catalog() {
  local runr="${1:?usage: lang-bot.sh catalog RUNR RUNTIME VERSION IMAGE}" runtime="${2:?}" version="${3:?}" image="${4:?}"
  local catalog="${runr}/api/resources/runtimes/builtin.json" env="${runr}/api/.env.docker" out
  [ -f "$catalog" ] || { echo "no ${catalog}" >&2; return 1; }
  jq -e --arg r "$runtime" '.runtimes | (if type == "array" then .[] else .[] end) | select(.id == $r)' "$catalog" >/dev/null \
    || { echo "${catalog} has no runtime ${runtime}" >&2; return 3; }
  out="$(mktemp)"
  jq --arg r "$runtime" --arg v "$version" --arg i "$image" '
    .runtimes |= (if type == "array"
      then map(if .id == $r then (del(.versionDiscovery) | .versions = [{version: $v, image: $i, default: true}]) else . end)
      else with_entries(if .value.id == $r then .value |= (del(.versionDiscovery) | .versions = [{version: $v, image: $i, default: true}]) else . end)
      end)' "$catalog" > "$out"
  cat "$out" > "$catalog"
  rm -f -- "$out"
  # the runtimes offered: this one, and Python, which the e2e's runtime plugin cases (rt-*) run
  # on: the xaas and faas cases run on the candidate and, for another runtime, on the published
  # Python
  local offered="python"
  [ "$runtime" = python ] || offered="python,${runtime}"
  if grep -q '^EXECUTOR_RUNTIMES=' "$env" 2>/dev/null; then
    sed -i "s/^EXECUTOR_RUNTIMES=.*/EXECUTOR_RUNTIMES=${offered}/" "$env"
  else
    echo "EXECUTOR_RUNTIMES=${offered}" >> "$env"
  fi
}

cmd_check_e2e() {
  local results="${1:?usage: lang-bot.sh check-e2e RESULTS.md RUNTIME VERSION [--ml]}" runtime="${2:?}" version="${3:?}" name count=0 failed
  local v="${version//./\\.}" names="http schedule queue" prefix=xaas
  if [ "${4:-}" = --ml ]; then names="http"; prefix=ml; fi
  [ -f "$results" ] || { echo "no e2e results (${results})" >&2; return 1; }
  for name in $names; do
    if grep -qE "^\| ${prefix}-${runtime}-${v}-${name} \|" "$results"; then count=$((count + 1)); fi
  done
  [ "$count" = "$(wc -w <<< "$names")" ] || { echo "the e2e ran ${count} of the ${prefix} cases of ${runtime} ${version}: it did not deploy the candidate image" >&2; return 1; }
  failed="$(awk '/^## Failures/ { on = 1; next } on && /^## / { exit } on && NF' "$results" | grep -E "\*\*(xaas|faas|ml)-${runtime}-${v}-" || true)"
  [ -z "$failed" ] || { echo "failed on the candidate image:"; echo "$failed"; return 1; }
  echo "the ${prefix} cases of ${runtime} ${version} ran on the candidate image and passed"
}

cmd_upstream() {
  local log="${1:?usage: lang-bot.sh upstream LOG}"
  [ -f "$log" ] || return 1
  awk '
    # a host of the internet, not the candidate (a local or private address, a cluster name)
    function public(line,   host) {
      while (match(line, /https:\/\/[A-Za-z0-9.-]+/)) {
        host = tolower(substr(line, RSTART + 8, RLENGTH - 8))
        line = substr(line, RSTART + RLENGTH)
        if (host !~ /\./) continue
        if (host ~ /^(localhost|127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/) continue
        if (host ~ /(\.local|\.localhost|\.internal|\.svc|\.nip\.io|\.sslip\.io)$/) continue
        return 1
      }
      return 0
    }
    # an outage: a 5xx of an upstream server, the curl (22) 5xx of a RUN step, the registry of the
    # e2e cluster
    function outage(s) {
      if (s ~ /(^|[^0-9A-Za-z])50[0234]([^0-9A-Za-z]|$)|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out/ &&
        s ~ /[Ff]ail|[Ee]rror|ERROR/ && public(s)) return 1
      if (s ~ /^(#[0-9]+ )?[0-9]+\.[0-9]+ curl: \(22\) The requested URL returned error: 50[0234]/) return 1
      if (s ~ /https?:\/\/(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9.]+(:[0-9]+)?\/v2\// &&
        s ~ /unable to complete operation after [0-9]+ attempts|synchronization failed|connection refused|i\/o timeout/) return 1
      return 0
    }
    # RunR e2e summary: its failed cases
    index($0, "── Failures ──") { infail = 1; next }
    infail && index($0, "── ") { infail = 0 }
    infail && index($0, "✗") { cases++; if (outage($0)) { if (c < 5) failing[++c] = $0 } else own = 1; next }
    n < 5 && outage($0) { found[++n] = $0 }
    END {
      if (cases) {
        if (own) exit 1
        for (i = 1; i <= c; i++) print failing[i]
        exit 0
      }
      for (i = 1; i <= n; i++) print found[i]
      exit n ? 0 : 1
    }
  ' "$log"
}

cmd_runr_pins() {
  local runr="${1:?usage: lang-bot.sh runr-pins RUNR RUNTIME}" runtime="${2:?}" catalog entry pins
  catalog="${runr}/api/resources/runtimes/builtin.json"
  [ -f "$catalog" ] || { echo "no ${catalog}" >&2; return 1; }
  entry="$(jq -c --arg r "$runtime" '.runtimes | (if type == "array" then .[] else .[] end) | select(.id == $r)' "$catalog")"
  [ -n "$entry" ] || { echo "no ${runtime} runtime"; return 3; }
  pins="$(grep -nE "exec-${runtime}:[0-9]" "${runr}/runtime/lib/runtime-images.sh" "${runr}/api/config/executor.php" 2>/dev/null || true)"
  if [ -n "$entry" ] && jq -e '.versionDiscovery and (.versions // [] | length == 0)' <<< "$entry" >/dev/null && [ -z "$pins" ]; then
    echo "discovered"
    return 0
  fi
  echo "${entry:+builtin.json: $(jq -c '{versions}' <<< "$entry")}${pins:+ ${pins}}"
  return 2
}

# status DIR NAME — the status of a test job's result artifact (none: it did not report)
status() { cat "$1/results/$2/status" 2>/dev/null || echo "no result"; }

# tail_of DIR NAME — the end of a test job's log, for a comment: never an empty block
tail_of() {
  local file="$1/results/$2/tail.txt"
  echo '```'
  if [ ! -f "$file" ]; then
    echo "no log: the job did not get that far (the run has its whole log)"
  elif [ -z "$(tr -d '[:space:]' < "$file")" ]; then
    echo "the log is empty: the step that failed printed nothing into it (the run has the job's whole log)"
  else
    tail -n 40 "$file"
  fi
  echo '```'
}

# upstream_of DIR NAME — the lines of a failed job's log that show an upstream outage (the job's
# result: lang-bot.sh upstream), none when it failed for another reason
upstream_of() { cat "$1/results/$2/upstream" 2>/dev/null || true; }

# push_main — HEAD onto main as a fast-forward, never forced: the bot's one push
push_main() {
  local rc=0
  git push -q origin HEAD:refs/heads/main || rc=$?
  return "$rc"
}

# changes — the lines the diff on stdin changes, each with its file, sorted: what a bump changed,
# whatever the lines around it
changes() {
  awk '
    /^diff --git / { hdr = 1; next }
    hdr && /^\+\+\+ / { file = $2; next }
    /^@@/ { hdr = 0; next }
    !hdr && /^[+-]/ { print file "\t" $0 }
  ' | LC_ALL=C sort
}

# bump_again KIND RUNTIME FULL — the bump of a tool, ML or toolchain test made again on this
# checkout, as the build job made it (lang-bot.sh tool-bump, ml-bump, wasm-bump)
bump_again() {
  case "$1" in
    tool) bash "$LANG_BOT_SELF" tool-bump "$2" "$3" ;;
    ml) bash "$LANG_BOT_SELF" ml-bump "$2" "$3" ;;
    wasm) bash "$LANG_BOT_SELF" wasm-bump "$2" "$3" ;;
    *) return 1 ;;
  esac
}

cmd_land() {
  local dir="${1:?usage: lang-bot.sh land DIR RUN_URL}" run_url="${2:?}" n i entry issue name rc log what list
  mkdir -p "$dir/comments" "$dir/actions.d" "$dir/bot"
  : > "$dir/actions"
  : > "$dir/publish.list"
  [ -f "$dir/tests.json" ] || echo '[]' > "$dir/tests.json"
  [ -f "$dir/archive.json" ] || echo '[]' > "$dir/archive.json"
  # the bot as it started: the checkout moves along main while it lands
  cp "${BASH_SOURCE[0]}" "$dir/bot/lang-bot.sh"
  export LANG_BOT_ROOT="$ROOT" LANG_BOT_SELF="$dir/bot/lang-bot.sh"
  # the green tests first, then the versions past their end of life, each in a process of its own
  for what in land archive; do
    list="$dir/tests.json"
    [ "$what" = land ] || list="$dir/archive.json"
    n="$(jq length "$list")"
    for ((i = 0; i < n; i++)); do
      entry="$(jq -c ".[$i]" "$list")"
      issue="$(jq -r .issue <<< "$entry")"
      name="$(jq -r '"\(.runtime) \(.full // .version)"' <<< "$entry")"
      log="$dir/${what}-${i}.log"
      rm -f -- "$dir/actions.d/${what}-${i}"
      rc=0
      bash "$LANG_BOT_SELF" "${what}-one" "$dir" "$i" "$run_url" > "$log" 2>&1 || rc=$?
      cat "$log"
      if [ "$rc" = 0 ] && [ -f "$dir/actions.d/${what}-${i}" ]; then
        # its issue's actions now; its images join the one publish after the loop
        grep -v $'^publish\t' "$dir/actions.d/${what}-${i}" >> "$dir/actions" || true
        sed -n $'s/^publish\t//p' "$dir/actions.d/${what}-${i}" | tr ',' '\n' >> "$dir/publish.list"
        continue
      fi
      # it failed in the middle: the issue hears of it, the checkout is clean for the next one
      git reset -q --hard 2>/dev/null || true
      git clean -fdq 2>/dev/null || true
      {
        echo "**Needs attention: the bot could not $([ "$what" = land ] && echo land || echo archive) ${name}** (\`ci/lang-bot.sh ${what}\`, exit ${rc}). Nothing of it was committed; the other issues of the run were handled and reported."
        echo ""
        echo '```'
        tail -n 30 "$log"
        echo '```'
        echo ""
        echo "Run: ${run_url}. Fix the bot (or do it by hand), then run **Actions → Language tests → Run workflow** with this issue's number."
      } > "$dir/comments/${issue}.md"
      printf 'label\t%s\t%s\ncomment\t%s\t%s\n' "$issue" "$ATTENTION_LABEL" "$issue" "$dir/comments/${issue}.md" >> "$dir/actions"
    done
  done
  # one publish for main as the run left it, with every image a landed test (or an archive) touched:
  # the publish workflow's concurrency would cancel or queue one dispatch per test of the same commit
  local images
  images="$(awk 'NF && !seen[$0]++' "$dir/publish.list" 2>/dev/null | paste -sd , -)"
  [ -z "$images" ] || printf 'publish\t%s\n' "$images" >> "$dir/actions"
}

# archive-one DIR INDEX RUN_URL — the archive of one version of DIR/archive.json past its end of
# life (cmd_land runs it), its actions in DIR/actions.d/archive-INDEX: the registry first (the image
# as eol-<version>, the floating tag gone: eol_archive_image of lib/eol.sh, or LANG_ARCHIVE_IMAGE,
# a command the tests answer with), then the records on main (archive), the issue closed
cmd_archive_one() {
  local dir="${1:?usage: lang-bot.sh archive-one DIR INDEX RUN_URL}" i="${2:?}" run_url="${3:?}"
  local entry issue runtime version eol digest actions comment sha body patches repo
  entry="$(jq -c ".[$i]" "$dir/archive.json")"
  issue="$(jq -r .issue <<< "$entry")"; runtime="$(jq -r .runtime <<< "$entry")"
  version="$(jq -r .version <<< "$entry")"; eol="$(jq -r .eol <<< "$entry")"
  actions="$dir/actions.d/archive-${i}"
  comment="$dir/comments/${issue}.md"
  repo="${REGISTRY}/exec-${runtime}"
  : > "$actions.tmp"

  # the registry: the image the floating tag named, kept as eol-<version>; the floating tag gone
  if [ -n "${LANG_ARCHIVE_IMAGE:-}" ]; then
    digest="$($LANG_ARCHIVE_IMAGE "$runtime" "$version")"
  else
    # shellcheck source=../lib/registry.sh
    source "${ROOT}/lib/registry.sh"
    # shellcheck source=../lib/eol.sh
    source "${ROOT}/lib/eol.sh"
    digest="$(eol_archive_image "$runtime" "$version")"
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "the registry named no digest (${digest:-none})" >&2; return 1; }
  patches="$(crane ls "$repo" 2>/dev/null | grep -E "^${version//./\\.}\.[0-9A-Za-z.]*-r[0-9]+$" | sort -V | paste -sd ' ' - || true)"

  # the records on main: archived-versions, tested-versions, the lifecycle, a fixed release
  git fetch -q origin main
  git reset -q --hard
  git checkout -q --detach origin/main
  bash "$LANG_BOT_SELF" archive "$runtime" "$version" "$eol" "$digest"
  git add -A -- "runtimes/${runtime}"
  if git diff --cached --quiet; then
    echo "**Archived: ${runtime} ${version}** was archived already: \`${repo}:${ARCHIVE_TAG_PREFIX}${version}\` is ${digest}, and main has its records (${run_url})." > "$comment"
    printf 'comment\t%s\t%s\nclose\t%s\n' "$issue" "$comment" "$issue" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  body="${runtime} ${version} reached its end of life on ${eol}. The image its floating tag named, ${digest}, stays as ${repo}:${ARCHIVE_TAG_PREFIX}${version} with its patch tags; the floating tag ${version} is gone, so RunR's discovery no longer offers the version (its projects keep it, locked as end-of-life; running deployments keep their image by digest). Recorded in runtimes/${runtime}/archived-versions, out of tested-versions, and its end of life in versionDiscovery.lifecycle: ${run_url}."
  body="$(fold -s -w 98 <<< "${body}" | sed 's/ *$//')"
  GIT_AUTHOR_NAME="${LANG_BOT_NAME:?}" GIT_AUTHOR_EMAIL="${LANG_BOT_EMAIL:?}" GIT_COMMITTER_NAME="$LANG_BOT_NAME" GIT_COMMITTER_EMAIL="$LANG_BOT_EMAIL" \
    git commit -q -F - <<EOF
chore(${runtime}): ${runtime} ${version} archived, end of life ${eol}

${body}

${LANG_TRAILER}: ${runtime} ${version}
EOF
  # a fast-forward of main, never forced
  if ! push_main; then
    echo "**${runtime} ${version} is archived in the registry (\`${repo}:${ARCHIVE_TAG_PREFIX}${version}\`, ${digest}), but main moved while the bot recorded it.** The next run records it (${run_url})." > "$comment"
    printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  sha="$(git rev-parse HEAD)"
  {
    echo "**Archived: ${runtime} ${version}** (end of life ${eol}). Nothing more to do here."
    echo ""
    echo "- the image: \`${repo}:${ARCHIVE_TAG_PREFIX}${version}\` is ${digest}, the image \`${repo}:${version}\` named${patches:+; its patch tags stay (${patches// /, })}"
    echo "- the floating tag \`${version}\` is gone: RunR's \`executor:sync\` no longer offers the version (it leaves the picker, as after its end of life already); its projects keep it, locked as end-of-life, and running deployments keep their image by digest"
    echo "- main ${sha}: \`runtimes/${runtime}/archived-versions\`, out of \`tested-versions\`, its end of life in \`versionDiscovery.lifecycle\` of \`runtime.yaml\`; the build and the watch leave it out"
    echo "- the publish run the bot starts drops its patches from the signed patch feed and publishes the runtime catalog"
    echo ""
    echo "Run: ${run_url}."
  } > "$comment"
  printf 'comment\t%s\t%s\nclose\t%s\npublish\t%s\n' "$issue" "$comment" "$issue" "$runtime" >> "$actions.tmp"
  mv "$actions.tmp" "$actions"
}

# land-one DIR INDEX RUN_URL — the landing of one test of DIR/tests.json (cmd_land runs it), its
# actions in DIR/actions.d/land-INDEX
cmd_land_one() {
  local dir="${1:?usage: lang-bot.sh land-one DIR INDEX RUN_URL}" i="${2:?}" run_url="${3:?}" test issue kind runtime version full key build
  local tested comment name subject sha pins rc suite suites failed paths images publish lines note body older deprecated outage retest
  local actions patch foreign again
  test="$(jq -c ".[$i]" "$dir/tests.json")"
  actions="$dir/actions.d/land-${i}"
  : > "$actions.tmp"
  issue="$(jq -r .issue <<< "$test")"; kind="$(jq -r .kind <<< "$test")"; runtime="$(jq -r .runtime <<< "$test")"
  version="$(jq -r .version <<< "$test")"; full="$(jq -r .full <<< "$test")"; key="$(jq -r .key <<< "$test")"
  suites="$(jq -r '.suites // [] | join(" ")' <<< "$test")"
  comment="$dir/comments/${issue}.md"
  build="$(status "$dir" "lang-result-${key}-build")"
  # held by its bump (an ML release without a wheel for the -gpu image's CUDA, ml-bump exit 4):
  # closed, nobody asked, the pins stay; a newer release with the wheel is a new issue
  if [ "$build" = held ]; then
    note="$(head -n 1 "$dir/results/lang-result-${key}-build/held" 2>/dev/null || true)"
    {
      echo "**Held: ${runtime} ${full}** — ${note:-held by its bump}."
      echo ""
      echo "Nothing was published or committed, and nobody needs to act: the CPU and GPU images stay on their pin together. The bot keeps watching: a newer release, or a newer patch of the current version, that has the wheel is bumped and tested as usual."
      echo ""
      echo "Run: ${run_url}."
    } > "$comment"
    printf 'comment\t%s\t%s\nclose\t%s\tnot planned\n' "$issue" "$comment" "$issue" >> "$actions.tmp"
    [ "$(jq -r '.outage // false' <<< "$test")" != true ] || printf 'unlabel\t%s\t%s\n' "$issue" "$OUTAGE_LABEL" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  # every result: "build" and one per RunR suite; a suite RunR's release does not have yet is skipped
  failed=""
  [ "$build" = success ] || failed="build"
  lines="- build, smoke test and this repository's tests: ${build}"
  # the images the test built: the runtime's, or a tool's or toolchain's (tool-bump and wasm-bump
  # list them)
  images="$runtime"
  if [ "$kind" = wasm ] || [ "$kind" = tool ]; then
    images="$(cat "$dir/results/lang-result-${key}-build/images" 2>/dev/null || true)"
    if [ -z "$images" ] && [ "$build" = success ]; then
      failed="build"
      lines="${lines} (it named no image it built)"
    fi
  fi
  [ -z "$(upstream_of "$dir" "lang-result-${key}-build")" ] || lines="${lines} (an outage)"
  for suite in $suites; do
    name="lang-result-${key}-e2e-${suite}"
    rc="$(status "$dir" "$name")"
    note=""
    [ "$rc" != skipped ] || note=" ($(cat "$dir/results/${name}/reason" 2>/dev/null || echo "no reason given"))"
    if [ "$build" != success ]; then
      # the e2e job deploys the build's candidate: there was none
      lines="${lines}"$'\n'"- RunR's \`ci.sh ${suite}\` on the candidate: not run (the build failed)"
      continue
    fi
    [ ! -f "$dir/results/${name}/retried" ] || note="${note} (run once more after an outage)"
    [ -z "$(upstream_of "$dir" "$name")" ] || note="${note} (an outage)"
    lines="${lines}"$'\n'"- RunR's \`ci.sh ${suite}\` on the candidate: ${rc}${note}"
    case "$rc" in success|skipped) ;; *) failed="${failed:+${failed} }e2e-${suite}" ;; esac
  done
  [ -n "$suites" ] || lines="${lines}"$'\n'"- RunR's e2e: none of its cases deploys this image (the smoke test checks it)"
  # every failure an outage (lang-bot.sh upstream): not the release's fault
  outage=""
  if [ -n "$failed" ]; then
    outage=1
    for name in $failed; do
      [ -n "$(upstream_of "$dir" "lang-result-${key}-${name}")" ] || { outage=""; break; }
    done
  fi
  retest="$(jq -r '.outage // false' <<< "$test")"
  if [ -n "$outage" ] && [ "$retest" != true ]; then
    # nobody is asked: the next run tests it again (plan: the label is no reason to wait)
    {
      echo "**Outage: ${runtime} ${full} was not tested to the end.** Something the test depends on failed: an upstream server's HTTP 5xx, or the registry inside RunR's e2e cluster (below). That is not this release's fault. Nothing was published or committed, and nobody needs to act: the next run of the language bot tests it again (label \`${OUTAGE_LABEL}\`); a second outage in a row asks a person."
      echo ""
      echo "$lines"
      for name in $failed; do
        echo ""
        echo "<details><summary>${name}: the outage</summary>"
        echo ""
        echo '```'
        upstream_of "$dir" "lang-result-${key}-${name}"
        echo '```'
        echo ""
        echo "</details>"
      done
      echo ""
      echo "Run: ${run_url}."
    } > "$comment"
    printf 'label\t%s\t%s\ncomment\t%s\t%s\n' "$issue" "$OUTAGE_LABEL" "$issue" "$comment" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  if [ -n "$failed" ]; then
    {
      if [ -n "$outage" ]; then
        echo "**Needs attention: ${runtime} ${full} hit an outage the second run in a row.** An upstream server or the registry inside RunR's e2e cluster failed again: a person looks whether it is down for longer. Nothing was published or committed: the weekly publish holds it."
      else
        echo "**Needs attention: ${runtime} ${full} failed.** Nothing was published or committed: the weekly publish holds it."
      fi
      echo ""
      echo "$lines"
      for name in $failed; do
        [ -d "$dir/results/lang-result-${key}-${name}" ] || continue
        echo ""
        echo "<details><summary>${name}: what failed</summary>"
        echo ""
        tail_of "$dir" "lang-result-${key}-${name}"
        echo ""
        echo "</details>"
      done
      echo ""
      echo "Run: ${run_url}. Fix it (or decide the version waits), then run **Actions → Language tests → Run workflow** with this issue's number; a newer release supersedes this issue by itself."
    } > "$comment"
    printf 'label\t%s\t%s\ncomment\t%s\t%s\n' "$issue" "$ATTENTION_LABEL" "$issue" "$comment" >> "$actions.tmp"
    [ "$retest" != true ] || printf 'unlabel\t%s\t%s\n' "$issue" "$OUTAGE_LABEL" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  [ "$retest" != true ] || printf 'unlabel\t%s\t%s\n' "$issue" "$OUTAGE_LABEL" >> "$actions.tmp"

  # green: the change on top of main as it is now, after the landings before it in this run
  tested="$(cat "$dir/results/lang-result-${key}-build/sha")"
  [ -n "$tested" ] || { echo "no tested commit in the build's result" >&2; return 1; }
  paths=()
  for name in $images; do paths+=("runtimes/${name}/"); done
  git fetch -q origin main
  git reset -q --hard
  git checkout -q --detach origin/main
  # main changed the images since the tested commit, other than by the bot's own landings (its
  # trailer): the next run tests it on that main
  foreign="$(git log --format="%h %(trailers:key=${LANG_TRAILER},valueonly,separator=%x2C)" "${tested}..HEAD" -- "${paths[@]}" ':(exclude)runtimes/*/tested-versions' \
    | awk 'NF == 1 { print $1 }' | paste -sd ' ' -)"
  if [ -n "$foreign" ]; then
    echo "**${runtime} ${full} passed on ${tested:0:12}, but main changed \`${paths[*]}\` since then (${foreign}).** Nothing was committed: the next run tests it again on the new main (${run_url})." > "$comment"
    printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  deprecated=""
  again=""
  case "$kind" in
    language)
      bash "$LANG_BOT_SELF" tested "$runtime" "$version" "$full"
      # a version that had no tag yet is a new one
      if ! grep -qxF "$version" "$dir/results/lang-result-${key}-build/published" 2>/dev/null; then
        subject="feat(${runtime}): ${runtime} ${version} (${full})"
        # a runtime that supports only its newest release (Bun): the published versions below it
        # are deprecated, with a sunset date
        if [ "$(filter_of "$runtime")" = newest-minor ]; then
          for older in $(grep -xE '[0-9]+\.[0-9]+' "$dir/results/lang-result-${key}-build/published" 2>/dev/null | sort -V); do
            if [ "$older" != "$version" ] && version_gte "$version" "$older" && note="$(bash "$LANG_BOT_SELF" lifecycle "$runtime" "$older")"; then
              deprecated="${deprecated:+${deprecated}; }${note}"
            fi
          done
        fi
      else
        subject="fix(${runtime}): ${runtime} ${full}"
      fi ;;
    tool|ml|wasm)
      patch="$dir/results/lang-result-${key}-build/pin.patch"
      if git apply --check "$patch" 2>/dev/null; then
        git apply "$patch"
      else
        # the landings before it moved the lines around its change: the same bump on this main,
        # committed only when it changes what the tested patch changed, line for line
        again="1"
        if ! bump_again "$kind" "$runtime" "$full" > "$dir/bump-again-${i}.out" 2>&1; then
          git reset -q --hard
          {
            echo "**${runtime} ${full} passed, but its change does not apply to main any more, and its bump does not run on the new main.** Nothing was committed: the next run tests it again on the new main (${run_url})."
            echo ""
            echo '```'
            tail -n 20 "$dir/bump-again-${i}.out"
            echo '```'
          } > "$comment"
          printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$actions.tmp"
          mv "$actions.tmp" "$actions"
          return 0
        fi
        if ! git diff --quiet && [ "$(changes < "$patch")" != "$(git diff | changes)" ]; then
          {
            echo "**${runtime} ${full} passed, but main moved under its change: made again on the new main, it is not the change the bot tested.** Nothing was committed: the next run tests it again on the new main (${run_url})."
            echo ""
            echo "<details><summary>tested and made again</summary>"
            echo ""
            echo '```diff'
            changes < "$patch" | cut -f 2-
            echo '```'
            echo ""
            echo '```diff'
            git diff | changes | cut -f 2-
            echo '```'
            echo ""
            echo "</details>"
          } > "$comment"
          git reset -q --hard
          printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$actions.tmp"
          mv "$actions.tmp" "$actions"
          return 0
        fi
      fi
      case "$kind" in
        tool) subject="fix(${images%% *}): " ;;
        ml) subject="fix(${runtime}): " ;;
        wasm) subject="fix(wasm): " ;;
      esac
      subject="${subject}$(cat "$dir/results/lang-result-${key}-build/pin" 2>/dev/null || echo "${runtime} ${full}")" ;;
  esac
  if git diff --quiet; then
    echo "**Nothing to do: main has ${runtime} ${full} already** (${run_url})." > "$comment"
    printf 'comment\t%s\t%s\nclose\t%s\n' "$issue" "$comment" "$issue" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  body="The language bot built ${images// /, } on ${runtime} ${full}, smoke-tested them and ran this repository's tests before this commit"
  [ -z "$suites" ] || body="${body}, and RunR's e2e (${suites// /, }) on the candidate images"
  body="${body}: ${run_url}."
  [ -z "$again" ] || body="${body} Made again on main after the bot's landings before it in the run: the same lines as the tested change, only the lines around them moved."
  [ -z "$deprecated" ] || body="${body} ${runtime} supports only its newest release: versionDiscovery.lifecycle deprecates ${deprecated}."
  body="$(fold -s -w 98 <<< "${body}" | sed 's/ *$//')"
  GIT_AUTHOR_NAME="${LANG_BOT_NAME:?}" GIT_AUTHOR_EMAIL="${LANG_BOT_EMAIL:?}" GIT_COMMITTER_NAME="$LANG_BOT_NAME" GIT_COMMITTER_EMAIL="$LANG_BOT_EMAIL" \
    git commit -q -a -F - <<EOF
${subject}

${body}

${LANG_TRAILER}: ${runtime} ${full}
EOF
  # a fast-forward of main, never forced; a main that moved meanwhile is left as it is
  rc=0
  push_main || rc=$?
  if [ "$rc" != 0 ]; then
    echo "**${runtime} ${full} passed, but main moved while the bot committed it.** Nothing was pushed: the next run tests it again (${run_url})." > "$comment"
    printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$actions.tmp"
    mv "$actions.tmp" "$actions"
    return 0
  fi
  sha="$(git rev-parse HEAD)"
  pins="$(cat "$dir/pins/${runtime}" 2>/dev/null || echo "not checked")"
  publish="${images// /,}"
  note=""
  [ "$kind" != ml ] || note=" (the -gpu image with the next heavy-images run)"
  {
    echo "**Passed: ${runtime} ${full}** is on main as ${sha}; the publish workflow publishes ${images// /, } now${note}."
    echo ""
    echo "$lines"
    echo "- RunR: ${pins}"
    [ -z "$again" ] || echo "- made again on main after this run's landings before it: the same lines as the tested change"
    [ -z "$deprecated" ] || echo "- ${runtime} supports only its newest release: \`runtimes/${runtime}/runtime.yaml\` deprecates ${deprecated} (RunR reads it from the runtime catalog)"
    echo ""
    echo "Run: ${run_url}."
  } > "$comment"
  printf 'label\t%s\t%s\ncomment\t%s\t%s\nclose\t%s\npublish\t%s\n' "$issue" "$PASSED_LABEL" "$issue" "$comment" "$issue" "$publish" >> "$actions.tmp"
  mv "$actions.tmp" "$actions"
}

command="${1:-}"
shift || true
case "$command" in
  plan) cmd_plan "$@" ;;
  ml-bump) cmd_ml_bump "$@" ;;
  wasm-bump) cmd_wasm_bump "$@" ;;
  tool-bump) cmd_tool_bump "$@" ;;
  tested) cmd_tested "$@" ;;
  archive) cmd_archive "$@" ;;
  archive-one) cmd_archive_one "$@" ;;
  lifecycle) cmd_lifecycle "$@" ;;
  catalog) cmd_catalog "$@" ;;
  check-e2e) cmd_check_e2e "$@" ;;
  upstream) cmd_upstream "$@" ;;
  runr-pins) cmd_runr_pins "$@" ;;
  land) cmd_land "$@" ;;
  land-one) cmd_land_one "$@" ;;
  *) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
