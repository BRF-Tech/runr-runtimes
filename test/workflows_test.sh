#!/usr/bin/env bash
# Tests the repository's workflows as text, without GitHub: every workflow reads contents only by
# default, has a concurrency group, pins every action to a full commit SHA with its version (a
# composite action of this repository by its path), checks every download against a pinned SHA256
# and retries it (ci/fetch.sh: an upstream's 504 for a minute fails no job), and uses only the
# secrets its job needs. The language bot:
#   - lang-releases.yml watches every week and by hand (ci.sh watch) and files an issue per finding;
#   - lang-test.yml runs after it and by hand, never on a push or a pull request; it is the only
#     workflow that writes contents, and its one push is ci/lang-bot.sh's
#     `git push -q origin HEAD:refs/heads/main` (no other refspec, tag, deletion or force); it
#     tests the languages, the tools of their images, the ML runtimes and the WebAssembly
#     toolchains with RunR's public last release (a runtime that release lacks skips its e2e), and
#     nothing of RunR's private repository: no deploy key, no origin; every step of its build and
#     e2e jobs before the suite prints into the job's log the red comment shows, a suite an upstream
#     outage stopped runs once more, the results say an outage is one (lang-bot.sh upstream), and
#     the outage label is made and taken off; the bot commits with Burak's identity
#     and its trailer (RunR-Lang-Bot: <name> <version>); an ML release without its CUDA wheel is
#     held and closed; the land job archives the versions past their end of life;
#   - the publish workflow holds an untested language version (LANG_GATE), every language runtime
#     has its tested-versions.
#
#   bash test/workflows_test.sh
# shellcheck disable=SC2016 # the workflows' text, not this shell's variables
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
wfdir="$here/.github/workflows"
fail() { echo "FAIL: $*" >&2; exit 1; }

# block FILE KEY — the lines under a top-level key, without comments and blank lines
block() {
  awk -v k="$2:" '$0 == k { on = 1; next } on && /^[[:space:]]*(#|$)/ { next } on && /^[^ ]/ { exit } on { print }' "$1"
}
# job FILE NAME — the lines of one job
job() {
  awk -v j="  $2:" '
    /^jobs:/ { injobs = 1; next }
    injobs && $0 == j { on = 1; print; next }
    on && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    on { print }
  ' "$1"
}

for wf in "$wfdir"/*.yml; do
  name="$(basename "$wf")"
  [ "$(block "$wf" permissions)" = '  contents: read' ] || fail "${name}: the default permissions are not contents: read alone"
  # a group of the workflow, or of its jobs that write (patch.yml, platform-release.yml)
  grep -qE '^ *concurrency:' "$wf" || fail "${name}: no concurrency group"
  bad="$(grep -E '^ *(- )?uses: ' "$wf" | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v?[0-9]' \
    | grep -vE 'uses: \./\.github/actions/[a-z0-9-]+$' || true)"
  [ -z "$bad" ] || fail "${name}: actions not pinned to a full commit SHA with its version: ${bad}"
  [ "$(grep -cE 'curl [^|]*-o ' "$wf" || true)" = "$(grep -cE 'sha256sum -c' "$wf" || true)" ] || fail "${name}: a download without its checksum"
  # a download through ci/fetch.sh names its pinned SHA256; one with curl itself retries
  bad="$(grep -E '(^|[ /])ci/fetch\.sh( |$)' "$wf" | grep -vE '^ +bash (runtimes-repo/)?ci/fetch\.sh "https://[^"]+" /tmp/[A-Za-z0-9._-]+ "\$\{[A-Z0-9_]+_SHA256\}"$' || true)"
  [ -z "$bad" ] || fail "${name}: a ci/fetch.sh download without its pinned SHA256: ${bad}"
  bad="$(grep -E 'curl [^|]*-o ' "$wf" | grep -v -- '--retry' || true)"
  [ -z "$bad" ] || fail "${name}: a download that does not retry (bash ci/fetch.sh URL OUT SHA256): ${bad}"
  allowed="secrets.GITHUB_TOKEN"
  case "$name" in
    publish.yml|patch.yml|platform-release.yml) allowed="$allowed secrets.RUNR_PATCH_FEED_COSIGN_KEY secrets.RUNR_PATCH_FEED_COSIGN_PASSWORD" ;;
  esac
  for secret in $(grep -oE '\$\{\{ *secrets\.[A-Za-z0-9_]+ *\}\}' "$wf" | sed -E 's/[${} ]//g' | sort -u); do
    [[ " ${allowed} " == *" ${secret} "* ]] || fail "${name}: a secret it does not need: ${secret}"
  done
  # contents: write in the language bot's landing alone; issues: write in its two workflows alone
  if grep -qE 'contents: *write' "$wf" && [ "$name" != lang-test.yml ]; then fail "${name} writes contents"; fi
  if grep -qE 'issues: *write' "$wf"; then
    case "$name" in lang-releases.yml|lang-test.yml) ;; *) fail "${name} writes issues" ;; esac
  fi
  # the workflows push nothing themselves (images aside)
  pushes="$(grep -nE '(^|[^-])git([^|]* )?push( |$)' "$wf" || true)"
  [ -z "$pushes" ] || fail "${name} pushes with git: ${pushes}"
done
echo "ok - every workflow: contents: read, a concurrency group, actions pinned, downloads checked and retried, only the secrets it needs, no git push"

# --- lang-releases.yml ------------------------------------------------------------------------------
rel="$wfdir/lang-releases.yml"
on="$(block "$rel" on)"
grep -qF "cron: '" <<<"$on" || fail "lang-releases.yml has no schedule"
grep -qxE '  workflow_dispatch:' <<<"$on" || fail "lang-releases.yml cannot be run by hand"
grep -qF './ci.sh watch --report=' "$rel" || fail "lang-releases.yml does not run ci.sh watch"
grep -qF 'gh issue create' "$rel" || fail "lang-releases.yml files no issue"
echo "ok - lang-releases.yml: weekly and by hand, ci.sh watch, an issue per finding"

# --- lang-test.yml ----------------------------------------------------------------------------------
lt="$wfdir/lang-test.yml"
on="$(block "$lt" on)"
grep -qF 'workflows: [Language releases]' <<<"$on" || fail "lang-test.yml does not run after Language releases"
grep -qxE '  workflow_dispatch:' <<<"$on" || fail "lang-test.yml cannot be run by hand"
grep -qxE '  (push|pull_request|pull_request_target|schedule):' <<<"$on" && fail "lang-test.yml runs on a push, a pull request or by itself"
grep -qE 'contents: *write' <<<"$(job "$lt" land)" || fail "lang-test.yml's land job cannot commit"
for j in plan build e2e; do grep -qE 'contents: *write' <<<"$(job "$lt" "$j")" && fail "lang-test.yml's ${j} job writes contents"; done
grep -qF 'bash ci/lang-bot.sh land "$RUNNER_TEMP/lang" "$RUN_URL"' "$lt" || fail "lang-test.yml does not land through ci/lang-bot.sh"
# RunR: its public last release only, nothing of its private repository
gitlab="$(grep -rnE 'GITLAB_|gitlab\.com|git@|ssh://|PUSH_KEY|KNOWN_HOSTS' "$wfdir" "$here/ci" "$here/lib" || true)"
[ -z "$gitlab" ] || fail "the language bot reaches RunR's private repository: ${gitlab}"
[ "$(grep -cF 'ref: ${{ needs.plan.outputs.runr-tag }}' "$lt")" = 2 ] || fail "lang-test.yml does not take RunR at its last release (the e2e and the pins)"
grep -qF 'gh release view --repo "$RUNR_REPOSITORY"' "$lt" || fail "lang-test.yml does not look up RunR's last release"
# every kind of test has its RunR suites: the main e2e, its ML case, the WebAssembly suites
for suite in 'test) bash runtime/ci.sh test --skip-sandbox' 'test-ml) TEST_E2E_EXTRA_ARGS=--ml bash runtime/ci.sh test --skip-sandbox' 'test-wasm|test-images) bash runtime/ci.sh "$SUITE"'; do
  grep -qF -- "$suite" "$lt" || fail "lang-test.yml does not run RunR's ${suite%%)*}"
done
# every kind of test is built: a language version, a tool of a language image, an ML framework, a
# WebAssembly toolchain; a runtime RunR's last release does not have yet skips its e2e
for kind in language tool ml wasm; do
  grep -qF "if: matrix.kind == '${kind}'" <<<"$(job "$lt" build)" || fail "lang-test.yml builds no ${kind} candidate"
done
grep -qF 'bash ci/lang-bot.sh tool-bump "$RUNTIME" "$FULL"' "$lt" || fail "lang-test.yml does not move a tool's pin through ci/lang-bot.sh"
grep -qF 'runtime yet: it comes with its next release' <<<"$(job "$lt" e2e)" || fail "lang-test.yml's e2e does not skip a runtime RunR's release lacks"
# the red comment's log: every step of the build job past the setup prints into build.log (crane,
# the four builds, this repository's tests), of the e2e job into e2e.log up to the suite
[ "$(grep -cF 'exec > >(tee -a "$RUNNER_TEMP/build.log") 2>&1' <<<"$(job "$lt" build)")" = 6 ] || fail "lang-test.yml's build steps do not all print into build.log"
[ "$(grep -cF 'exec > >(tee -a "$RUNNER_TEMP/e2e.log") 2>&1' <<<"$(job "$lt" e2e)")" = 2 ] || fail "lang-test.yml's e2e steps do not all print into e2e.log"
# an upstream outage: the suite once more, the results of both jobs say it, the label made and taken off
grep -qF 'outage="$(bash ../runtimes-repo/ci/lang-bot.sh upstream "$RUNNER_TEMP/e2e.log")"' <<<"$(job "$lt" e2e)" || fail "lang-test.yml does not run a suite an outage stopped once more"
grep -qF 'bash ci/lang-bot.sh upstream "$RUNNER_TEMP/build.log" > "$RUNNER_TEMP/result/upstream"' <<<"$(job "$lt" build)" || fail "the build's result does not say an outage"
grep -qF 'bash runtimes-repo/ci/lang-bot.sh upstream "$RUNNER_TEMP/e2e.log" > "$RUNNER_TEMP/result/upstream"' <<<"$(job "$lt" e2e)" || fail "the e2e's result does not say an outage"
grep -qF 'gh label create "lang: upstream outage"' "$lt" || fail "lang-test.yml does not make the outage label"
grep -qF 'unlabel) gh issue edit "$issue" --repo "$GITHUB_REPOSITORY" --remove-label "$arg"' "$lt" || fail "lang-test.yml does not take a label off"
grep -qF 'close) gh issue close "$issue" --repo "$GITHUB_REPOSITORY" --reason "${arg:-completed}"' "$lt" || fail "lang-test.yml does not close with a reason (held: not planned)"
# a torch without a wheel for the -gpu image's CUDA: held by the bump (exit 4), nothing built, its
# e2e skipped, the issue closed by the land
grep -qF 'if [ "$rc" = 4 ]; then' <<<"$(job "$lt" build)" && grep -qF 'echo held > "$RUNNER_TEMP/result/status"' <<<"$(job "$lt" build)" \
  && grep -qF '"$(cat "$RUNNER_TEMP/build/status")" = held' <<<"$(job "$lt" e2e)" || fail "lang-test.yml does not hold an ML release without its CUDA wheel"
# a version past its end of life: archived by the land job, which may tag and remove package
# versions for it (the Admin role of this repository on the packages), with crane logged in
grep -qE 'packages: *write' <<<"$(job "$lt" land)" && grep -qF 'ARCHIVE: ${{ needs.plan.outputs.archive }}' <<<"$(job "$lt" land)" \
  && grep -qF 'bash ci/fetch.sh "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/' <<<"$(job "$lt" land)" \
  && grep -qF "needs.plan.outputs.any-archive == 'true'" <<<"$(job "$lt" land)" || fail "lang-test.yml's land job does not archive the end-of-life versions"
grep -qF 'LANG_ARCHIVE_IMAGE' "$lt" && fail "lang-test.yml replaces the registry step of the archive (LANG_ARCHIVE_IMAGE is the tests')"
# the one push: HEAD:refs/heads/main of this repository, a fast-forward
bot="$here/ci/lang-bot.sh"
gitcmd='^[^#]*(^|[^A-Za-z_-])git( -[cC] [^ ]+)*'
[ "$(grep -cE "${gitcmd} push" "$bot")" = 1 ] || fail "ci/lang-bot.sh has another push than the one of main"
grep -qE '^[^#]*git push -q origin HEAD:refs/heads/main \|\| rc=\$\?$' "$bot" || fail "ci/lang-bot.sh does not push exactly HEAD:refs/heads/main"
grep -E "${gitcmd} push" "$bot" | grep -qE -- '--force|--mirror|--all|--tags|--delete| -f( |$)| -d( |$)|\+HEAD|\+refs| :refs/'   && fail "ci/lang-bot.sh forces, deletes or pushes more"
grep -qE "${gitcmd} push" "$here/lib/watch.sh" && fail "lib/watch.sh pushes"
# the bot's commits: Burak's identity (2026-11-11, as in BRF-Tech/runr), marked by their trailer
grep -qxF '  LANG_BOT_NAME: Burak Faruk ŞAHİN' "$lt" && grep -qxF '  LANG_BOT_EMAIL: 19393636+brkfun@users.noreply.github.com' "$lt" \
  || fail "lang-test.yml does not commit as Burak Faruk ŞAHİN <19393636+brkfun@users.noreply.github.com>"
grep -qF 'LANG_TRAILER="RunR-Lang-Bot"' "$bot" && grep -qxF '${LANG_TRAILER}: ${runtime} ${full}' "$bot" || fail "ci/lang-bot.sh commits without its trailer"
echo "ok - lang-test.yml: after the watch and by hand, contents: write in its landing alone, one push of HEAD:refs/heads/main, RunR's public last release only"

# --- the publish gate -------------------------------------------------------------------------------
grep -qF "LANG_GATE: '1'" <<<"$(job "$wfdir/publish.yml" publish)" || fail "publish.yml publishes untested language versions (no LANG_GATE)"
grep -q 'LANG_GATE' "$wfdir/patch.yml" && fail "patch.yml holds a person's patch"
# every language runtime ci.sh builds (RUNTIME_DEFS) has the file the gate reads
languages="$(SCRIPT_DIR="$here" bash -c 'source "$0/lib/common.sh" && runtime_ids' "$here")"
[[ " ${languages} " == *" java dotnet ruby bun "* ]] || fail "the language runtimes: ${languages}"
for rt in $languages; do
  [ -f "$here/runtimes/$rt/tested-versions" ] || fail "no runtimes/${rt}/tested-versions"
done
echo "ok - the publish workflow holds an untested language version; the patch workflow never"
