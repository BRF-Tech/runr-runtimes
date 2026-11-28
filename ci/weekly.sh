#!/usr/bin/env bash
# The language bot's weekly issue (README.md, The language bot), tested by test/weekly_test.sh.
#
# One issue per ISO week (UTC) with findings, "deps: weekly (2026-W48)", lists every finding of
# `ci.sh watch` (lib/watch.sh) as a row with its state, which the bots update in place: a language
# runtime's patch or minor release, a tool's, an ML framework's or a WebAssembly toolchain's, an
# end of life, a base image's newer series. Language releases (lang-releases.yml) adds each
# finding once: a key (the name the watch gives it: ruby-4.0.10, php-8.2-eol, base-alpine-3.24)
# that a weekly issue has, or that a closed issue of the earlier bot named (one issue per
# finding, before 2026-11-28), is not added again. Language tests (lang-test.yml) marks the rows it
# tests and writes their results. A row still open when a later week has findings moves into that
# week's issue, and the earlier one closes with a link to it; an issue whose rows are all done
# closes. The bots edit the body and write no comment on it. The format: ci/weekly.jq.
#
#   bash ci/weekly.sh week DATE
#       {"week", "monday", "sunday"} of a date (YYYY-MM-DD).
#   bash ci/weekly.sh file REPORT_DIR ISSUES.json DATE [--complete]
#       lang-releases.yml: the findings of `ci.sh watch --report=REPORT_DIR` (each *.md: its title,
#       a blank line, its text) against every issue (ISSUES.json: gh issue list --state all --json
#       number,title,state,labels,body); prints the operations (JSON). --complete: the watch read
#       every upstream, so an open row it no longer finds is done. An open issue of the earlier bot
#       is folded into the week's issue as a row in the state of its labels (needs attention,
#       lang: upstream outage) and closed with a pointer to it; one the complete watch no longer
#       finds is closed as resolved.
#   bash ci/weekly.sh rows ISSUES.json
#       lang-test.yml: the open weekly issue of ISSUES.json (gh issue list --json
#       number,title,state,labels,body) and its rows: {issue, week, rows}; {issue: null, …} when
#       none is open.
#   bash ci/weekly.sh update ISSUE.json UPDATES.json
#       lang-test.yml: a run's row updates (UPDATES.json: [{key, state, note, run}]) into the weekly
#       issue (ISSUE.json: gh issue view --json number,title,state,labels,body); prints the
#       operations: the body edited, the label needs attention while a row needs a person, the
#       issue closed when every row is done.
#   bash ci/weekly.sh apply OPS.json
#       the operations with gh (GH_REPO or GITHUB_REPOSITORY): create (its number for {{weekly}}),
#       alias, edit, reopen, close (with its comment), label, unlabel, warn, in order; exit 1 when
#       one failed (the others still run).
#
# Needs bash, jq (1.7) and GNU date; apply needs gh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "weekly: $*" >&2; exit 1; }

week_json() {
  local d="$1" dow monday
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "a date YYYY-MM-DD: '${d}'"
  dow="$(date -u -d "$d" +%u)"
  monday="$(date -u -d "$d -$((dow - 1)) days" +%F)"
  jq -nc --arg w "$(date -u -d "$d" +%G-W%V)" --arg m "$monday" --arg s "$(date -u -d "$monday +6 days" +%F)" \
    '{week: $w, monday: $m, sunday: $s}'
}

# the language runtimes (RUNTIME_DEFS of lib/common.sh): a release of one moves its major.minor
languages_json() {
  # shellcheck disable=SC2034 # read by lib/common.sh
  SCRIPT_DIR="$ROOT"
  # shellcheck source=../lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck disable=SC2046 # one word per runtime
  printf '%s\n' $(runtime_ids) | jq -R . | jq -sc .
}

cmd_file() {
  local dir="${1:?usage: weekly.sh file REPORT_DIR ISSUES.json DATE [--complete]}" issues="${2:?}" date="${3:?}" complete=false f
  case "${4:-}" in
    --complete) complete=true ;;
    '') ;;
    *) die "unknown argument: ${4}" ;;
  esac
  [ -f "$issues" ] || die "no ${issues}"
  # each finding: its title (the first line), its key (the file's name) and what it is (the first
  # paragraph of its text)
  shopt -s nullglob
  local findings=()
  for f in "$dir"/*.md; do findings+=("$f"); done
  shopt -u nullglob
  {
    for f in ${findings[@]+"${findings[@]}"}; do
      jq -Rs --arg name "$(basename "$f" .md)" '
        (split("\n")) as $l
        | {name: $name, title: $l[0], about: ([$l[2:][] ] | (index("") // length) as $e | .[:$e] | join(" "))}' "$f"
    done
  } | jq -s -L "$ROOT/ci" --slurpfile issues "$issues" --arg date "$date" --argjson week "$(week_json "$date")" \
      --argjson complete "$complete" --argjson languages "$(languages_json)" '
    include "weekly";
    map(. + {key: (.title | key_of)} | select(.key != null))
    | {findings: ., issues: $issues[0], date: $date, week: $week, complete: $complete, languages: $languages} | file_main'
}

cmd_rows() {
  local issues="${1:?usage: weekly.sh rows ISSUES.json}"
  [ -f "$issues" ] || die "no ${issues}"
  jq -c -L "$ROOT/ci" 'include "weekly"; rows_main' "$issues"
}

cmd_update() {
  local issue="${1:?usage: weekly.sh update ISSUE.json UPDATES.json}" updates="${2:?}"
  [ -f "$issue" ] && [ -f "$updates" ] || die "no ${issue} or ${updates}"
  jq -n -L "$ROOT/ci" --slurpfile issue "$issue" --slurpfile updates "$updates" \
    'include "weekly"; {issue: $issue[0], updates: $updates[0]} | update_main'
}

cmd_apply() {
  local ops="${1:?usage: weekly.sh apply OPS.json}" repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}" n i op issue errors=0 work url weekly="" label reason comment
  local -a args labels
  [ -n "$repo" ] || die "apply: GH_REPO or GITHUB_REPOSITORY names the repository"
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # the directory of this call
  trap "rm -rf -- '$work'" RETURN
  # sub TEXT — TEXT with {{weekly}} as the week's issue number (created or aliased so far)
  sub() { if [ -n "$weekly" ]; then printf '%s' "${1//"{{weekly}}"/$weekly}"; else printf '%s' "$1"; fi; }
  field() { jq -r --arg f "$1" '.[$f] // "" | if type == "array" then join("\n") else tostring end' "$work/op.json"; }
  n="$(jq length "$ops")"
  for ((i = 0; i < n; i++)); do
    jq -c ".[$i]" "$ops" > "$work/op.json"
    op="$(field op)"
    issue="$(sub "$(field issue)")"
    if [[ "$issue" == *"{{"* ]] || [[ "$(field body)$(field comment)" == *"{{weekly}}"* && -z "$weekly" ]]; then
      echo "::warning::${op} skipped: the week's issue was not created" >&2
      errors=$((errors + 1))
      continue
    fi
    case "$op" in
      alias) weekly="$issue" ;;
      create)
        sub "$(field body)" > "$work/body.md"
        labels=()
        while IFS= read -r label; do [ -z "$label" ] || labels+=(--label "$label"); done < <(field labels)
        if url="$(gh issue create --repo "$repo" --title "$(field title)" --body-file "$work/body.md" ${labels[@]+"${labels[@]}"})"; then
          weekly="${url##*/}"
          echo "created #${weekly}: $(field title)"
        else
          echo "::warning::could not create $(field title)" >&2
          errors=$((errors + 1))
        fi ;;
      edit)
        sub "$(field body)" > "$work/body.md"
        gh issue edit "$issue" --repo "$repo" --body-file "$work/body.md" >/dev/null && echo "edited #${issue}" || errors=$((errors + 1)) ;;
      reopen)
        gh issue reopen "$issue" --repo "$repo" >/dev/null && echo "reopened #${issue}" || errors=$((errors + 1)) ;;
      close)
        reason="$(field reason)"
        comment="$(sub "$(field comment)")"
        args=(--reason "${reason:-completed}")
        [ -z "$comment" ] || args+=(--comment "$comment")
        gh issue close "$issue" --repo "$repo" "${args[@]}" >/dev/null && echo "closed #${issue}" || errors=$((errors + 1)) ;;
      label|unlabel)
        label="$(field label)"
        if [ "$op" = label ]; then args=(--add-label "$label"); else args=(--remove-label "$label"); fi
        gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null && echo "${op}led #${issue}: ${label}" || errors=$((errors + 1)) ;;
      warn) echo "::warning::$(field text)" >&2 ;;
      *) echo "::warning::unknown operation ${op}" >&2; errors=$((errors + 1)) ;;
    esac
  done
  [ -z "$weekly" ] || echo "weekly=${weekly}"
  [ "$errors" = 0 ] || { echo "${errors} operation(s) failed or were skipped" >&2; return 1; }
}

command="${1:-}"
shift || true
case "$command" in
  week) week_json "${1:?usage: weekly.sh week DATE}" ;;
  file) cmd_file "$@" ;;
  rows) cmd_rows "$@" ;;
  update) cmd_update "$@" ;;
  apply) cmd_apply "$@" ;;
  *) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
