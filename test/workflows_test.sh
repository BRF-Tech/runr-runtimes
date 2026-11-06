#!/usr/bin/env bash
# Tests the repository's workflows as text, without GitHub: every workflow reads contents only by
# default, has a concurrency group, pins every action to a full commit SHA with its version (a
# composite action of this repository by its path), checks every download against a pinned SHA256
# and uses only the secrets its job needs. The language bot:
#   - lang-releases.yml watches every week and by hand (ci.sh watch) and files an issue per finding;
#   - lang-test.yml runs after it and by hand, never on a push or a pull request; it is the only
#     workflow that writes contents, and its one push is ci/lang-bot.sh's
#     `git push -q origin HEAD:refs/heads/main` (no other refspec, tag, deletion or force); it
#     reads RunR's next with the deploy key (GITLAB_RUNR_PUSH_KEY, vars.GITLAB_KNOWN_HOSTS) in one
#     step, through ci/lang-ssh-key.sh, never pushes there, and removes the key in a step that
#     always runs;
#   - the publish workflow holds an untested language version (LANG_GATE).
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
  allowed="secrets.GITHUB_TOKEN"
  case "$name" in
    publish.yml|patch.yml|platform-release.yml) allowed="$allowed secrets.RUNR_PATCH_FEED_COSIGN_KEY secrets.RUNR_PATCH_FEED_COSIGN_PASSWORD" ;;
    lang-test.yml) allowed="$allowed secrets.GITLAB_RUNR_PUSH_KEY" ;;
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
echo "ok - every workflow: contents: read, a concurrency group, actions pinned, downloads checked, only the secrets it needs, no git push"

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
# the deploy key: one step, through lang-ssh-key.sh, removed afterwards, RunR's next only read
[ "$(grep -cF 'PUSH_KEY: ${{ secrets.GITLAB_RUNR_PUSH_KEY }}' "$lt")" = 1 ] || fail "lang-test.yml: the deploy key in more than one step"
[ "$(grep -cF 'KNOWN_HOSTS: ${{ vars.GITLAB_KNOWN_HOSTS }}' "$lt")" = 1 ] || fail "lang-test.yml: GitLab's host key in more than one step"
grep -nE '(secrets|vars)\.GITLAB_' "$lt" | grep -vE ': +(PUSH_KEY: \$\{\{ secrets\.GITLAB_RUNR_PUSH_KEY|KNOWN_HOSTS: \$\{\{ vars\.GITLAB_KNOWN_HOSTS) \}\}$' \
  && fail "lang-test.yml uses the deploy key other than as a step's PUSH_KEY / KNOWN_HOSTS"
grep -qF 'GIT_SSH_COMMAND="$(bash ci/lang-ssh-key.sh "$RUNNER_TEMP/ssh")"' "$lt" || fail "lang-test.yml writes the deploy key other than through ci/lang-ssh-key.sh"
grep -B1 -F 'run: rm -rf "$RUNNER_TEMP/ssh"' "$lt" | grep -qF 'if: always()' || fail "lang-test.yml does not remove the deploy key in a step that always runs"
grep -nE '\$\{?(PUSH_KEY|KNOWN_HOSTS)\b' "$lt" && fail "lang-test.yml reads the deploy key in a run script"
grep -nE 'RUNR_REMOTE' "$lt" | grep -vE 'RUNR_REMOTE: git@gitlab\.com:brftech/runr\.git$|git clone -q --depth 1 --branch next --single-branch "\$RUNR_REMOTE"' \
  && fail "lang-test.yml does more with RunR's origin than clone next"
key="$here/ci/lang-ssh-key.sh"
for o in 'IdentitiesOnly=yes' 'StrictHostKeyChecking=yes' 'UserKnownHostsFile=' 'umask 077' 'chmod 600' 'SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8'; do
  grep -qF -- "$o" "$key" || fail "ci/lang-ssh-key.sh: no ${o}"
done
grep -qE 'StrictHostKeyChecking=(no|accept-new)|ssh-keyscan' "$lt" "$key" && fail "the bot trusts another host key than GitLab's"
# the one push: HEAD:refs/heads/main of this repository, a fast-forward
bot="$here/ci/lang-bot.sh"
gitcmd='^[^#]*(^|[^A-Za-z_-])git( -[cC] [^ ]+)*'
[ "$(grep -cE "${gitcmd} push" "$bot")" = 1 ] || fail "ci/lang-bot.sh has another push than the one of main"
grep -qE '^[^#]*git push -q origin HEAD:refs/heads/main \|\| rc=\$\?$' "$bot" || fail "ci/lang-bot.sh does not push exactly HEAD:refs/heads/main"
grep -E "${gitcmd} push" "$bot" | grep -qE -- '--force|--mirror|--all|--tags|--delete| -f( |$)| -d( |$)|\+HEAD|\+refs| :refs/'   && fail "ci/lang-bot.sh forces, deletes or pushes more"
for s in lib/watch.sh ci/lang-ssh-key.sh; do
  grep -qE "${gitcmd} push" "$here/$s" && fail "${s} pushes"
done
echo "ok - lang-test.yml: after the watch and by hand, contents: write in its landing alone, one push of HEAD:refs/heads/main, RunR's next only read with the deploy key"

# --- the publish gate -------------------------------------------------------------------------------
grep -qF "LANG_GATE: '1'" <<<"$(job "$wfdir/publish.yml" publish)" || fail "publish.yml publishes untested language versions (no LANG_GATE)"
grep -q 'LANG_GATE' "$wfdir/patch.yml" && fail "patch.yml holds a person's patch"
for rt in python nodejs go php; do
  [ -f "$here/runtimes/$rt/tested-versions" ] || fail "no runtimes/${rt}/tested-versions"
done
echo "ok - the publish workflow holds an untested language version; the patch workflow never"
