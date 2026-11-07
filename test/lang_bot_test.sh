#!/usr/bin/env bash
# Tests ci/lang-bot.sh, the language bot's steps, without GitHub, PyPI or RunR: issues are a JSON
# file as `gh issue list` writes it, PyPI, GitHub's release assets and ziglang.org answer from
# fixtures (WATCH_FIXTURES), RunR is a throwaway checkout with its catalog, main a bare git
# repository. Checks that:
#   - the plan tests the newest release of each language version (every runtime of RUNTIME_DEFS),
#     tool of a language image, ML runtime and WebAssembly toolchain with the RunR suites that
#     deploy its images, supersedes the older ones, skips an end-of-life notice, a passed issue, one
#     of a runtime it does not know and one that waits for a person unless the run names it;
#   - an ML bump moves torch with the torchvision that requires it, and tensorflow's CPU and CUDA
#     pins together;
#   - a toolchain bump moves its ARG in every WebAssembly Dockerfile that has it, with the SHA256
#     of its downloads, and the reqs mirror's base image of tinygo and rust; a download it cannot
#     check changes nothing;
#   - a tool bump moves Maven's ARG with the SHA-512 of its download, which must be the published
#     one, and the dependency plugin's ARG; nothing without a matching checksum;
#   - tested-versions gets one line per version, in order, the header kept;
#   - a lifecycle entry (deprecated today, its sunset 13 weeks later) goes into
#     versionDiscovery.lifecycle once per version;
#   - RunR's catalog offers the runtime at the candidate alone, the e2e check finds the candidate's
#     xaas cases (an ML runtime: its ML case) and their failures, and RunR's pins of a discovered
#     runtime are none; a runtime RunR's release does not have is exit 3 for both;
#   - landing: a green version, ML pin or toolchain is committed on top of main and pushed as a
#     fast-forward with the bot's identity (a tool's pin too, a new Bun minor with the lifecycle of
#     the one before), a suite RunR's release does not have yet counts as skipped, a red one or one
#     without a result is labelled with what failed, a version whose
#     runtime changed on main since the tested commit is left for the next run.
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
for rt in python nodejs go php java dotnet ruby bun pytorch tensorflow wasm-exec wasm-go wasm-js wasm-python wasm-rust; do cp -r "$here/runtimes/$rt" "$repo/runtimes/"; done
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
  {"number": 38, "title": "deps: something else", "labels": []},
  {"number": 39, "title": "lang: spin 4.2.0 released", "labels": []},
  {"number": 29, "title": "lang: spin 4.1.1 released", "labels": []},
  {"number": 41, "title": "lang: componentize-py 0.26.0 released", "labels": []},
  {"number": 42, "title": "lang: cobol 3.5.0 released", "labels": []},
  {"number": 44, "title": "lang: java 25.0.6 released", "labels": []},
  {"number": 45, "title": "lang: maven 3.9.17 released", "labels": []},
  {"number": 46, "title": "lang: maven 3.9.18 released", "labels": []},
  {"number": 47, "title": "lang: bun 1.5.0 released", "labels": []},
  {"number": 48, "title": "lang: maven-dependency-plugin 3.12.0 released", "labels": []},
  {"number": 49, "title": "lang: maven 3.9 released", "labels": []}
]
EOF
plan="$(bash "$bot" plan "$tmp/issues.json")"
[ "$(jq -c '[.tests[] | [.issue, .kind, .runtime, .version, .full, .key]] | sort' <<<"$plan")" = '[[30,"language","python","3.13","3.13.10","python-3.13"],[31,"language","python","3.16","3.16.0","python-3.16"],[33,"ml","pytorch","2.15","2.15.0","pytorch"],[34,"wasm","tinygo","0.43.0","0.43.0","wasm-tinygo"],[39,"wasm","spin","4.2.0","4.2.0","wasm-spin"],[41,"wasm","componentize-py","0.26.0","0.26.0","wasm-componentize-py"],[44,"language","java","25.0","25.0.6","java-25.0"],[46,"tool","maven","3.9.18","3.9.18","java-maven"],[47,"language","bun","1.5","1.5.0","bun-1.5"],[48,"tool","maven-dependency-plugin","3.12.0","3.12.0","java-maven-dependency-plugin"]]' ] \
  || fail "tests: $(jq -c .tests <<<"$plan")"
# the suites: the main e2e of a language and of a tool's image, its ML case, the WebAssembly suites
# that deploy the images of a toolchain (none for wasm-python's, which only the smoke test checks)
[ "$(jq -c '[.tests[] | [.key, .suites]]' <<<"$plan")" = '[["bun-1.5",["test"]],["java-25.0",["test"]],["java-maven",["test"]],["java-maven-dependency-plugin",["test"]],["python-3.13",["test"]],["python-3.16",["test"]],["pytorch",["test-ml"]],["wasm-componentize-py",[]],["wasm-spin",["test-wasm","test-images"]],["wasm-tinygo",["test-images"]]]' ] \
  || fail "suites: $(jq -c '[.tests[] | [.key, .suites]]' <<<"$plan")"
[ "$(jq -c '[.superseded[] | [.issue, .by]] | sort' <<<"$plan")" = '[[25,30],[29,39],[45,46]]' ] || fail "superseded: $(jq -c .superseded <<<"$plan")"
[ "$(jq -c .attention <<<"$plan")" = '[]' ] || fail "attention: $(jq -c .attention <<<"$plan")"
for i in 32 35 36 37 42 49; do jq -e --argjson i "$i" '.skipped[] | select(.issue == $i)' <<<"$plan" >/dev/null || fail "#${i} not skipped: $plan"; done
plan="$(bash "$bot" plan "$tmp/issues.json" --only=32)"
[ "$(jq -c '[.tests[].issue]' <<<"$plan")" = '[32]' ] && [ "$(jq -c .retrigger <<<"$plan")" = '[32]' ] || fail "--only: $plan"
bash "$bot" plan "$tmp/issues.json" --only='1;x' >/dev/null 2>&1 && fail "--only takes numbers only"
echo "ok - the plan: the newest release per language version (Java, .NET, Ruby, Bun too), tool, ML runtime and toolchain with its RunR suites, the older superseded, end of life, passed, unknown and held issues skipped"

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

# --- WebAssembly toolchain bump ---------------------------------------------------------------------
sum() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }
arg_of() { sed -n "s/^ARG $2=//p" "$repo/runtimes/$1/Dockerfile"; }
# spin: every image has it; the checksums of its release assets
fx https://github.com/spinframework/spin/releases/download/v4.2.0/spin-v4.2.0-static-linux-amd64.tar.gz 'spin amd64'
fx https://github.com/spinframework/spin/releases/download/v4.2.0/spin-v4.2.0-static-linux-aarch64.tar.gz 'spin arm64'
out="$(bash "$bot" wasm-bump spin 4.2.0)" || fail "wasm-bump spin: ${out}"
[ "$out" = '{"pin":"spin 4.2.0 (was 4.1.0)","images":["wasm-exec","wasm-go","wasm-js","wasm-python","wasm-rust"],"mirror":[]}' ] || fail "wasm-bump spin: ${out}"
for img in wasm-exec wasm-go wasm-js wasm-python wasm-rust; do
  [ "$(arg_of "$img" SPIN_VERSION)|$(arg_of "$img" SPIN_SHA256_AMD64)|$(arg_of "$img" SPIN_SHA256_ARM64)" = "4.2.0|$(sum 'spin amd64')|$(sum 'spin arm64')" ] \
    || fail "spin in ${img}: $(grep '^ARG SPIN' "$repo/runtimes/$img/Dockerfile")"
done
# zig: wasm-exec alone; the checksums of ziglang.org's index
fx https://ziglang.org/download/index.json "{\"0.17.0\": {\"x86_64-linux\": {\"shasum\": \"$(printf 'a%.0s' {1..64})\"}, \"aarch64-linux\": {\"shasum\": \"$(printf 'b%.0s' {1..64})\"}}}"
out="$(bash "$bot" wasm-bump zig 0.17.0)" || fail "wasm-bump zig: ${out}"
[ "$(jq -c .images <<<"$out")" = '["wasm-exec"]' ] && [ "$(arg_of wasm-exec ZIG_VERSION)|$(arg_of wasm-exec ZIG_SHA256_AMD64)" = "0.17.0|$(printf 'a%.0s' {1..64})" ] \
  || fail "zig: ${out} $(grep '^ARG ZIG' "$repo/runtimes/wasm-exec/Dockerfile")"
# tinygo and rust: their base image follows in the reqs mirror, the old line goes, others stay
out="$(bash "$bot" wasm-bump tinygo 0.43.0)" || fail "wasm-bump tinygo: ${out}"
[ "$out" = '{"pin":"tinygo 0.43.0 (was 0.42.0)","images":["wasm-exec","wasm-go"],"mirror":["tinygo:0.43.0"]}' ] || fail "wasm-bump tinygo: ${out}"
grep -qxF '  "tinygo:0.43.0|tinygo/tinygo:0.43.0"' "$repo/lib/mirror.sh" && ! grep -qF '"tinygo:0.42.0|' "$repo/lib/mirror.sh" \
  || fail "tinygo's mirror line: $(grep tinygo "$repo/lib/mirror.sh")"
old_rust="$(arg_of wasm-rust RUST_VERSION)"
out="$(bash "$bot" wasm-bump rust 1.99.0)" || fail "wasm-bump rust: ${out}"
[ "$(jq -c '[.images, .mirror]' <<<"$out")" = '[["wasm-rust"],["rust:1.99.0-slim-bookworm"]]' ] || fail "wasm-bump rust: ${out}"
grep -qxF '  "rust:1.99.0-slim-bookworm|rust:1.99.0-slim-bookworm"' "$repo/lib/mirror.sh" && ! grep -qF "\"rust:${old_rust}-slim-bookworm|" "$repo/lib/mirror.sh" \
  || fail "rust's mirror line: $(grep 'rust:' "$repo/lib/mirror.sh")"
[ "$(grep -c '"rust:' "$repo/lib/mirror.sh")" = "$(grep -c '"rust:' "$here/lib/mirror.sh")" ] || fail "rust's other mirror lines changed"
# a download it cannot check (no fixture) changes nothing; a tool it does not know is refused
before="$(cat "$repo"/runtimes/wasm-*/Dockerfile | sha256sum)"
rc=0; bash "$bot" wasm-bump wasi-sdk 35 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ "$(cat "$repo"/runtimes/wasm-*/Dockerfile | sha256sum)" = "$before" ] || fail "wasi-sdk without its checksums: exit ${rc}"
bash "$bot" wasm-bump python 3.16.0 >/dev/null 2>&1 && fail "wasm-bump of a language"
echo "ok - a toolchain bump: its ARG in every image that has it with the checksums of its downloads, the mirrored base image of tinygo and rust, nothing without a checksum"

# --- a tool of a language image ---------------------------------------------------------------------
sha512() { printf '%s\n' "$1" | sha512sum | cut -d' ' -f1; }
maven() { echo "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$1/apache-maven-$1-bin.tar.gz"; }
fx "$(maven 3.9.17)" 'maven 3.9.17'
fx "$(maven 3.9.17).sha512" "$(sha512 'maven 3.9.17')"
out="$(bash "$bot" tool-bump maven 3.9.17)" || fail "tool-bump maven: ${out}"
[ "$out" = '{"pin":"maven 3.9.17 (was 3.9.16)","image":"java","images":["java"]}' ] || fail "tool-bump maven: ${out}"
[ "$(arg_of java MAVEN_VERSION)|$(arg_of java MAVEN_SHA512)" = "3.9.17|$(sha512 'maven 3.9.17')" ] \
  || fail "maven in exec-java: $(grep '^ARG MAVEN' "$repo/runtimes/java/Dockerfile")"
# the dependency plugin: no download of its own (Maven checks what it fetches)
out="$(bash "$bot" tool-bump maven-dependency-plugin 3.12.0)" || fail "tool-bump maven-dependency-plugin: ${out}"
[ "$(jq -r .pin <<<"$out")|$(arg_of java MAVEN_DEPENDENCY_PLUGIN)" = "maven-dependency-plugin 3.12.0 (was 3.11.0)|3.12.0" ] \
  || fail "the dependency plugin: ${out} $(grep '^ARG MAVEN_DEPENDENCY' "$repo/runtimes/java/Dockerfile")"
# a download whose SHA-512 is not the published one, or without one, changes nothing
fx "$(maven 3.9.18)" 'maven 3.9.18'
fx "$(maven 3.9.18).sha512" "$(sha512 'something else')"
fx "$(maven 3.9.19)" 'maven 3.9.19'
before="$(sha256sum < "$repo/runtimes/java/Dockerfile")"
for v in 3.9.18 3.9.19 3.9.20; do
  rc=0; bash "$bot" tool-bump maven "$v" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ "$(sha256sum < "$repo/runtimes/java/Dockerfile")" = "$before" ] || fail "maven ${v} without its published checksum: exit ${rc}"
done
bash "$bot" tool-bump spin 4.2.0 >/dev/null 2>&1 && fail "tool-bump of a WebAssembly toolchain"
bash "$bot" tool-bump maven 3.10 >/dev/null 2>&1 && fail "tool-bump of a version that is no release"
echo "ok - a tool bump: Maven's ARG with the SHA-512 of its download, the published one; the dependency plugin's ARG; nothing without a matching checksum"

# --- tested-versions --------------------------------------------------------------------------------
f="$repo/runtimes/python/tested-versions"
bash "$bot" tested python 3.16 3.16.0
bash "$bot" tested python 3.13 3.13.9
bash "$bot" tested python 3.13 3.13.10
[ "$(grep -v '^#' "$f" | tr '\n' '|')" = '3.13 3.13.10|3.16 3.16.0|' ] || fail "tested-versions: $(cat "$f")"
[ "$(grep -c '^#' "$f")" = "$(grep -c '^#' "$here/runtimes/python/tested-versions")" ] || fail "the header changed"
bash "$bot" tested python 3.13 3.14.1 2>/dev/null && fail "a release of another version"
bash "$bot" tested pytorch 2.15 2.15.0 2>/dev/null && fail "tested-versions of an ML runtime"
bash "$bot" tested java 25.0 25.0.6 || fail "tested-versions of java"
grep -qxF '25.0 25.0.6' "$repo/runtimes/java/tested-versions" && grep -qxF '21.0 21.0.13' "$repo/runtimes/java/tested-versions" \
  || fail "java's tested-versions: $(cat "$repo/runtimes/java/tested-versions")"
echo "ok - tested-versions: one line per version, in order, the header kept"

# --- lifecycle: Bun supports only its newest release --------------------------------------------------
y="$repo/runtimes/bun/runtime.yaml"
out="$(LANG_TODAY=2026-11-07 bash "$bot" lifecycle bun 1.4)" || fail "lifecycle: ${out}"
[ "$out" = "1.4: deprecated 2026-11-07, sunset 2027-02-06" ] || fail "lifecycle: ${out}"
LANG_TODAY=2026-12-01 bash "$bot" lifecycle bun 1.5 >/dev/null || fail "lifecycle of a second version"
rc=0; LANG_TODAY=2027-01-01 bash "$bot" lifecycle bun 1.4 >/dev/null || rc=$?
[ "$rc" = 3 ] || fail "a version with its lifecycle already: exit ${rc}"
[ "$(sed -n '/^versionDiscovery:/,/^[^ ]/p' "$y" | sed '$d')" = 'versionDiscovery:
  repository: ghcr.io/brf-tech/runr/exec-bun
  image: "ghcr.io/brf-tech/runr/exec-bun:{version}"
  eol: bun
  lifecycle:
    "1.4": {deprecated: "2026-11-07", sunset: "2027-02-06"}
    "1.5": {deprecated: "2026-12-01", sunset: "2027-03-02"}' ] || fail "the lifecycle: $(cat "$y")"
[ "$(sed '/^versionDiscovery:/,/^[^ ]/d' "$y")" = "$(sed '/^versionDiscovery:/,/^[^ ]/d' "$here/runtimes/bun/runtime.yaml")" ] || fail "the rest of the manifest changed"
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["versionDiscovery"]["lifecycle"] == {"1.4": {"deprecated": "2026-11-07", "sunset": "2027-02-06"}, "1.5": {"deprecated": "2026-12-01", "sunset": "2027-03-02"}}, d' "$y" \
    || fail "the lifecycle does not read as RunR reads it"
fi
bash "$bot" lifecycle wasm-rust 4.1 >/dev/null 2>&1 && fail "a lifecycle entry without versionDiscovery"
bash "$bot" lifecycle bun 1 >/dev/null 2>&1 && fail "a lifecycle entry of a version that is no X.Y"
echo "ok - lifecycle: deprecated today, the sunset 13 weeks later, once per version, in versionDiscovery.lifecycle"

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
rc=0; bash "$bot" catalog "$runr" ruby 3.4 x 2>/dev/null || rc=$?
[ "$rc" = 3 ] || fail "a runtime the catalog does not have: exit ${rc}"
cat > "$tmp/results.md" <<'EOF'
## Results

| Test | Version | Deploy | Ready | Verify | Time |
|------|---------|--------|-------|--------|------|
| xaas-python-3.16-http | ✓ | ✓ | ✓ | ✓ | 20s |
| xaas-python-3.16-schedule | ✓ | ✓ | ✓ | ✓ | 20s |
| xaas-python-3.16-queue | ✓ | ✓ | ✓ | ✓ | 20s |
| faas-python-3.16-http | ✓ | ✓ | ✓ | ✓ | 60s |
| ml-pytorch-2.15-http | ✓ | ✓ | ✓ | ✓ | 90s |
EOF
bash "$bot" check-e2e "$tmp/results.md" python 3.16 >/dev/null || fail "check-e2e: the candidate's cases passed"
bash "$bot" check-e2e "$tmp/results.md" python 3.15 >/dev/null 2>&1 && fail "check-e2e: another version passed"
bash "$bot" check-e2e "$tmp/results.md" pytorch 2.15 --ml >/dev/null || fail "check-e2e --ml: the ML case passed"
bash "$bot" check-e2e "$tmp/results.md" tensorflow 2.22 --ml >/dev/null 2>&1 && fail "check-e2e --ml: no ML case of tensorflow passed"
cp "$tmp/results.md" "$tmp/results-ok.md"
printf '\n## Failures\n\n- **faas-python-3.16-http** [ready]: timed out\n- **ml-pytorch-2.15-http** [verify]: HTTP 500\n' >> "$tmp/results.md"
bash "$bot" check-e2e "$tmp/results.md" python 3.16 >/dev/null 2>&1 && fail "check-e2e: a failure passed"
bash "$bot" check-e2e "$tmp/results.md" pytorch 2.15 --ml >/dev/null 2>&1 && fail "check-e2e --ml: a failure passed"
[ "$(bash "$bot" runr-pins "$runr" nodejs)" = discovered ] || fail "runr-pins of a discovered runtime"
rc=0; bash "$bot" runr-pins "$runr" wasm-rust >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "runr-pins of a pinned runtime: exit ${rc}"
rc=0; bash "$bot" runr-pins "$runr" ruby >/dev/null || rc=$?
[ "$rc" = 3 ] || fail "runr-pins of a runtime RunR's release does not have: exit ${rc}"
echo "ok - RunR: the catalog offers the candidate alone, the e2e check finds its cases (an ML runtime's ML case) and failures, a discovered runtime has no pins"

# --- landing ----------------------------------------------------------------------------------------
origin="$tmp/origin.git"
git init -q --bare -b main "$origin"
work="$tmp/work"
git init -q -b main "$work"
mkdir -p "$work/runtimes"
for rt in python bun java pytorch wasm-exec wasm-go; do cp -r "$here/runtimes/$rt" "$work/runtimes/"; done
cp -r "$here/ci" "$here/lib" "$work/"
(cd "$work" && git add -A && git commit -q -m base && git remote add origin "$origin" && git push -q origin main)
tested="$(git -C "$work" rev-parse HEAD)"
dir="$tmp/lang"
mkdir -p "$dir/results" "$dir/pins"
cat > "$dir/tests.json" <<'EOF'
[{"issue": 31, "kind": "language", "runtime": "python", "version": "3.16", "full": "3.16.0", "key": "python-3.16", "suites": ["test"]},
 {"issue": 30, "kind": "language", "runtime": "python", "version": "3.13", "full": "3.13.10", "key": "python-3.13", "suites": ["test"]},
 {"issue": 43, "kind": "language", "runtime": "nodejs", "version": "24.23", "full": "24.23.0", "key": "nodejs-24.23", "suites": ["test"]},
 {"issue": 33, "kind": "ml", "runtime": "pytorch", "version": "2.15", "full": "2.15.0", "key": "pytorch", "suites": ["test-ml"]},
 {"issue": 34, "kind": "wasm", "runtime": "tinygo", "version": "0.43.0", "full": "0.43.0", "key": "wasm-tinygo", "suites": ["test-images"]},
 {"issue": 47, "kind": "language", "runtime": "bun", "version": "1.5", "full": "1.5.0", "key": "bun-1.5", "suites": ["test"]},
 {"issue": 45, "kind": "tool", "runtime": "maven", "version": "3.9.17", "full": "3.9.17", "key": "java-maven", "suites": ["test"]}]
EOF
result() { mkdir -p "$dir/results/lang-result-$1"; echo "$2" > "$dir/results/lang-result-$1/status"; echo "$tested" > "$dir/results/lang-result-$1/sha"; echo "the end of the $1 log" > "$dir/results/lang-result-$1/tail.txt"; }
result python-3.16-build success
echo ghcr.io/brf-tech/runr/candidates/exec-python:3.16.0 > "$dir/results/lang-result-python-3.16-build/image"
printf '3.13\n3.15\n' > "$dir/results/lang-result-python-3.16-build/published"
result python-3.16-e2e-test success
result python-3.13-build success
result python-3.13-e2e-test failure
# nodejs: built, but its e2e reported nothing (the job was cancelled)
result nodejs-24.23-build success
result pytorch-build success
(cd "$work" && sed -i 's/^torch==.*/torch==2.15.0/' runtimes/pytorch/requirements-torch.txt && git diff > "$dir/results/lang-result-pytorch-build/pin.patch" && git checkout -q -- .)
echo "torch 2.15.0, torchvision 0.30.0" > "$dir/results/lang-result-pytorch-build/pin"
# RunR's last release before its ML case: the suite is skipped, the build decides
mkdir -p "$dir/results/lang-result-pytorch-e2e-test-ml"
echo skipped > "$dir/results/lang-result-pytorch-e2e-test-ml/status"
echo "RunR v0.6.7 has no ML case yet (test:e2e --ml): it comes with its next release" > "$dir/results/lang-result-pytorch-e2e-test-ml/reason"
# tinygo: the build job's bump, as lang-test.yml runs it
result wasm-tinygo-build success
(cd "$work" && bash ci/lang-bot.sh wasm-bump tinygo 0.43.0 > "$tmp/bump.json" && git diff > "$dir/results/lang-result-wasm-tinygo-build/pin.patch" && git checkout -q -- .)
jq -r .pin "$tmp/bump.json" > "$dir/results/lang-result-wasm-tinygo-build/pin"
jq -r '.images | join(" ")' "$tmp/bump.json" > "$dir/results/lang-result-wasm-tinygo-build/images"
result wasm-tinygo-e2e-test-images success
# bun 1.5: a new minor (1.4 is published) of a release RunR's last release does not offer yet
result bun-1.5-build success
echo ghcr.io/brf-tech/runr/candidates/exec-bun:1.5.0 > "$dir/results/lang-result-bun-1.5-build/image"
printf '1.4\n' > "$dir/results/lang-result-bun-1.5-build/published"
mkdir -p "$dir/results/lang-result-bun-1.5-e2e-test"
echo skipped > "$dir/results/lang-result-bun-1.5-e2e-test/status"
echo "RunR v0.6.7 has no bun runtime yet: it comes with its next release" > "$dir/results/lang-result-bun-1.5-e2e-test/reason"
# maven: the build job's bump, as lang-test.yml runs it
result java-maven-build success
(cd "$work" && bash ci/lang-bot.sh tool-bump maven 3.9.17 > "$tmp/bump.json" && git diff > "$dir/results/lang-result-java-maven-build/pin.patch" && git checkout -q -- .)
jq -r .pin "$tmp/bump.json" > "$dir/results/lang-result-java-maven-build/pin"
jq -r '.images | join(" ")' "$tmp/bump.json" > "$dir/results/lang-result-java-maven-build/images"
result java-maven-e2e-test success
echo "RunR v0.6.7 has no bun runtime yet: its next release brings it and discovers its versions in the registry, nothing to move" > "$dir/pins/bun"
echo "a tool inside the image, which RunR v0.6.7 does not pin: nothing to move" > "$dir/pins/maven"
echo "pins no version of python: it discovers them in the registry, nothing to move" > "$dir/pins/python"
echo "the images keep their version, which RunR v0.6.7 pins (WASM_RUNTIME_VERSION): nothing to move" > "$dir/pins/tinygo"
(cd "$work" && LANG_TODAY=2026-11-07 LANG_BOT_NAME="RunR deps bot" LANG_BOT_EMAIL="deps-bot@runr.sh" bash ci/lang-bot.sh land "$dir" https://example.test/run/9) > "$tmp/out" 2>&1 \
  || fail "land: $(cat "$tmp/out")"
log="$(git --git-dir="$origin" log --format='%an <%ae>|%cn <%ce>|%s' main)"
[ "$(head -n 5 <<<"$log")" = "RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|fix(java): maven 3.9.17 (was 3.9.16)
RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|feat(bun): bun 1.5 (1.5.0)
RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|fix(wasm): tinygo 0.43.0 (was 0.42.0)
RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|fix(pytorch): torch 2.15.0, torchvision 0.30.0
RunR deps bot <deps-bot@runr.sh>|RunR deps bot <deps-bot@runr.sh>|feat(python): python 3.16 (3.16.0)" ] || fail "main: ${log}"
[ "$(git --git-dir="$origin" show main:runtimes/python/tested-versions | grep -v '^#')" = "3.16 3.16.0" ] || fail "main's tested-versions"
git --git-dir="$origin" show main:runtimes/pytorch/requirements-torch.txt | grep -qxF 'torch==2.15.0' || fail "main's torch pin"
git --git-dir="$origin" show main:runtimes/wasm-go/Dockerfile | grep -qxF 'ARG TINYGO_VERSION=0.43.0' && git --git-dir="$origin" show main:lib/mirror.sh | grep -qF '"tinygo:0.43.0|tinygo/tinygo:0.43.0"' \
  || fail "main's tinygo"
git --git-dir="$origin" log -1 --format=%b --grep='^fix(wasm)' main | grep -qF "RunR's e2e (test-images) on the candidate images" \
  || fail "the toolchain commit: $(git --git-dir="$origin" log -1 --format=%b --grep='^fix(wasm)' main)"
# bun 1.5: tested, and 1.4 deprecated with a sunset 13 weeks later
[ "$(git --git-dir="$origin" show main:runtimes/bun/tested-versions | grep -v '^#')" = "1.4 1.4.4
1.5 1.5.0" ] || fail "main's bun tested-versions: $(git --git-dir="$origin" show main:runtimes/bun/tested-versions)"
git --git-dir="$origin" show main:runtimes/bun/runtime.yaml | grep -qxF '    "1.4": {deprecated: "2026-11-07", sunset: "2027-02-06"}' \
  || fail "main's bun lifecycle: $(git --git-dir="$origin" show main:runtimes/bun/runtime.yaml)"
git --git-dir="$origin" log -1 --format=%b --grep='^feat(bun)' main | tr '\n' ' ' | grep -qF 'versionDiscovery.lifecycle deprecates 1.4: deprecated 2026-11-07, sunset 2027-02-06' \
  || fail "the bun commit: $(git --git-dir="$origin" log -1 --format=%b --grep='^feat(bun)' main)"
# maven: the pin and its checksum
git --git-dir="$origin" show main:runtimes/java/Dockerfile | grep -qxF 'ARG MAVEN_VERSION=3.9.17' \
  && git --git-dir="$origin" show main:runtimes/java/Dockerfile | grep -qxF "ARG MAVEN_SHA512=$(sha512 'maven 3.9.17')" || fail "main's maven"
[ "$(git --git-dir="$origin" for-each-ref --format='%(refname)')" = refs/heads/main ] || fail "other refs pushed"
actions="$(cat "$dir/actions")"
grep -qF "$(printf 'label\t31\tlang: passed')" <<<"$actions" && grep -qF "$(printf 'publish\tpython')" <<<"$actions" || fail "green: ${actions}"
grep -qF "$(printf 'label\t30\tneeds attention')" <<<"$actions" || fail "red: ${actions}"
grep -qF 'the end of the python-3.13-e2e-test log' "$dir/comments/30.md" || fail "red: the log: $(cat "$dir/comments/30.md")"
grep -qF 'nothing to move' "$dir/comments/31.md" || fail "green: RunR's pins: $(cat "$dir/comments/31.md")"
grep -qF "$(printf 'label\t43\tneeds attention')" <<<"$actions" && grep -qF 'test` on the candidate: no result' "$dir/comments/43.md" || fail "no e2e result: ${actions} $(cat "$dir/comments/43.md" 2>/dev/null)"
grep -qF "$(printf 'publish\tpytorch')" <<<"$actions" || fail "ml: no publish"
grep -qF 'test-ml` on the candidate: skipped (RunR v0.6.7 has no ML case yet' "$dir/comments/33.md" || fail "ml: the skipped suite: $(cat "$dir/comments/33.md")"
grep -qF "$(printf 'label\t34\tlang: passed')" <<<"$actions" && grep -qF "$(printf 'publish\twasm-exec,wasm-go')" <<<"$actions" || fail "wasm: ${actions}"
grep -qF 'test-images` on the candidate: success' "$dir/comments/34.md" && grep -qF 'WASM_RUNTIME_VERSION' "$dir/comments/34.md" || fail "wasm: the comment: $(cat "$dir/comments/34.md")"
grep -qF "$(printf 'label\t47\tlang: passed')" <<<"$actions" && grep -qF "$(printf 'publish\tbun')" <<<"$actions" || fail "bun: ${actions}"
grep -qF 'test` on the candidate: skipped (RunR v0.6.7 has no bun runtime yet' "$dir/comments/47.md" && grep -qF 'deprecates 1.4: deprecated 2026-11-07, sunset 2027-02-06' "$dir/comments/47.md" \
  || fail "bun: the comment: $(cat "$dir/comments/47.md")"
grep -qF "$(printf 'label\t45\tlang: passed')" <<<"$actions" && grep -qF "$(printf 'publish\tjava')" <<<"$actions" || fail "maven: ${actions}"
echo "ok - landing: green versions, tool and ML pins and toolchains on main as fast-forwards with the bot's identity and their publish, a new Bun minor deprecating the one before, a suite or runtime RunR has not yet skipped, a red one or one without a result labelled with its log"

# main changed the runtime since the tested commit: left for the next run
(cd "$work" && git fetch -q origin && git checkout -q --detach origin/main && echo "# changed" >> runtimes/python/Dockerfile && git commit -q -am "python: a change" && git push -q origin HEAD:refs/heads/main)
cat > "$dir/tests.json" <<'EOF'
[{"issue": 40, "kind": "language", "runtime": "python", "version": "3.17", "full": "3.17.0", "key": "python-3.17", "suites": ["test"]}]
EOF
result python-3.17-build success
result python-3.17-e2e-test success
before="$(git --git-dir="$origin" rev-parse main)"
(cd "$work" && LANG_BOT_NAME=b LANG_BOT_EMAIL=b@example.test bash ci/lang-bot.sh land "$dir" https://example.test/run/10) > "$tmp/out" 2>&1 || fail "land: $(cat "$tmp/out")"
[ "$(git --git-dir="$origin" rev-parse main)" = "$before" ] || fail "committed on a main whose runtime changed"
grep -qF 'main changed `runtimes/python/`' "$dir/comments/40.md" || fail "the comment: $(cat "$dir/comments/40.md")"
echo "ok - a version whose runtime changed on main since the tested commit is left for the next run"
