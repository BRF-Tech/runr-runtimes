#!/usr/bin/env bash
# Tests ci/lang-bot.sh, the language bot's steps, without GitHub, PyPI or RunR: issues are a JSON
# file as `gh issue list` writes it, PyPI answers from fixtures (WATCH_FIXTURES), RunR is a throwaway
# checkout with its catalog, main a bare git repository. Checks that:
#   - the plan tests the newest release of each language version and ML runtime, supersedes the
#     older ones, labels a WebAssembly toolchain for a person, skips an end-of-life notice, a
#     passed issue and one that waits for a person unless the run names it;
#   - an ML bump moves torch with the torchvision that requires it, and tensorflow's CPU and CUDA
#     pins together;
#   - tested-versions gets one line per version, in order, the header kept;
#   - RunR's catalog offers the runtime at the candidate alone, the e2e check finds the candidate's
#     xaas cases and their failures, and RunR's pins of a discovered runtime are none;
#   - landing: a green version is committed on top of main and pushed as a fast-forward with the
#     bot's identity, a red one labelled with what failed, a version whose runtime changed on main
#     since the tested commit is left for the next run.
#
#   bash test/lang_bot_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip: lang_bot_test needs jq"; exit 0; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=someone GIT_AUTHOR_EMAIL=someone@example.test GIT_COMMITTER_NAME=someone GIT_COMMITTER_EMAIL=someone@example.test

# a throwaway copy of this repository's files the bot reads and writes
repo="$tmp/repo"
mkdir -p "$repo"
cp -r "$here/ci" "$here/lib" "$repo/"
mkdir -p "$repo/runtimes"
for rt in python nodejs go php pytorch tensorflow; do cp -r "$here/runtimes/$rt" "$repo/runtimes/"; done
bot="$repo/ci/lang-bot.sh"

# --- the plan ---------------------------------------------------------------------------------------
cat > "$tmp/issues.json" <<'EOF'
[
  {"number": 30, "title": "lang: python 3.13.10 released", "labels": []},
  {"number": 25, "title": "lang: python 3.13.9 released", "labels": [{"name": "needs attention"}]},
  {"number": 31, "title": "lang: python 3.16.0 released", "labels": []},
  {"number": 32, "title": "lang: nodejs 24.23.0 released", "labels": [{"name": "needs attention"}]},
  {"number": 33, "title": "lang: pytorch 2.15.0 released", "labels": []},
  {"number": 34, "title": "lang: tinygo 0.43.0 released", "labels": []},
  {"number": 35, "title": "lang: python 3.10 end of life 2026-10-31", "labels": []},
  {"number": 36, "title": "lang: php 8.3.28 released", "labels": [{"name": "lang: passed"}]},
  {"number": 37, "title": "lang: python 3.16 released", "labels": []},
  {"number": 38, "title": "deps: something else", "labels": []}
]
EOF
plan="$(bash "$bot" plan "$tmp/issues.json")"
[ "$(jq -c '[.tests[] | [.issue, .kind, .runtime, .version, .full, .key]] | sort' <<<"$plan")" = '[[30,"language","python","3.13","3.13.10","python-3.13"],[31,"language","python","3.16","3.16.0","python-3.16"],[33,"ml","pytorch","2.15.0","2.15.0","pytorch"]]' ] \
  || fail "tests: $(jq -c .tests <<<"$plan")"
[ "$(jq -c '[.superseded[] | [.issue, .by]]' <<<"$plan")" = '[[25,30]]' ] || fail "superseded: $(jq -c .superseded <<<"$plan")"
[ "$(jq -c '[.attention[].issue]' <<<"$plan")" = '[34]' ] || fail "attention: $(jq -c .attention <<<"$plan")"
for i in 32 35 36 37; do jq -e --argjson i "$i" '.skipped[] | select(.issue == $i)' <<<"$plan" >/dev/null || fail "#${i} not skipped: $plan"; done
plan="$(bash "$bot" plan "$tmp/issues.json" --only=32)"
[ "$(jq -c '[.tests[].issue]' <<<"$plan")" = '[32]' ] && [ "$(jq -c .retrigger <<<"$plan")" = '[32]' ] || fail "--only: $plan"
bash "$bot" plan "$tmp/issues.json" --only='1;x' >/dev/null 2>&1 && fail "--only takes numbers only"
echo "ok - the plan: the newest release per language version and ML runtime, the older superseded, toolchains for a person, end of life, passed and held issues skipped"

# --- ML bump ----------------------------------------------------------------------------------------
export WATCH_FIXTURES="$tmp/fixtures"
mkdir -p "$WATCH_FIXTURES"
fx() { printf '%s\n' "$2" > "${WATCH_FIXTURES}/${1//[^A-Za-z0-9._-]/_}"; }
fx https://pypi.org/pypi/torchvision/json '{"releases": {"0.29.1": [], "0.30.0": [], "0.30.1": [], "0.31.0rc1": []}}'
fx https://pypi.org/pypi/torchvision/0.30.1/json '{"info": {"requires_dist": ["numpy", "torch (==2.15.1)"]}}'
fx https://pypi.org/pypi/torchvision/0.30.0/json '{"info": {"requires_dist": ["numpy", "torch==2.15.0"]}}'
fx https://pypi.org/pypi/torchvision/0.29.1/json '{"info": {"requires_dist": ["torch==2.14.1"]}}'
out="$(bash "$bot" ml-bump pytorch 2.15.0)" || fail "ml-bump pytorch: ${out}"
grep -qxF 'torch==2.15.0' "$repo/runtimes/pytorch/requirements-torch.txt" && grep -qxF 'torchvision==0.30.0' "$repo/runtimes/pytorch/requirements-torch.txt" \
  || fail "the torch pins: $(cat "$repo/runtimes/pytorch/requirements-torch.txt")"
rc=0; bash "$bot" ml-bump pytorch 2.16.0 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a torch without its torchvision: exit ${rc}"
bash "$bot" ml-bump tensorflow 2.22.0 >/dev/null || fail "ml-bump tensorflow"
grep -qxF 'tensorflow-cpu==2.22.0' "$repo/runtimes/tensorflow/requirements-cpu.txt" && grep -qxF 'tensorflow[and-cuda]==2.22.0' "$repo/runtimes/tensorflow/requirements-cuda.txt" \
  || fail "the tensorflow pins"
bash "$bot" ml-bump python 3.16.0 >/dev/null 2>&1 && fail "ml-bump of a language"
echo "ok - an ML bump: torch with the torchvision that requires it, tensorflow's CPU and CUDA pins together"

# --- tested-versions --------------------------------------------------------------------------------
f="$repo/runtimes/python/tested-versions"
bash "$bot" tested python 3.16 3.16.0
bash "$bot" tested python 3.13 3.13.9
bash "$bot" tested python 3.13 3.13.10
[ "$(grep -v '^#' "$f" | tr '\n' '|')" = '3.13 3.13.10|3.16 3.16.0|' ] || fail "tested-versions: $(cat "$f")"
[ "$(grep -c '^#' "$f")" = "$(grep -c '^#' "$here/runtimes/python/tested-versions")" ] || fail "the header changed"
bash "$bot" tested python 3.13 3.14.1 2>/dev/null && fail "a release of another version"
bash "$bot" tested pytorch 2.15 2.15.0 2>/dev/null && fail "tested-versions of an ML runtime"
echo "ok - tested-versions: one line per version, in order, the header kept"

# --- RunR: the catalog, the e2e check, the pins -----------------------------------------------------
runr="$tmp/runr"
mkdir -p "$runr/api/resources/runtimes" "$runr/runtime/lib" "$runr/api/config"
cat > "$runr/api/resources/runtimes/builtin.json" <<'EOF'
{"_comment": "bundled", "runtimes": {
  "python": {"id": "python", "versionDiscovery": {"repository": "ghcr.io/brf-tech/runr/exec-python", "image": "ghcr.io/brf-tech/runr/exec-python:{version}", "eol": "python"}},
  "nodejs": {"id": "nodejs", "versionDiscovery": {"repository": "ghcr.io/brf-tech/runr/exec-nodejs", "image": "x", "eol": "nodejs"}},
  "wasm-rust": {"id": "wasm-rust", "versions": [{"version": "4.1", "image": "ghcr.io/brf-tech/runr/exec-wasm-rust:4.1", "default": true}]}}}
EOF
printf 'APP_KEY=\n' > "$runr/api/.env.docker"
echo 'WASM_RUNTIME_VERSION="${WASM_RUNTIME_VERSION:-4.1}"' > "$runr/runtime/lib/runtime-images.sh"
bash "$bot" catalog "$runr" python 3.16 ghcr.io/brf-tech/runr/candidates/exec-python:3.16.0 || fail "catalog"
[ "$(jq -c '.runtimes.python | {versionDiscovery, versions}' "$runr/api/resources/runtimes/builtin.json")" = '{"versionDiscovery":null,"versions":[{"version":"3.16","image":"ghcr.io/brf-tech/runr/candidates/exec-python:3.16.0","default":true}]}' ] \
  || fail "the catalog: $(jq -c .runtimes.python "$runr/api/resources/runtimes/builtin.json")"
jq -e '.runtimes.nodejs.versionDiscovery' "$runr/api/resources/runtimes/builtin.json" >/dev/null || fail "another runtime changed"
grep -qxF 'EXECUTOR_RUNTIMES=python' "$runr/api/.env.docker" || fail "EXECUTOR_RUNTIMES: $(cat "$runr/api/.env.docker")"
cp "$runr/api/resources/runtimes/builtin.json" "$tmp/builtin.json"
bash "$bot" catalog "$runr" nodejs 24.23 ghcr.io/brf-tech/runr/candidates/exec-nodejs:24.23.0 || fail "catalog nodejs"
grep -qxF 'EXECUTOR_RUNTIMES=python,nodejs' "$runr/api/.env.docker" || fail "another runtime keeps Python for the rt-* cases: $(cat "$runr/api/.env.docker")"
cp "$tmp/builtin.json" "$runr/api/resources/runtimes/builtin.json"
bash "$bot" catalog "$runr" ruby 3.4 x 2>/dev/null && fail "a runtime the catalog does not have"
cat > "$tmp/results.md" <<'EOF'
## Results

| Test | Version | Deploy | Ready | Verify | Time |
|------|---------|--------|-------|--------|------|
| xaas-python-3.16-http | ✓ | ✓ | ✓ | ✓ | 20s |
| xaas-python-3.16-schedule | ✓ | ✓ | ✓ | ✓ | 20s |
| xaas-python-3.16-queue | ✓ | ✓ | ✓ | ✓ | 20s |
| faas-python-3.16-http | ✓ | ✓ | ✓ | ✓ | 60s |
EOF
bash "$bot" check-e2e "$tmp/results.md" python 3.16 >/dev/null || fail "check-e2e: the candidate's cases passed"
bash "$bot" check-e2e "$tmp/results.md" python 3.15 >/dev/null 2>&1 && fail "check-e2e: another version passed"
printf '\n## Failures\n\n- **faas-python-3.16-http** [ready]: timed out\n' >> "$tmp/results.md"
bash "$bot" check-e2e "$tmp/results.md" python 3.16 >/dev/null 2>&1 && fail "check-e2e: a failure passed"
[ "$(bash "$bot" runr-pins "$runr" nodejs)" = discovered ] || fail "runr-pins of a discovered runtime"
rc=0; bash "$bot" runr-pins "$runr" wasm-rust >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "runr-pins of a pinned runtime: exit ${rc}"
echo "ok - RunR: the catalog offers the candidate alone, the e2e check finds its cases and failures, a discovered runtime has no pins"

# --- landing ----------------------------------------------------------------------------------------
origin="$tmp/origin.git"
git init -q --bare -b main "$origin"
work="$tmp/work"
git init -q -b main "$work"
cp -r "$here/runtimes/python" "$here/runtimes/pytorch" "$work/" 2>/dev/null
mkdir -p "$work/runtimes" && mv "$work/python" "$work/pytorch" "$work/runtimes/"
cp -r "$repo/ci" "$work/"
(cd "$work" && git add -A && git commit -q -m base && git remote add origin "$origin" && git push -q origin main)
tested="$(git -C "$work" rev-parse HEAD)"
dir="$tmp/lang"
mkdir -p "$dir/results" "$dir/pins"
cat > "$dir/tests.json" <<'EOF'
[{"issue": 31, "kind": "language", "runtime": "python", "version": "3.16", "full": "3.16.0", "key": "python-3.16"},
 {"issue": 30, "kind": "language", "runtime": "python", "version": "3.13", "full": "3.13.10", "key": "python-3.13"},
 {"issue": 33, "kind": "ml", "runtime": "pytorch", "version": "2.15.0", "full": "2.15.0", "key": "pytorch"}]
EOF
result() { mkdir -p "$dir/results/lang-result-$1"; echo "$2" > "$dir/results/lang-result-$1/status"; echo "$tested" > "$dir/results/lang-result-$1/sha"; echo "the end of the $1 log" > "$dir/results/lang-result-$1/tail.txt"; }
result python-3.16-build success
echo ghcr.io/brf-tech/runr/candidates/exec-python:3.16.0 > "$dir/results/lang-result-python-3.16-build/image"
printf '3.13\n3.15\n' > "$dir/results/lang-result-python-3.16-build/published"
result python-3.16-e2e success
result python-3.13-build success
result python-3.13-e2e failure
result pytorch-build success
(cd "$work" && sed -i 's/^torch==.*/torch==2.15.0/' runtimes/pytorch/requirements-torch.txt && git diff > "$dir/results/lang-result-pytorch-build/pin.patch" && git checkout -q -- .)
echo "torch 2.15.0, torchvision 0.30.0" > "$dir/results/lang-result-pytorch-build/pin"
echo "pins no version of python: it discovers them in the registry, nothing to move" > "$dir/pins/python"
(cd "$work" && LANG_BOT_NAME="RunR deps bot" LANG_BOT_EMAIL="deps-bot@runr.sh" bash ci/lang-bot.sh land "$dir" https://example.test/run/9) > "$tmp/out" 2>&1 \
  || fail "land: $(cat "$tmp/out")"
log="$(git --git-dir="$origin" log --format='%an <%ae>|%cn <%ce>|%s' main)"
[ "$(head -n 2 <<<"$log")" = "RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|fix(pytorch): torch 2.15.0, torchvision 0.30.0
RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|feat(python): python 3.16 (3.16.0)" ] || fail "main: ${log}"
[ "$(git --git-dir="$origin" show main:runtimes/python/tested-versions | grep -v '^#')" = "3.16 3.16.0" ] || fail "main's tested-versions"
git --git-dir="$origin" show main:runtimes/pytorch/requirements-torch.txt | grep -qxF 'torch==2.15.0' || fail "main's torch pin"
[ "$(git --git-dir="$origin" for-each-ref --format='%(refname)')" = refs/heads/main ] || fail "other refs pushed"
actions="$(cat "$dir/actions")"
grep -qF "$(printf 'label\t31\tlang: passed')" <<<"$actions" && grep -qF "$(printf 'publish\tpython')" <<<"$actions" || fail "green: ${actions}"
grep -qF "$(printf 'label\t30\tneeds attention')" <<<"$actions" || fail "red: ${actions}"
grep -qF 'the end of the python-3.13-e2e log' "$dir/comments/30.md" || fail "red: the log: $(cat "$dir/comments/30.md")"
grep -qF 'nothing to move' "$dir/comments/31.md" || fail "green: RunR's pins: $(cat "$dir/comments/31.md")"
grep -qF "$(printf 'publish\tpytorch')" <<<"$actions" || fail "ml: no publish"
echo "ok - landing: green versions on main as fast-forwards with the bot's identity and their publish, a red one labelled with its log"

# main changed the runtime since the tested commit: left for the next run
(cd "$work" && git fetch -q origin && git checkout -q --detach origin/main && echo "# changed" >> runtimes/python/Dockerfile && git commit -q -am "python: a change" && git push -q origin HEAD:refs/heads/main)
cat > "$dir/tests.json" <<'EOF'
[{"issue": 40, "kind": "language", "runtime": "python", "version": "3.17", "full": "3.17.0", "key": "python-3.17"}]
EOF
result python-3.17-build success
result python-3.17-e2e success
before="$(git --git-dir="$origin" rev-parse main)"
(cd "$work" && LANG_BOT_NAME=b LANG_BOT_EMAIL=b@example.test bash ci/lang-bot.sh land "$dir" https://example.test/run/10) > "$tmp/out" 2>&1 || fail "land: $(cat "$tmp/out")"
[ "$(git --git-dir="$origin" rev-parse main)" = "$before" ] || fail "committed on a main whose runtime changed"
grep -qF 'main changed `runtimes/python/`' "$dir/comments/40.md" || fail "the comment: $(cat "$dir/comments/40.md")"
echo "ok - a version whose runtime changed on main since the tested commit is left for the next run"
