#!/usr/bin/env bash
# Tests ci/weekly.sh, the language bot's weekly issue, without GitHub: a fake gh on PATH keeps the
# issues in a JSON file, the findings are report files as `ci.sh watch --report` writes them.
# Checks that:
#   - a week is its ISO week (UTC), Monday to Sunday;
#   - the first run opens "deps: weekly (<ISO year>-W<week>)" with one row per finding (a release
#     new, a base image's series a person's decision, an end of life held until its date, one past
#     it new), folds the open issues of the earlier bot into it in the state of their labels and
#     closes them with a pointer to the row, closes one the complete watch no longer finds, and
#     never adds a finding a closed issue of the earlier bot had; the issue carries the labels deps
#     and needs attention;
#   - the same findings again change nothing; a new one is added to this week's issue;
#   - the rows of the open issue are what the plan reads, and a run's updates change their state,
#     note and run in place, the label needs attention following the rows;
#   - a later week opens its own issue with the open rows carried over and the new findings, closes
#     the earlier one with a link to it ("Continued in #N."), marks done a row the complete watch no
#     longer finds (an incomplete watch none), and supersedes the older release of one image;
#   - an issue whose rows are all done closes ("Closed: every row is done."), a quiet week opens
#     none, and a closed issue of this week reopens when it has an open row again;
#   - two open weekly issues (a race) are merged into one; a marker quoted in a person's text is
#     none; a long issue leaves out what each finding is; apply goes on after a failed operation.
#
#   bash test/weekly_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip: weekly_test needs jq"; exit 0; }
weekly="$here/ci/weekly.sh"

# --- the week -----------------------------------------------------------------------------------------
[ "$(bash "$weekly" week 2026-11-28)" = '{"week":"2026-W48","monday":"2026-11-23","sunday":"2026-11-29"}' ] || fail "week: $(bash "$weekly" week 2026-11-28)"
[ "$(bash "$weekly" week 2026-11-23 | jq -r .week)" = 2026-W48 ] && [ "$(bash "$weekly" week 2026-11-30 | jq -r .week)" = 2026-W49 ] || fail "Monday starts a week"
# ISO years: 2027-01-01 is in 2026's week 53
[ "$(bash "$weekly" week 2027-01-01 | jq -c '[.week, .monday]')" = '["2026-W53","2026-12-28"]' ] || fail "the ISO year"
bash "$weekly" week 2026-13-01 >/dev/null 2>&1 && fail "not a date"
echo "ok - a week: its ISO week (UTC), Monday to Sunday"

# --- a fake GitHub ----------------------------------------------------------------------------------
# gh issue create|edit|close|reopen|list|view on the issues of $GH_STORE; GH_FAIL=OP fails OP
export GH_STORE="$tmp/store.json" GH_LOG="$tmp/gh.log" GH_REPO=BRF-Tech/runr-runtimes
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = issue ] || { echo "fake gh: $*" >&2; exit 2; }
op="$2"; shift 2
echo "$op $*" >> "$GH_LOG"
[ "${GH_FAIL:-}" != "$op" ] || { echo "fake gh: ${op} refused" >&2; exit 1; }
n="" title="" body="" state="" reason="" comment=""
adds=() removes=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--json|--limit|--search) shift ;;
    --title) title="$2"; shift ;;
    --body-file) body="$(cat "$2")"; shift ;;
    --label|--add-label) adds+=("$2"); shift ;;
    --remove-label) removes+=("$2"); shift ;;
    --reason) reason="$2"; shift ;;
    --comment) comment="$2"; shift ;;
    --state) state="$2"; shift ;;
    [0-9]*) n="$1" ;;
  esac
  shift
done
labels() { printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'; }
upd() { jq --argjson n "$n" "$@" "$GH_STORE" > "$GH_STORE.tmp" && mv "$GH_STORE.tmp" "$GH_STORE"; }
case "$op" in
  create)
    n="$(jq '([.[].number] | max // 0) + 1' "$GH_STORE")"
    jq --argjson n "$n" --arg t "$title" --arg b "$body" --argjson l "$(labels ${adds[@]+"${adds[@]}"})" \
      '. + [{number: $n, title: $t, state: "OPEN", labels: ($l | map({name: .})), body: $b}]' "$GH_STORE" > "$GH_STORE.tmp" && mv "$GH_STORE.tmp" "$GH_STORE"
    echo "https://github.com/${GH_REPO}/issues/${n}" ;;
  edit)
    if [ -n "$body" ]; then upd --arg b "$body" 'map(if .number == $n then .body = $b else . end)'; fi
    upd --argjson a "$(labels ${adds[@]+"${adds[@]}"})" --argjson r "$(labels ${removes[@]+"${removes[@]}"})" \
      'map(if .number == $n then .labels = ([.labels[].name] + $a - $r | unique | map({name: .})) else . end)' ;;
  close)
    upd --arg c "$comment" --arg r "$reason" 'map(if .number == $n then .state = "CLOSED" | .closed = $r | .comments = ((.comments // []) + (if $c == "" then [] else [$c] end)) else . end)' ;;
  reopen) upd 'map(if .number == $n then .state = "OPEN" else . end)' ;;
  list)
    if [ "$state" = open ]; then jq '[.[] | select(.state == "OPEN")]' "$GH_STORE"; else cat "$GH_STORE"; fi ;;
  view) jq --argjson n "$n" '.[] | select(.number == $n)' "$GH_STORE" ;;
  *) echo "fake gh: issue ${op}" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# finding NAME TITLE TEXT — a report file of ci.sh watch in $tmp/report
finding() { mkdir -p "$tmp/report"; printf '%s\n\n%s\n\nThe language bot does this and that.\n\nReported by ci.sh watch.\n' "$2" "$3" > "$tmp/report/$1.md"; }
# file DATE [--complete] — the file step of lang-releases.yml on the fake GitHub
file() { gh issue list --state all > "$tmp/issues.json"; bash "$weekly" file "$tmp/report" "$tmp/issues.json" "$@" > "$tmp/ops.json"; bash "$weekly" apply "$tmp/ops.json" > "$tmp/apply.out"; }
issue() { jq --argjson n "$1" '.[] | select(.number == $n)' "$GH_STORE"; }
rows() { issue "$1" | jq -c '.body | [scan("<!-- runr-lang:row (\\{[^\n]*\\}) -->") | .[0] | fromjson]'; }
state_of() { rows "$1" | jq -r --arg k "$2" '.[] | select(.key == $k) | .state'; }
labels_of() { issue "$1" | jq -r '[.labels[].name] | sort | join(",")'; }
newest() { jq '[.[] | select(.title | startswith("deps: weekly"))] | max_by(.number) | .number' "$GH_STORE"; }

# --- the first week: the findings, the earlier bot's issues folded ------------------------------------
# the earlier bot's issues: open ones (needs attention, an outage, none), closed ones (passed, held)
jq -n '[
  {number: 11, title: "lang: php 8.2 end of life 2026-12-31", state: "OPEN", labels: [], body: "a notice"},
  {number: 13, title: "lang: pytorch 2.15.0 released", state: "CLOSED", labels: [{name: "needs attention"}], body: "held"},
  {number: 20, title: "lang: go 1.26.10 released", state: "OPEN", labels: [], body: "x"},
  {number: 29, title: "base: alpine 3.24 available", state: "OPEN", labels: [], body: "x"},
  {number: 43, title: "lang: maven 3.10.2 released", state: "OPEN", labels: [{name: "lang: upstream outage"}], body: "x"},
  {number: 44, title: "lang: php 8.6.0 released", state: "CLOSED", labels: [{name: "lang: passed"}], body: "x"},
  {number: 47, title: "lang: ruby 4.0.10 released", state: "OPEN", labels: [{name: "needs attention"}], body: "x"},
  {number: 48, title: "A person'"'"'s question", state: "OPEN", labels: [], body: "quoting the bot:\n<!-- runr-lang:weekly:2026-W47 -->\nand more"}
]' > "$GH_STORE"
finding ruby-4.0.10 'lang: ruby 4.0.10 released' 'A new patch release of ruby 4.0: **4.0.10**.'
finding maven-3.10.2 'lang: maven 3.10.2 released' 'A new release of maven: **3.10.2**.'
finding php-8.2-eol 'lang: php 8.2 end of life 2026-12-31' 'php 8.2 reaches its end of life on 2026-12-31.'
finding base-alpine-3.24 'base: alpine 3.24 available' 'Upstream has a newer series of alpine: **3.24**. The reqs mirror pins alpine up to 3.22:'
finding pytorch-2.15.0 'lang: pytorch 2.15.0 released' 'A new release of torch.'
finding go-1.27.4 'lang: go 1.27.4 released' 'A new patch release of go 1.27: **1.27.4**.'
finding python-3.10-eol 'lang: python 3.10 end of life 2026-10-01' 'python 3.10 reached its end of life on 2026-10-01.'
file 2026-11-23 --complete || fail "the first file: $(cat "$tmp/apply.out")"
w1="$(newest)"
[ "$w1" = 49 ] && [ "$(issue "$w1" | jq -r .title)" = 'deps: weekly (2026-W48)' ] || fail "the first weekly issue: $(jq -c '[.[] | [.number, .title]]' "$GH_STORE")"
grep -qxF 'weekly=49' "$tmp/apply.out" || fail "apply names the week's issue: $(cat "$tmp/apply.out")"
[ "$(rows "$w1" | jq -c '[.[] | [.key, .state, (.until // null), (.from // null)]] | sort')" = '[["base-alpine-3.24","a person'"'"'s decision",null,29],["go-1.27.4","new",null,null],["maven-3.10.2","upstream outage",null,43],["php-8.2-eol","held","2026-12-31",11],["python-3.10-eol","new",null,null],["ruby-4.0.10","needs attention",null,47]]' ] \
  || fail "the rows: $(rows "$w1")"
[ "$(labels_of "$w1")" = "deps,needs attention" ] || fail "the labels: $(labels_of "$w1")"
body="$(issue "$w1" | jq -r .body)"
[ "$(sed -n '$p' <<<"$body")" = '<!-- runr-lang:weekly:2026-W48 -->' ] || fail "the marker is not the last line"
grep -qF '| `ruby-4.0.10` | lang: ruby 4.0.10 released | needs attention |' <<<"$body" && grep -qF '| `php-8.2-eol` | lang: php 8.2 end of life 2026-12-31 | held until 2026-12-31 |' <<<"$body" \
  && grep -qF '(2026-11-23 to 2026-11-29, UTC)' <<<"$body" && grep -qF -- '- `base-alpine-3.24`: Upstream has a newer series of alpine: **3.24**. The reqs mirror pins alpine up to 3.22.' <<<"$body" \
  || fail "the body: ${body}"
# the rows in the order a person reads them: needs attention first, what is done last
[ "$(grep -oE '^\| `[a-z0-9.-]+` ' <<<"$body" | tr -d '|` ' | paste -sd ' ' -)" = "ruby-4.0.10 maven-3.10.2 base-alpine-3.24 go-1.27.4 python-3.10-eol php-8.2-eol" ] \
  || fail "the order: $(grep -oE '^\| `[a-z0-9.-]+` ' <<<"$body")"
# the earlier bot's open issues: folded with a pointer to their row, or resolved; closed ones stay
for n in 11 29 43 47; do
  [ "$(issue "$n" | jq -r '[.state, .closed] | join(" ")')" = "CLOSED not planned" ] && grep -qE "^Folded into the weekly issue #49, row \`[a-z0-9.-]+\`: " <<<"$(issue "$n" | jq -r '.comments[0]')" \
    || fail "#${n} not folded: $(issue "$n")"
done
[ "$(issue 20 | jq -r '[.state, .closed, .comments[0]] | join("|")')" = "CLOSED|completed|Resolved: the watch of 2026-11-23 no longer finds it (README.md, The language bot)." ] || fail "#20: $(issue 20)"
[ "$(issue 48 | jq -r .state)" = OPEN ] && [ "$(issue 13 | jq -r '.comments // [] | length')" = 0 ] || fail "a person's issue or a closed one touched"
echo "ok - the first week: a row per finding in its state, the earlier bot's open issues folded or resolved, a finding a closed one had not added again, the labels deps and needs attention"

# --- the same week ------------------------------------------------------------------------------------
: > "$GH_LOG"
file 2026-11-25 --complete || fail "file again: $(cat "$tmp/apply.out")"
[ ! -s "$GH_LOG" ] || [ -z "$(grep -vE '^list ' "$GH_LOG")" ] || fail "the same findings changed something: $(cat "$GH_LOG")"
finding nodejs-24.22.3 'lang: nodejs 24.22.3 released' 'A new patch release of nodejs 24.22: **24.22.3**.'
file 2026-11-26 --complete || fail "file with a new finding: $(cat "$tmp/apply.out")"
[ "$(newest)" = "$w1" ] && [ "$(state_of "$w1" nodejs-24.22.3)" = new ] || fail "a new finding of the week: $(rows "$w1")"
echo "ok - the same week: the same findings change nothing, a new one is added to its issue"

# --- Language tests: the rows, their updates --------------------------------------------------------
gh issue list --state open > "$tmp/open.json"
[ "$(bash "$weekly" rows "$tmp/open.json" | jq -c '{issue, week, n: (.rows | length)}')" = '{"issue":49,"week":"2026-W48","n":7}' ] || fail "rows: $(bash "$weekly" rows "$tmp/open.json")"
# update ISSUE UPDATES_JSON — the report step of lang-test.yml
update() { gh issue view "$1" > "$tmp/w.json"; echo "$2" > "$tmp/u.json"; bash "$weekly" update "$tmp/w.json" "$tmp/u.json" > "$tmp/ops.json"; bash "$weekly" apply "$tmp/ops.json" > "$tmp/apply.out"; }
update "$w1" '[{"key": "go-1.27.4", "state": "testing", "note": "this run tests it", "run": "https://example.test/run/1"},
  {"key": "nodejs-24.22.3", "state": "testing", "run": "https://example.test/run/1"}, {"key": "no-such-row", "state": "testing"}]' || fail "update: $(cat "$tmp/apply.out")"
[ "$(state_of "$w1" go-1.27.4)" = testing ] && grep -qF '| `go-1.27.4` | lang: go 1.27.4 released | testing | this run tests it | [run](https://example.test/run/1) |' <<<"$(issue "$w1" | jq -r .body)" \
  || fail "testing: $(issue "$w1" | jq -r .body)"
jq -e '.[] | select(.op == "warn") | .text == "no row no-such-row in #49"' "$tmp/ops.json" >/dev/null || fail "an unknown row: $(cat "$tmp/ops.json")"
update "$w1" '[{"key": "go-1.27.4", "state": "published", "note": "main 0123456789ab; the publish workflow publishes go", "run": "https://example.test/run/1"},
  {"key": "nodejs-24.22.3", "state": "needs attention", "note": "e2e-test: failed: xaas-nodejs-24.22-http [ready]", "run": "https://example.test/run/1"},
  {"key": "python-3.10-eol", "state": "archived", "note": "exec-python:eol-3.10", "run": "https://example.test/run/1"},
  {"key": "php-8.2-eol", "state": "testing"}]' || fail "update: $(cat "$tmp/apply.out")"
[ "$(state_of "$w1" go-1.27.4)|$(state_of "$w1" nodejs-24.22.3)|$(state_of "$w1" python-3.10-eol)" = "published|needs attention|archived" ] \
  && [ "$(rows "$w1" | jq -r '.[] | select(.key == "php-8.2-eol") | .until')" = 2026-12-31 ] || fail "the results (an end of life keeps its date): $(rows "$w1")"
# a row of an earlier issue keeps where it came from; the label follows the rows
rows "$w1" | jq -e '.[] | select(.key == "ruby-4.0.10") | .from == 47' >/dev/null || fail "from"
update "$w1" '[{"key": "ruby-4.0.10", "state": "published"}, {"key": "nodejs-24.22.3", "state": "published"}, {"key": "php-8.2-eol", "state": "held", "note": "the bot archives the version after its end of life"}]' \
  || fail "update: $(cat "$tmp/apply.out")"
[ "$(labels_of "$w1")" = deps ] || fail "needs attention stayed: $(labels_of "$w1")"
[ "$(issue "$w1" | jq -r .state)" = OPEN ] || fail "closed with open rows"
echo "ok - Language tests: the open issue's rows, their state, note and run updated in place, the label needs attention following them"

# --- the next week: carried over, done, superseded --------------------------------------------------
rm -rf "$tmp/report"
finding maven-3.10.2 'lang: maven 3.10.2 released' 'A new release of maven: **3.10.2**.'
finding maven-3.10.3 'lang: maven 3.10.3 released' 'A new release of maven: **3.10.3**.'
finding php-8.2-eol 'lang: php 8.2 end of life 2026-12-31' 'php 8.2 reaches its end of life on 2026-12-31.'
finding ruby-4.0.11 'lang: ruby 4.0.11 released' 'A new patch release of ruby 4.0: **4.0.11**.'
finding go-1.27.4 'lang: go 1.27.4 released' 'A new patch release of go 1.27: **1.27.4**.'
# an incomplete watch: the alpine row (no finding now) is not done
file 2026-11-30 || fail "the next week: $(cat "$tmp/apply.out")"
w2="$(newest)"
[ "$w2" = 50 ] && [ "$(issue "$w2" | jq -r .title)" = 'deps: weekly (2026-W49)' ] || fail "the next week's issue: $(jq -c '[.[] | [.number, .title, .state]]' "$GH_STORE")"
[ "$(rows "$w2" | jq -c '[.[] | [.key, .state]] | sort')" = '[["base-alpine-3.24","a person'"'"'s decision"],["maven-3.10.3","new"],["php-8.2-eol","held"],["ruby-4.0.11","new"]]' ] \
  || fail "carried over and new: $(rows "$w2")"
# the older maven, open until now, superseded where it was: in the earlier week's issue
[ "$(state_of "$w1" maven-3.10.2)" = superseded ] && rows "$w1" | jq -e '.[] | select(.key == "maven-3.10.2") | .note | startswith("by `maven-3.10.3`")' >/dev/null \
  || fail "maven 3.10.2 not superseded: $(rows "$w1")"
# go 1.27.4 was published: found again, it is not added again
issue "$w1" | jq -e '.state == "CLOSED" and (.body | contains("Continued in #50."))' >/dev/null && grep -qxF 'Continued from #49.' <<<"$(issue "$w2" | jq -r .body)" \
  || fail "the earlier week not closed with its link: $(issue "$w1" | jq -r '.state, .body')"
[ "$(issue "$w1" | jq -r .body | sed -n '$p')" = '<!-- runr-lang:weekly:2026-W48 -->' ] || fail "the closed issue's marker"
# the earlier week's rows stay as they were: published ones in it alone
[ "$(state_of "$w1" go-1.27.4)" = published ] && [ -z "$(state_of "$w2" go-1.27.4)" ] || fail "a published row carried over"
echo "ok - the next week: its own issue with the open rows carried over and the new findings, the earlier one closed with a link, a finding of a done row not added again, the older release superseded"

# the complete watch of the same week: alpine is no longer found (its series mirrored): done
file 2026-12-01 --complete || fail "file complete: $(cat "$tmp/apply.out")"
[ "$(state_of "$w2" base-alpine-3.24)" = "done" ] && rows "$w2" | jq -e '.[] | select(.key == "base-alpine-3.24") | .note == "no longer found by the watch of 2026-12-01"' >/dev/null \
  || fail "not done: $(rows "$w2")"
echo "ok - a row the complete watch no longer finds is done, an incomplete watch marks none"

# --- every row done: closed; a quiet week; reopened -------------------------------------------------
update "$w2" '[{"key": "maven-3.10.3", "state": "published"}, {"key": "ruby-4.0.11", "state": "published"}, {"key": "php-8.2-eol", "state": "archived"}]' \
  || fail "update: $(cat "$tmp/apply.out")"
issue "$w2" | jq -e '.state == "CLOSED" and (.body | contains("Closed: every row is done."))' >/dev/null || fail "not closed when done: $(issue "$w2" | jq -r '.state, .body')"
rm -rf "$tmp/report"
mkdir -p "$tmp/report"
: > "$GH_LOG"
file 2026-12-02 --complete || fail "a quiet day: $(cat "$tmp/apply.out")"
[ -z "$(grep -vE '^list ' "$GH_LOG")" ] && [ "$(newest)" = "$w2" ] || fail "a quiet day did something: $(cat "$GH_LOG")"
finding bun-1.4.6 'lang: bun 1.4.6 released' 'A new patch release of bun 1.4: **1.4.6**.'
file 2026-12-03 --complete || fail "a new finding in a closed week: $(cat "$tmp/apply.out")"
[ "$(newest)" = "$w2" ] && [ "$(issue "$w2" | jq -r .state)" = OPEN ] && [ "$(state_of "$w2" bun-1.4.6)" = new ] \
  && ! grep -qF 'Closed: every row is done.' <<<"$(issue "$w2" | jq -r .body)" || fail "not reopened: $(issue "$w2" | jq -c '{state, body}')"
update "$w2" '[{"key": "bun-1.4.6", "state": "published"}]' || fail "update"
rm -rf "$tmp/report"
mkdir -p "$tmp/report"
: > "$GH_LOG"
file 2026-12-07 --complete || fail "a quiet week: $(cat "$tmp/apply.out")"
[ -z "$(grep -vE '^list ' "$GH_LOG")" ] && [ "$(newest)" = "$w2" ] || fail "a quiet week opened an issue: $(cat "$GH_LOG")"
echo "ok - an issue whose rows are all done closes, a quiet week opens none, this week's closed issue reopens for a new finding"

# --- two open weekly issues, a long issue, a failed operation -----------------------------------------
finding ruby-4.0.12 'lang: ruby 4.0.12 released' 'A new patch release of ruby 4.0: **4.0.12**.'
file 2026-12-14 --complete || fail "file: $(cat "$tmp/apply.out")"
w3="$(newest)"
# a race opened a second one with an open row
jq --argjson n "$((w3 + 1))" --arg b "$(issue "$w3" | jq -r .body | sed 's/ruby-4.0.12/dotnet-10.0.16/g; s/ruby 4.0.12/dotnet 10.0.16/g')" \
  '. + [{number: $n, title: "deps: weekly (2026-W51)", state: "OPEN", labels: [{name: "deps"}], body: $b}]' "$GH_STORE" > "$tmp/s" && mv "$tmp/s" "$GH_STORE"
file 2026-12-15 --complete || fail "file with two open: $(cat "$tmp/apply.out")"
[ "$(issue "$w3" | jq -r .state)" = CLOSED ] && grep -qF "Merged into #$((w3 + 1))" <<<"$(issue "$w3" | jq -r '.comments[0]')" \
  && [ "$(state_of "$((w3 + 1))" ruby-4.0.12)" = new ] || fail "not merged: $(jq -c '[.[] | select(.number >= '"$w3"') | {number, state, comments}]' "$GH_STORE")"
# a long issue: what each finding is goes, the rows stay
long="$(head -c 3000 /dev/zero | tr '\0' 'x')"
jq -n --arg about "$long" '{number: 90, title: "deps: weekly (2026-W51)", state: "OPEN", labels: [{name: "deps"}],
  body: ("x\n\n" + ([range(40)] | map("<!-- runr-lang:row " + ({key: "go-1.\(.).0", title: "lang: go 1.\(.).0 released", state: "new", about: $about} | tojson) + " -->") | join("\n"))
         + "\n\n<!-- runr-lang:weekly:2026-W51 -->\n")}' > "$tmp/long.json"
echo '[{"key": "go-1.3.0", "state": "testing"}]' > "$tmp/u.json"
bash "$weekly" update "$tmp/long.json" "$tmp/u.json" > "$tmp/ops.json"
jq -e '.[0].op == "edit" and (.[0].body | length) < 65536 and (.[0].body | contains("What each finding is") | not) and (.[0].body | contains("| `go-1.39.0` |"))' "$tmp/ops.json" >/dev/null \
  || fail "a long issue: $(jq -r '.[0].body | length' "$tmp/ops.json")"
# apply goes on after a failed operation, and says so
echo '[{"op": "close", "issue": 50, "reason": "completed"}, {"op": "label", "issue": 50, "label": "deps"}, {"op": "close", "issue": "{{weekly}}"}]' > "$tmp/ops.json"
: > "$GH_LOG"
rc=0; GH_FAIL=close bash "$weekly" apply "$tmp/ops.json" > "$tmp/apply.out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q '^close 50' "$GH_LOG" && grep -q '^edit 50 .*--add-label deps' "$GH_LOG" && [ "$(grep -c '^close' "$GH_LOG")" = 1 ] \
  && grep -qF '2 operation(s) failed or were skipped' "$tmp/apply.out" || fail "apply after a failure: exit ${rc} $(cat "$GH_LOG" "$tmp/apply.out")"
echo "ok - two open weekly issues merged into one, a long issue without what each finding is, apply goes on after a failed operation"
