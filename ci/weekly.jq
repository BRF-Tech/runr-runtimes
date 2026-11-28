# The language bot's weekly issue: the jq functions of ci/weekly.sh (README.md, The language bot).
# Included with jq -L ci 'include "weekly"; …'.
#
# The format:
#   - one issue per ISO week (UTC) with findings, titled "deps: weekly (2026-W48)", its body's last
#     line <!-- runr-lang:weekly:2026-W48 -->; a marker counts only as the body's last line (one
#     quoted in a person's text is none);
#   - a table "Row | Finding | State | Note | Run", one row per finding of ci.sh watch, its key the
#     name the watch gives it (ruby-4.0.10, php-8.2-eol, base-alpine-3.24: key_of), and under it
#     what each finding is (its first paragraph);
#   - each row's data in a hidden <!-- runr-lang:row {…} --> line, the week's in
#     <!-- runr-lang:meta {…} -->: {week, monday, sunday, previous, closing};
#   - State: new | testing | published | needs attention | upstream outage | held | a person's
#     decision | archived | superseded | done. Finished: published, archived, superseded, done,
#     and held without a date (an ML release without its CUDA wheel). Open: the others, and held
#     with a date ("held until <date>": an end-of-life notice, archived after it);
#   - closing: "Continued in #N." (a later week's issue took its open rows), "Closed: every row is
#     done."; a per-finding issue of the earlier bot, folded: "Folded into the weekly issue #N, row
#     `<key>` …".

def last_line: (. // "") | sub("\\s+$"; "") | split("\n") | last // "";
def weekly_week: last_line | (capture("^<!-- runr-lang:weekly:(?<w>[0-9]{4}-W[0-9]{2}) -->$")? | .w) // null;
def title_week: (. // "") | (capture("^deps: weekly \\((?<w>[0-9]{4}-W[0-9]{2})\\)$")? | .w) // null;
def weekly_title($w): "deps: weekly (\($w))";
def json_marker($name): "<!-- runr-lang:\($name) " + (tojson | gsub("-->"; "--\\u003e")) + " -->";
def markers($name): [(. // "") | scan("<!-- runr-lang:\($name) (\\{[^\n]*\\}) -->") | .[0] | fromjson? // empty];
def is_weekly: ((.body // "") | weekly_week) != null;

# a finding's key, from its title (the name of its report file, lib/watch.sh watch_report)
def key_of:
  if test("^lang: [a-z0-9-]+ [0-9]+\\.[0-9]+ end of life [0-9]{4}-[0-9]{2}-[0-9]{2}$") then
    capture("^lang: (?<n>[a-z0-9-]+) (?<v>[0-9]+\\.[0-9]+) ") | "\(.n)-\(.v)-eol"
  elif test("^lang: [a-z0-9-]+ [0-9]+(\\.[0-9]+)* released$") then
    capture("^lang: (?<n>[a-z0-9-]+) (?<v>[0-9][0-9.]*) released$") | "\(.n)-\(.v)"
  elif test("^base: [a-z0-9-]+ [0-9]+(\\.[0-9]+)*( \\([a-z]+\\))? available$") then
    capture("^base: (?<n>[a-z0-9-]+) (?<v>[0-9][0-9.]*)") | "base-\(.n)-\(.v)"
  else null end;
def kind_of: if test("^base: ") then "base" elif test(" end of life [0-9-]+$") then "eol" else "release" end;
def eol_date: (capture(" end of life (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})$")? | .d) // null;
# what a finding moves: a language version (python-3.13: its major.minor), a tool, an ML runtime,
# a toolchain (by name), a base image's series (base-alpine): of two open rows of one, the newer
# release supersedes the older
def image_of($languages):
  if test("^base: ") then capture("^base: (?<n>[a-z0-9-]+) ") | "base-\(.n)"
  elif test("^lang: [a-z0-9-]+ [0-9][0-9.]* released$") then
    capture("^lang: (?<n>[a-z0-9-]+) (?<v>[0-9][0-9.]*) released$")
    | if (.n | IN($languages[])) and (.v | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) then "\(.n)-\(.v | sub("\\.[0-9]+$"; ""))" else .n end
  else null end;
def version_of: (capture(" (?<v>[0-9][0-9.]*)( \\([a-z]+\\))? (released|available)$")? | .v) // null;
def vparts: split(".") | map(tonumber? // 0);
def vnewer($a; $b): ($a | vparts) > ($b | vparts);

def finished_states: ["published", "archived", "superseded", "done"];
def is_final: (.state as $s | finished_states | index($s) != null) or (.state == "held" and (.until // null) == null);
def is_open: is_final | not;

# ── issues ───────────────────────────────────────────────────────────────────
def parse_weekly:
  . as $i | ($i.body // "") as $b
  | {number: $i.number, state: ($i.state // "OPEN"), title: ($i.title // ""), labels: [$i.labels[]?.name],
     week: ($b | weekly_week), meta: (($b | markers("meta"))[0] // {}), rows: ($b | markers("row"))};
# a per-finding issue of the earlier bot ("lang: … released", "base: … available")
def parse_legacy:
  . as $i | ($i.title // "" | key_of) as $k
  | if $k == null or ($i | is_weekly) then empty
    else {number: $i.number, state: ($i.state // "OPEN"), title: $i.title, key: $k, labels: [$i.labels[]?.name]} end;

# ── rows ─────────────────────────────────────────────────────────────────────
def oneline: tostring | gsub("[\r\n]+"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def clip($n): if length > $n then .[:($n - 1)] + "…" else . end;
def tidy: with_entries(select(.value != null and .value != ""));
# a finding's row as it is found: an end of life is held until its date (the bot archives the
# version after it), a base image's series is a person's decision
def about_of: (. // "") | oneline | sub(":$"; ".") | clip(500);
def new_row($date):
  (.title | kind_of) as $k
  | {key, title, about: (.about | about_of), found: $date}
  + if $k == "base" then {state: "a person's decision", note: "mirror the series (REQS_IMAGES) and move the images, or let it wait: the row is done once the watch no longer finds it"}
    elif $k == "eol" then (.title | eol_date) as $d
      | if $d < $date then {state: "new"} else {state: "held", until: $d, note: "the bot archives the version after its end of life"} end
    else {state: "new"} end
  | tidy;
# the state a row of a folded issue starts with: its labels', else a new finding's
def legacy_state($row):
  if (.labels | index("needs attention")) then {state: "needs attention", note: "its issue's last comment says what failed"}
  elif (.labels | index("lang: upstream outage")) then {state: "upstream outage", note: "the next run tests it again"}
  elif (.labels | index("lang: passed")) then {state: "published", note: null}
  else ($row | {state, note, until}) end;

# ── the body ─────────────────────────────────────────────────────────────────
def rank: {"needs attention": 0, "upstream outage": 1, "a person's decision": 2, "testing": 3, "new": 4,
           "held": 5, "published": 6, "archived": 7, "superseded": 8, "done": 9}[.state] // 4;
def cell: tostring | gsub("\\|"; "\\|") | gsub("[\r\n]+"; " ");
def state_cell: if .state == "held" and (.until // null) != null then "held until \(.until)" else .state end;
def run_cell: if (.run // "") != "" then "[run](\(.run))" else "" end;
def note_cell: [(.note // empty), (if (.from // null) != null then "from #\(.from)" else empty end)] | join("; ");
def render($meta; $rows; $about):
  ($rows | sort_by(rank, .key)) as $rs
  | "What the language bot found and did in **\($meta.week)** (\($meta.monday // "?") to \($meta.sunday // "?"), UTC): one row per finding of `ci.sh watch`, with its state. The bots edit this issue as they work and write no comments here: **Language releases** (`lang-releases.yml`, Mondays) adds each finding once, **Language tests** (`lang-test.yml`, after it) tests the open releases and archives the versions past their end of life, and writes the result into the row (the run's summary has the logs). `needs attention`: a person fixes what failed, then runs **Actions → Language tests → Run workflow** with `rows` = the row's key (several: `ruby-4.0.10,go-1.27.4`). `a person's decision`: done once the watch no longer finds it. A row still open when the next week's issue opens moves there; an issue whose rows are all done closes. README.md → The language bot.\n\n"
  + (if ($meta.previous // null) != null then "Continued from #\($meta.previous).\n\n" else "" end)
  + (if ($rs | length) == 0 then "Nothing is open.\n"
     else "| Row | Finding | State | Note | Run |\n|---|---|---|---|---|\n"
       + ([$rs[] | "| `\(.key | cell)` | \(.title | cell) | \(state_cell | cell) | \(note_cell | cell) | \(run_cell) |"] | join("\n")) + "\n" end)
  + (if $about and ([$rs[] | select((.about // "") != "")] | length) > 0 then
       "\n<details><summary>What each finding is</summary>\n\n"
       + ([$rs[] | select((.about // "") != "") | "- `\(.key)`: \(.about)"] | join("\n")) + "\n\n</details>\n"
     else "" end)
  + (if ($meta.closing // "") != "" then "\n\($meta.closing)\n" else "" end)
  + "\n" + ($meta | json_marker("meta")) + "\n"
  + ([$rs[] | json_marker("row")] | join("\n")) + (if ($rs | length) > 0 then "\n" else "" end)
  + "\n<!-- runr-lang:weekly:\($meta.week) -->\n";
# GitHub takes 65536 characters: a long issue leaves out what each finding is
def render_fit($meta; $rows):
  render($meta; $rows; true) as $b | if ($b | length) > 60000 then render($meta; $rows | map(del(.about)); false) else $b end;

# the labels of a weekly issue: deps, and needs attention while a row needs a person
def labels_of($rows): ["deps"] + (if any($rows[]; .state == "needs attention") then ["needs attention"] else [] end);
def label_ops($n; $have; $rows):
  (labels_of($rows)) as $want
  | [($want - $have)[] | {op: "label", issue: $n, label: .}]
    + [(["needs attention"] - $want)[] | select(IN($have[])) | {op: "unlabel", issue: $n, label: .}];

# ── file: the watch's findings into the week's issue (lang-releases.yml) ──────
# input {findings: [{key, title, about}], issues: [every issue: number, title, state, labels, body],
# date, week: {week, monday, sunday}, complete: the watch read every upstream, languages: [ids]}
def file_main:
  . as $in
  | ($in.date) as $date
  | ($in.languages // []) as $L
  | [$in.issues[] | select(is_weekly) | parse_weekly] as $W
  | ([$W[] | select(.state == "OPEN")] | sort_by(.number) | reverse) as $open
  # the current issue: the newest open one, else the newest one (this week's closed one is reopened
  # when it has an open row again; an earlier week's rows a person closed it with go on)
  | (($open[0]) // ($W | sort_by(.number) | last) // null) as $cur
  | ([$open[1:][]]) as $others
  | ([$in.issues[] | parse_legacy]) as $legacy
  | ([$in.findings[] | select(.key != null)] | unique_by(.key)) as $F
  | ([$F[] | .key]) as $fkeys
  # once per key: a row any weekly issue has, or the title of a closed per-finding issue of the
  # earlier bot, is not added again
  | ([$W[] | .rows[] | .key] + [$legacy[] | select(.state != "OPEN") | .key] | unique) as $known
  | (($cur.rows // []) + [$others[] | .rows[] | select(is_open)] | unique_by(.key)) as $base
  | {rows: $base, ops: [], late: [], move: false, touched: []}

  # 1. the per-finding issues of the earlier bot still open: folded into the week's issue (the
  #    watch still finds them; with an incomplete watch, any) as a row in the state of its labels,
  #    closed with a pointer to it; one the watch no longer finds is closed as resolved
  | reduce ($legacy[] | select(.state == "OPEN")) as $l (.;
      if ($l.key | IN($fkeys[])) or ($in.complete | not) then
        ([$F[] | select(.key == $l.key)][0] // {key: $l.key, title: $l.title}) as $f
        | (if any(.rows[]; .key == $l.key) then .
           else .rows += [($f | new_row($date)) as $r | $r + ($l | legacy_state($r)) + {from: $l.number} | tidy] end)
        | .move = true | .touched += [$l.key]
        | .late += [{op: "close", issue: $l.number, reason: "not planned",
                     comment: "Folded into the weekly issue #{{weekly}}, row `\($l.key)`: the language bot keeps one issue per week (README.md, The language bot)."}]
      else
        .late += [{op: "close", issue: $l.number, reason: "completed",
                   comment: "Resolved: the watch of \($date) no longer finds it (README.md, The language bot)."}]
      end)

  # 2. the findings: one with a row keeps it (its title and what it is refreshed; a row done
  #    since is found again), one any weekly issue or earlier issue had is not added again
  | reduce $F[] as $f (.;
      if any(.rows[]; .key == $f.key) then
        .rows |= map(if .key == $f.key then
                       (. + {title: $f.title, about: ($f.about | about_of)})
                       | if .state == "done" then (.state = "new" | del(.note, .run)) else . end
                       | tidy
                     else . end)
      elif ($f.key | IN($known[])) then .
      else .rows += [$f | new_row($date)] | .move = true | .touched += [$f.key] end)

  # 3. of two open rows of one image, the newer release supersedes the older
  | . as $st
  | .rows |= map(. as $r
      | ($r.title | image_of($L)) as $img
      | if ($r | is_open) and ($r.title | kind_of) != "eol" and $img != null then
          ([$st.rows[] | select(.key != $r.key and is_open and (.title | image_of($L)) == $img
                                and vnewer(.title | version_of; $r.title | version_of))]
           | sort_by(.title | version_of | vparts) | last) as $by
          | if $by != null then . + {state: "superseded", note: "by `\($by.key)`: the bot tests the newest release only"} | del(.until) else . end
        else . end)

  # 4. a row the watch no longer finds (it read every upstream): done
  | (if $in.complete then
       .rows |= map(if is_open and ((.key | IN($fkeys[])) | not) then
                      . + {state: "done", note: "no longer found by the watch of \($date)"} | del(.until, .run)
                    else . end)
     else . end)

  # 5. the week's issue: this week's edited (reopened when it was closed); an earlier week's closed
  #    with a pointer, its open rows carried over into this week's issue with the new ones; none
  #    when nothing is open
  | . as $st
  | ([$st.rows[] | select(is_open)]) as $openrows
  | ($others | map({op: "close", issue: .number, reason: "completed",
                    comment: "Merged into #{{weekly}}: one weekly issue is open at a time."})) as $merge
  | if $cur == null then
      (if ($openrows | length) > 0 then
         [{op: "create", key: "weekly", title: weekly_title($in.week.week), labels: labels_of($st.rows),
           body: render_fit($in.week + {previous: null}; $st.rows)}]
       else [] end)
    elif $cur.week == $in.week.week then
      ($cur.meta + {week: $cur.week} | if ($openrows | length) == 0 then .closing = "Closed: every row is done." else del(.closing) end) as $m
      | [{op: "alias", key: "weekly", issue: $cur.number}]
      + (if $cur.state != "OPEN" and ($openrows | length) > 0 then [{op: "reopen", issue: $cur.number}] else [] end)
      + (if ($cur.rows | sort_by(.key)) != ($st.rows | sort_by(.key)) or ($cur.meta.closing // "") != ($m.closing // "") then
           [{op: "edit", issue: $cur.number, body: render_fit($m; $st.rows)}] else [] end)
      + (if $cur.state == "OPEN" or ($openrows | length) > 0 then label_ops($cur.number; $cur.labels; $st.rows) else [] end)
      + (if $cur.state == "OPEN" and ($openrows | length) == 0 then [{op: "close", issue: $cur.number, reason: "completed"}] else [] end)
    else
      # the earlier week's rows as this run left them; its open ones go on in this week's issue
      ([$cur.rows[] | .key]) as $mine
      | ([$st.rows[] | select(.key | IN($mine[]))]) as $old
      | ([$old[] | select(is_open)] | length > 0) as $carry
      | ($cur.meta + {week: $cur.week, closing: (if $carry then "Continued in #{{weekly}}." else "Closed: every row is done." end)}) as $om
      | (if ($openrows | length) > 0 then
           [{op: "create", key: "weekly", title: weekly_title($in.week.week), labels: labels_of($openrows),
             body: render_fit($in.week + {previous: (if $carry then $cur.number else null end)}; $openrows)}]
         else [] end)
      + (if ($cur.rows | sort_by(.key)) != ($old | sort_by(.key)) or ($cur.meta.closing // "") != $om.closing then
           [{op: "edit", issue: $cur.number, body: render_fit($om; $old)}] else [] end)
      + (if $cur.state == "OPEN" then [{op: "close", issue: $cur.number, reason: "completed"}] else [] end)
      + [(["needs attention"][] | select(IN($cur.labels[]))) | {op: "unlabel", issue: $cur.number, label: .}]
    end
  | . + $st.late + (if any(.[]; .key? == "weekly") then $merge else [] end)
  # nothing to point at (no issue this week): what needs its number waits for the next run
  | if any(.[]; .key? == "weekly") then . else map(select(((.comment // "") + (.body // "")) | contains("{{weekly}}") | not)) end;

# ── rows: the open weekly issue's rows (lang-test.yml's plan) ────────────────
# input: the open issues (gh issue list --json number,title,state,labels,body)
def rows_main:
  ([.[] | select(is_weekly and (.state // "OPEN") == "OPEN") | parse_weekly] | sort_by(.number) | last) as $w
  | if $w == null then {issue: null, week: null, rows: []} else {issue: $w.number, week: $w.week, rows: $w.rows} end;

# ── update: a run's results into the weekly issue's rows (lang-test.yml) ────
# input {issue: gh issue view --json number,title,state,labels,body, updates: [{key, state, note,
# run}]}: each row of a key takes its state, and its note and run (none: the row's go; an end of
# life keeps its date); an issue whose rows are all done closes
def update_main:
  . as $in
  | ($in.issue | parse_weekly) as $w
  | (reduce $in.updates[] as $u ($w.rows;
      map(if .key == $u.key then
            (del(.note, .run) + ($u | {state, note, run} | tidy))
          else . end))) as $rows
  | ([$rows[] | select(is_open)] | length) as $n
  | ($w.meta + {week: $w.week} | if $n == 0 then .closing = "Closed: every row is done." else del(.closing) end) as $m
  | (if ($rows | sort_by(.key)) != ($w.rows | sort_by(.key)) or ($w.meta.closing // "") != ($m.closing // "") then
       [{op: "edit", issue: $w.number, body: render_fit($m; $rows)}] else [] end)
    + (if $w.state == "OPEN" then label_ops($w.number; $w.labels; $rows) else [] end)
    + (if $w.state == "OPEN" and $n == 0 then [{op: "close", issue: $w.number, reason: "completed"}] else [] end)
    + [$in.updates[] | select(.key as $k | any($w.rows[]; .key == $k) | not) | {op: "warn", text: "no row \(.key) in #\($w.number)"}];
