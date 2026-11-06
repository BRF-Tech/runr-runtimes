#!/usr/bin/env bash
# The language bot (.github/workflows/lang-test.yml): the parts of its run that are more than a
# command, tested by test/lang_bot_test.sh.
#
#   ci/lang-bot.sh plan ISSUES.json [--only=N,…]
#       which issues of lang-releases.yml (`ci.sh watch`) this run tests: JSON {tests: [{issue,
#       kind, runtime, version, full, key}], superseded: [{issue, by}], retrigger: [issue],
#       attention: [{issue, reason}], skipped: [{issue, reason}]}. kind "language" (python, nodejs,
#       go, php: version is the major.minor, full the release) or "ml" (pytorch, tensorflow:
#       version is the framework release). Of several open issues of one image (a language
#       version, an ML runtime) the newest is tested, the older ones superseded. A WebAssembly
#       toolchain needs a person (labelled); an end-of-life notice is for people (skipped). An
#       issue labelled "lang: passed" is done, one labelled "needs attention" waits unless the run
#       names it (--only), which takes the label off.
#   ci/lang-bot.sh ml-bump RUNTIME VERSION
#       the framework pin of an ML runtime moved to VERSION in this checkout: torch with the
#       torchvision release that requires it (PyPI), tensorflow-cpu with tensorflow[and-cuda]
#   ci/lang-bot.sh tested RUNTIME VERSION FULL
#       "VERSION FULL" into runtimes/RUNTIME/tested-versions (the publish gate, lib/patch.sh)
#   ci/lang-bot.sh catalog RUNR RUNTIME VERSION IMAGE
#       a checkout of BRF-Tech/runr (RUNR) offers RUNTIME at VERSION alone, with IMAGE (its
#       built-in catalog api/resources/runtimes/builtin.json), and no other runtime but Python
#       (EXECUTOR_RUNTIMES of api/.env.docker): RunR's main e2e then deploys its functions on the
#       candidate image
#   ci/lang-bot.sh check-e2e RESULTS.md RUNTIME VERSION
#       the e2e's results show the xaas cases of RUNTIME at VERSION, and none of them failed
#   ci/lang-bot.sh runr-pins RUNR RUNTIME
#       what a checkout of RunR's next pins of RUNTIME's versions: "discovered" (exit 0: RunR finds
#       them in the registry, nothing to move), or the pins (exit 2: a person moves them)
#   ci/lang-bot.sh land DIR RUN_URL
#       after the test jobs (DIR/tests.json, their results in DIR/results/<artifact>/, RunR's pins
#       in DIR/pins/<runtime>): every green test is committed on top of main (the version into
#       tested-versions, or the ML pin) when main did not change the runtime since the tested
#       commit, and pushed as `git push origin HEAD:refs/heads/main`, a fast-forward (the bot's
#       identity LANG_BOT_NAME, LANG_BOT_EMAIL). DIR/actions: what the issues get, one action per
#       line (comment ISSUE FILE, label ISSUE LABEL, close ISSUE, publish RUNTIME)
#
# Needs bash, jq, curl (ml-bump) and GNU sed and sort.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED_LABEL="${LANG_PASSED_LABEL:-lang: passed}"
ATTENTION_LABEL="${LANG_ATTENTION_LABEL:-needs attention}"
LANGUAGES=" python nodejs go php "
ML=" pytorch tensorflow "
TOOLCHAINS=" spin tinygo wasi-sdk wasm-tools zig componentize-py spin-sdk rust "

newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }
json_list() { if [ "$#" -gt 0 ]; then printf '%s\n' "$@" | jq -s -c .; else echo '[]'; fi; }

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
  local number title labels runtime version kind key full
  local -A newest=() newest_issue=()
  local rows=() tests=() superseded=() retrigger=() attention=() skipped=()
  while IFS=$'\t' read -r number title labels; do
    [ -n "$number" ] || continue
    if [[ "$title" =~ ^lang:\ [a-z0-9-]+\ [0-9.]+\ end\ of\ life ]]; then
      skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "an end-of-life notice, for people"}')")
      continue
    fi
    [[ "$title" =~ ^lang:\ ([a-z0-9-]+)\ ([0-9]+(\.[0-9]+)*)\ released$ ]] || continue
    runtime="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    if [[ "$labels" == *"|${PASSED_LABEL}|"* ]]; then
      skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "passed already"}')")
      continue
    fi
    if [[ "$TOOLCHAINS" == *" ${runtime} "* ]]; then
      [[ "$labels" == *"|${ATTENTION_LABEL}|"* ]] || attention+=("$(jq -nc --argjson i "$number" --arg t "$runtime" \
        '{issue: $i, reason: ("a toolchain of the WebAssembly images (" + $t + "): its checksums, mirrored bases and, for Spin, RunR'"'"'s shim move with it, which a person does (the issue says how)")}')")
      continue
    fi
    if [[ "$LANGUAGES" == *" ${runtime} "* ]]; then
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { skipped+=("$(jq -nc --argjson i "$number" '{issue: $i, reason: "a language release is X.Y.Z"}')"); continue; }
      kind=language
      full="$version"
      version="${full%.*}"
      key="${runtime}-${version}"
    elif [[ "$ML" == *" ${runtime} "* ]]; then
      kind=ml
      full="$version"
      key="$runtime"
    else
      skipped+=("$(jq -nc --argjson i "$number" --arg r "$runtime" '{issue: $i, reason: ("the bot does not know " + $r)}')")
      continue
    fi
    rows+=("${number}"$'\t'"${kind}"$'\t'"${runtime}"$'\t'"${version}"$'\t'"${full}"$'\t'"${key}"$'\t'"${labels}")
    if [ -z "${newest[$key]:-}" ] || newer "$full" "${newest[$key]}" \
      || { [ "$full" = "${newest[$key]}" ] && [ "$number" -gt "${newest_issue[$key]}" ]; }; then
      newest[$key]="$full"
      newest_issue[$key]="$number"
    fi
  done < <(jq -r '.[] | [.number, .title, ("|" + ([.labels[]?.name] | join("|")) + "|")] | @tsv' "$issues")

  local row
  for row in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r number kind runtime version full key labels <<< "$row"
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
    tests+=("$(jq -nc --argjson i "$number" --arg k "$kind" --arg r "$runtime" --arg v "$version" --arg f "$full" --arg key "$key" \
      '{issue: $i, kind: $k, runtime: $r, version: $v, full: $f, key: $key}')")
  done
  jq -nc --argjson tests "$(json_list ${tests[@]+"${tests[@]}"})" --argjson superseded "$(json_list ${superseded[@]+"${superseded[@]}"})" \
    --argjson retrigger "$(json_list ${retrigger[@]+"${retrigger[@]}"})" --argjson attention "$(json_list ${attention[@]+"${attention[@]}"})" \
    --argjson skipped "$(json_list ${skipped[@]+"${skipped[@]}"})" \
    '{tests: ($tests | sort_by(.key)), superseded: $superseded, retrigger: $retrigger, attention: $attention, skipped: $skipped}'
}

cmd_ml_bump() {
  local runtime="${1:?usage: lang-bot.sh ml-bump RUNTIME VERSION}" version="${2:?}" dir vision
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${version}: not a release X.Y.Z" >&2; return 1; }
  dir="${ROOT}/runtimes/${runtime}"
  # shellcheck source=../lib/common.sh
  source "${ROOT}/lib/common.sh"
  # shellcheck source=../lib/watch.sh
  source "${ROOT}/lib/watch.sh"
  case "$runtime" in
    pytorch)
      # the torchvision release that requires exactly this torch (its Requires-Dist), the newest first
      vision=""
      local v
      for v in $(watch_get "https://pypi.org/pypi/torchvision/json" | jq -r '.releases | keys[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r | head -n 12); do
        if watch_get "https://pypi.org/pypi/torchvision/${v}/json" \
          | jq -e --arg t "torch==${version}" '[.info.requires_dist[]? | gsub(" "; "") | select(startswith($t))] | length > 0' >/dev/null; then
          vision="$v"
          break
        fi
      done
      [ -n "$vision" ] || { echo "no torchvision release on PyPI requires torch==${version}" >&2; return 2; }
      sed -i -E "s/^torch==[0-9.]+$/torch==${version}/; s/^torchvision==[0-9.]+$/torchvision==${vision}/" "${dir}/requirements-torch.txt"
      echo "torch ${version}, torchvision ${vision}" ;;
    tensorflow)
      sed -i -E "s/^tensorflow-cpu==[0-9.]+$/tensorflow-cpu==${version}/" "${dir}/requirements-cpu.txt"
      sed -i -E "s/^tensorflow\[and-cuda\]==[0-9.]+$/tensorflow[and-cuda]==${version}/" "${dir}/requirements-cuda.txt"
      echo "tensorflow ${version} (CPU and CUDA)" ;;
    *) echo "${runtime}: not an ML runtime (pytorch, tensorflow)" >&2; return 1 ;;
  esac
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
    || { echo "${catalog} has no runtime ${runtime}" >&2; return 1; }
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
  local results="${1:?usage: lang-bot.sh check-e2e RESULTS.md RUNTIME VERSION}" runtime="${2:?}" version="${3:?}" name count=0 failed
  [ -f "$results" ] || { echo "no e2e results (${results})" >&2; return 1; }
  for name in http schedule queue; do
    if grep -qE "^\| xaas-${runtime}-${version//./\\.}-${name} \|" "$results"; then count=$((count + 1)); fi
  done
  [ "$count" = 3 ] || { echo "the e2e ran ${count} of the 3 xaas cases of ${runtime} ${version}: it did not deploy the candidate image" >&2; return 1; }
  failed="$(awk '/^## Failures/ { on = 1; next } on && /^## / { exit } on && NF' "$results" | grep -E "\*\*(xaas|faas)-${runtime}-${version//./\\.}-" || true)"
  [ -z "$failed" ] || { echo "failed on the candidate image:"; echo "$failed"; return 1; }
  echo "the xaas cases of ${runtime} ${version} ran on the candidate image and passed"
}

cmd_runr_pins() {
  local runr="${1:?usage: lang-bot.sh runr-pins RUNR RUNTIME}" runtime="${2:?}" catalog entry pins
  catalog="${runr}/api/resources/runtimes/builtin.json"
  [ -f "$catalog" ] || { echo "no ${catalog}" >&2; return 1; }
  entry="$(jq -c --arg r "$runtime" '.runtimes | (if type == "array" then .[] else .[] end) | select(.id == $r)' "$catalog")"
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

# tail_of DIR NAME — the end of a test job's log, for a comment
tail_of() {
  echo '```'
  tail -n 40 "$1/results/$2/tail.txt" 2>/dev/null || echo "no log: the job did not get that far"
  echo '```'
}

cmd_land() {
  local dir="${1:?usage: lang-bot.sh land DIR RUN_URL}" run_url="${2:?}" n i test issue kind runtime version full key build e2e
  local tested comment name subject sha pins rc
  mkdir -p "$dir/comments"
  : > "$dir/actions"
  n="$(jq length "$dir/tests.json")"
  for ((i = 0; i < n; i++)); do
    test="$(jq -c ".[$i]" "$dir/tests.json")"
    issue="$(jq -r .issue <<< "$test")"; kind="$(jq -r .kind <<< "$test")"; runtime="$(jq -r .runtime <<< "$test")"
    version="$(jq -r .version <<< "$test")"; full="$(jq -r .full <<< "$test")"; key="$(jq -r .key <<< "$test")"
    comment="$dir/comments/${issue}.md"
    build="$(status "$dir" "lang-result-${key}-build")"
    e2e="success"
    [ "$kind" = language ] && e2e="$(status "$dir" "lang-result-${key}-e2e")"
    if [ "$build" != success ] || [ "$e2e" != success ]; then
      {
        echo "**Needs attention: ${runtime} ${full} failed.** Nothing was published or committed: the weekly publish holds it."
        echo ""
        echo "- build, smoke test and this repository's tests: ${build}"
        [ "$kind" = language ] && echo "- RunR's e2e on the candidate image: ${e2e}"
        for name in build e2e; do
          [ "$(status "$dir" "lang-result-${key}-${name}")" = success ] && continue
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
      printf 'label\t%s\t%s\ncomment\t%s\t%s\n' "$issue" "$ATTENTION_LABEL" "$issue" "$comment" >> "$dir/actions"
      continue
    fi

    # green: the change on top of main, when main did not change the runtime since the tested commit
    tested="$(cat "$dir/results/lang-result-${key}-build/sha")"
    git fetch -q origin main
    if ! git diff --quiet "$tested" origin/main -- "runtimes/${runtime}/" ':(exclude)runtimes/*/tested-versions'; then
      echo "**${runtime} ${full} passed on ${tested:0:12}, but main changed \`runtimes/${runtime}/\` since then.** Nothing was committed: the next run tests it again on the new main (${run_url})." > "$comment"
      printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$dir/actions"
      continue
    fi
    git checkout -q --detach origin/main
    if [ "$kind" = language ]; then
      bash "$ROOT/ci/lang-bot.sh" tested "$runtime" "$version" "$full"
      # a version that had no tag yet is a new one
      if ! grep -qxF "$version" "$dir/results/lang-result-${key}-build/published" 2>/dev/null; then
        subject="feat(${runtime}): ${runtime} ${version} (${full})"
      else
        subject="fix(${runtime}): ${runtime} ${full}"
      fi
    else
      git apply "$dir/results/lang-result-${key}-build/pin.patch"
      subject="fix(${runtime}): $(cat "$dir/results/lang-result-${key}-build/pin" 2>/dev/null || echo "${runtime} ${full}")"
    fi
    if git diff --quiet; then
      echo "**Nothing to do: main has ${runtime} ${full} already** (${run_url})." > "$comment"
      printf 'comment\t%s\t%s\nclose\t%s\n' "$issue" "$comment" "$issue" >> "$dir/actions"
      continue
    fi
    GIT_AUTHOR_NAME="${LANG_BOT_NAME:?}" GIT_AUTHOR_EMAIL="${LANG_BOT_EMAIL:?}" GIT_COMMITTER_NAME="$LANG_BOT_NAME" GIT_COMMITTER_EMAIL="$LANG_BOT_EMAIL" \
      git commit -q -a -F - <<EOF
${subject}

The language bot built exec-${runtime}$([ "$kind" = language ] && echo ":${version}") on ${runtime} ${full},
smoke-tested it and ran this repository's tests$([ "$kind" = language ] && echo ", and RunR's e2e deployed functions on it (the xaas and
faas cases)") before this commit: ${run_url}.
EOF
    # a fast-forward of main, never forced; a main that moved meanwhile is left as it is
    rc=0
    git push -q origin HEAD:refs/heads/main || rc=$?
    if [ "$rc" != 0 ]; then
      echo "**${runtime} ${full} passed, but main moved while the bot committed it.** Nothing was pushed: the next run tests it again (${run_url})." > "$comment"
      printf 'comment\t%s\t%s\n' "$issue" "$comment" >> "$dir/actions"
      continue
    fi
    sha="$(git rev-parse HEAD)"
    pins="$(cat "$dir/pins/${runtime}" 2>/dev/null || echo "not checked")"
    {
      echo "**Passed: ${runtime} ${full}** is on main as ${sha}; the publish workflow publishes it now."
      echo ""
      echo "- build, smoke test and this repository's tests: success"
      [ "$kind" = language ] && echo "- RunR's e2e (its last release) on \`$(cat "$dir/results/lang-result-${key}-build/image" 2>/dev/null)\`: the xaas and faas cases of ${runtime} ${version} passed"
      echo "- RunR's next: ${pins}"
      echo ""
      echo "Run: ${run_url}."
    } > "$comment"
    printf 'label\t%s\t%s\ncomment\t%s\t%s\nclose\t%s\npublish\t%s\n' "$issue" "$PASSED_LABEL" "$issue" "$comment" "$issue" "$runtime" >> "$dir/actions"
  done
}

command="${1:-}"
shift || true
case "$command" in
  land) cmd_land "$@" ;;
  plan) cmd_plan "$@" ;;
  ml-bump) cmd_ml_bump "$@" ;;
  tested) cmd_tested "$@" ;;
  catalog) cmd_catalog "$@" ;;
  check-e2e) cmd_check_e2e "$@" ;;
  runr-pins) cmd_runr_pins "$@" ;;
  *) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
