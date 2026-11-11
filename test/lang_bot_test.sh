#!/usr/bin/env bash
# Tests ci/lang-bot.sh, the language bot's steps, without GitHub, PyPI or RunR: issues are a JSON
# file as `gh issue list` writes it, PyPI, GitHub's release assets and ziglang.org answer from
# fixtures (WATCH_FIXTURES), RunR is a throwaway checkout with its catalog, main a bare git
# repository. Whatever this checkout pins (the bot moves the pins, its tests run on the moved
# ones), every bump goes from the pin it finds to the next release, and tested-versions and the
# lifecycle start from fixtures. Checks that:
#   - the plan tests the newest release of each language version (every runtime of RUNTIME_DEFS),
#     tool of a language image, ML runtime and WebAssembly toolchain with the RunR suites that
#     deploy its images, supersedes the older ones, skips an end-of-life notice, a passed issue, one
#     of a runtime it does not know and one that waits for a person unless the run names it, and
#     marks the second chance of one an upstream outage stopped;
#   - an ML bump moves torch with the torchvision pip installs next to it (the newest whose torch
#     requirement admits it: an exact pin or a range), both built on the -gpu image's CUDA wheel
#     index (none: nothing moves), and tensorflow's CPU and CUDA pins together;
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
#   - an outage is an upstream server's 5xx on a line that failed (helm's chart, a download, a RUN
#     step's curl) or the e2e cluster's registry for every failed case of RunR's summary, never the
#     candidate's own answer, another local address or a case that failed on its own;
#   - landing: a green version, ML pin or toolchain is committed on top of main and pushed as a
#     fast-forward with the bot's identity and trailer, and one publish after the last landing
#     takes every image the landed tests touched (a tool's pin too, a new Bun minor with the
#     lifecycle of the one before), a suite RunR's release does not have yet counts as skipped, a
#     red one or one without a result is labelled with what failed (never an empty log), one an
#     outage stopped is labelled for the next run (a second outage in a row asks a person), a
#     version whose runtime changed on main since the tested commit is left for the next run;
#   - the five green toolchains of run 43020609005 (rust, spin, tinygo, wasm-tools, zig) on one
#     base all land, a patch whose lines moved made again on the new main; one made again with
#     other lines waits for the next run, and one the bot cannot land is reported while the others
#     land.
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

# the pins of this checkout, whatever they are, and the next release of each, which the bumps move to
arg_in() { sed -n "s/^ARG $2=//p" "$here/runtimes/$1/Dockerfile" | head -n 1; }
next() { case "$1" in *.*) echo "${1%.*}.$((10#${1##*.} + 1))" ;; *) echo "$((10#$1 + 1))" ;; esac; }
spin_old="$(arg_in wasm-exec SPIN_VERSION)" tinygo_old="$(arg_in wasm-go TINYGO_VERSION)" zig_old="$(arg_in wasm-exec ZIG_VERSION)"
maven_old="$(arg_in java MAVEN_VERSION)" plugin_old="$(arg_in java MAVEN_DEPENDENCY_PLUGIN)"
torch_old="$(sed -n 's/^torch==//p' "$here/runtimes/pytorch/requirements-torch.txt")"
for v in "$spin_old" "$tinygo_old" "$zig_old" "$maven_old" "$plugin_old" "$torch_old"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "a pin of this checkout is no release X.Y.Z: '${v}'"
done
spin_new="$(next "$spin_old")" tinygo_new="$(next "$tinygo_old")" zig_new="$(next "$zig_old")"
maven_new="$(next "$maven_old")" plugin_new="$(next "$plugin_old")" torch_new="$(next "$torch_old")"
# tested-versions and Bun's manifest as the bot may find them: the header alone (Java: one version
# the test keeps), no lifecycle
tested_fixture() { grep '^#' "$here/runtimes/$1/tested-versions"; shift; [ "$#" = 0 ] || printf '%s\n' "$@"; }
no_lifecycle() { awk '/^versionDiscovery:/ { vd = 1 } vd && /^[^ #]/ && !/^versionDiscovery:/ { vd = 0 } vd && /^  lifecycle:/ { lc = 1; next } lc && /^    / { next } { lc = 0; print }' "$1"; }
tested_fixture python > "$repo/runtimes/python/tested-versions"
tested_fixture java "21.0 21.0.13" > "$repo/runtimes/java/tested-versions"
no_lifecycle "$here/runtimes/bun/runtime.yaml" > "$repo/runtimes/bun/runtime.yaml"

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
  {"number": 49, "title": "lang: maven 3.9 released", "labels": []},
  {"number": 50, "title": "lang: zig 0.17.1 released", "labels": [{"name": "lang: upstream outage"}]}
]
EOF
plan="$(bash "$bot" plan "$tmp/issues.json")"
[ "$(jq -c '[.tests[] | [.issue, .kind, .runtime, .version, .full, .key]] | sort' <<<"$plan")" = '[[30,"language","python","3.13","3.13.10","python-3.13"],[31,"language","python","3.16","3.16.0","python-3.16"],[33,"ml","pytorch","2.15","2.15.0","pytorch"],[34,"wasm","tinygo","0.43.0","0.43.0","wasm-tinygo"],[39,"wasm","spin","4.2.0","4.2.0","wasm-spin"],[41,"wasm","componentize-py","0.26.0","0.26.0","wasm-componentize-py"],[44,"language","java","25.0","25.0.6","java-25.0"],[46,"tool","maven","3.9.18","3.9.18","java-maven"],[47,"language","bun","1.5","1.5.0","bun-1.5"],[48,"tool","maven-dependency-plugin","3.12.0","3.12.0","java-maven-dependency-plugin"],[50,"wasm","zig","0.17.1","0.17.1","wasm-zig"]]' ] \
  || fail "tests: $(jq -c .tests <<<"$plan")"
# the suites: the main e2e of a language and of a tool's image, its ML case, the WebAssembly suites
# that deploy the images of a toolchain (none for wasm-python's, which only the smoke test checks)
[ "$(jq -c '[.tests[] | [.key, .suites]]' <<<"$plan")" = '[["bun-1.5",["test"]],["java-25.0",["test"]],["java-maven",["test"]],["java-maven-dependency-plugin",["test"]],["python-3.13",["test"]],["python-3.16",["test"]],["pytorch",["test-ml"]],["wasm-componentize-py",[]],["wasm-spin",["test-wasm","test-images"]],["wasm-tinygo",["test-images"]],["wasm-zig",["test-images"]]]' ] \
  || fail "suites: $(jq -c '[.tests[] | [.key, .suites]]' <<<"$plan")"
# an upstream outage stopped #50 the run before: it is tested again, as its second chance
[ "$(jq -c '[.tests[] | select(.outage) | .issue]' <<<"$plan")" = '[50]' ] || fail "the outage's second chance: $(jq -c .tests <<<"$plan")"
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
# torchvision pinned torch exactly up to 0.29.0 (torch==2.14.0), and names a range since 0.29.1
# (torch>=2.14.0: torch's stable ABI); a pre-release and torchaudio's requirement do not count
fx https://pypi.org/pypi/torchvision/json '{"releases": {"0.29.1": [], "0.30.0": [], "0.30.1": [], "0.31.0": [], "0.31.1": [], "0.31.2rc1": []}}'
fx https://pypi.org/pypi/torchvision/0.31.2rc1/json '{"info": {"requires_dist": ["torch>=2.16.0"]}}'
fx https://pypi.org/pypi/torchvision/0.31.1/json '{"info": {"requires_dist": ["numpy", "torch>=2.16.0,<3"]}}'
fx https://pypi.org/pypi/torchvision/0.31.0/json '{"info": {"requires_dist": ["numpy", "torchaudio==2.18.0", "torch>=2.16.0,<2.18", "scipy; extra == \"scipy\""]}}'
fx https://pypi.org/pypi/torchvision/0.30.1/json '{"info": {"requires_dist": ["numpy", "torch (==2.15.1)"]}}'
fx https://pypi.org/pypi/torchvision/0.30.0/json '{"info": {"requires_dist": ["numpy", "torch==2.15.0"]}}'
fx https://pypi.org/pypi/torchvision/0.29.1/json '{"info": {"requires_dist": ["torch==2.14.1"]}}'
# the -gpu image's CUDA wheel index (Dockerfile.gpu) has these builds, as PyTorch's simple index
# lists them: no torch 2.16.0, no torchvision 0.31.1 (as torchvision 0.29.2 has no cu126 build)
cuda_index="$(grep -oE 'https://download\.pytorch\.org/whl/cu[0-9]+' "$here/runtimes/pytorch/Dockerfile.gpu" | head -n 1)"
cu="${cuda_index##*/}"
[ -n "$cu" ] || fail "no CUDA wheel index in runtimes/pytorch/Dockerfile.gpu"
wheel_links() { local w; for w in "$@"; do printf '<a href="/whl/%s/%s-cp312-cp312-manylinux_2_28_x86_64.whl">%s</a><br/>\n' "$cu" "${w/+/%2B}" "$w"; done; }
fx "${cuda_index}/torch/" "$(wheel_links "torch-2.15.0+${cu}" "torch-2.15.1+${cu}" "torch-2.17.2+${cu}" "torch-2.18.0+${cu}" "torch-3.0.0+${cu}")"
fx "${cuda_index}/torchvision/" "$(wheel_links "torchvision-0.30.0+${cu}" "torchvision-0.30.1+${cu}" "torchvision-0.31.0+${cu}")"
torch_pins() { grep -E '^torch(vision)?==' "$repo/runtimes/pytorch/requirements-torch.txt" | tr '\n' ' '; }
out="$(bash "$bot" ml-bump pytorch 2.15.0)" || fail "ml-bump pytorch: ${out}"
[ "$out|$(torch_pins)" = "torch 2.15.0, torchvision 0.30.0|torch==2.15.0 torchvision==0.30.0 " ] || fail "the torch pins (an exact pin): ${out} $(torch_pins)"
out="$(bash "$bot" ml-bump pytorch 2.15.1)" || fail "ml-bump pytorch 2.15.1: ${out}"
[ "$(torch_pins)" = "torch==2.15.1 torchvision==0.30.1 " ] || fail "the torch pins (torch (==X)): $(torch_pins)"
# 0.31.1 admits 2.17.2 too, but has no build for the -gpu image: 0.31.0
out="$(bash "$bot" ml-bump pytorch 2.17.2)" || fail "ml-bump pytorch 2.17.2: ${out}"
[ "$(torch_pins)" = "torch==2.17.2 torchvision==0.31.0 " ] || fail "the torch pins (a range): $(torch_pins)"
# nothing moves: no torchvision admits torch 3.0.0; the one that admits 2.18.0 has no build for the
# -gpu image; torch 2.16.0 has none itself (another CUDA is a person's decision)
for v in 3.0.0 2.18.0 2.16.0; do
  rc=0; out="$(bash "$bot" ml-bump pytorch "$v" 2>&1)" || rc=$?
  [ "$rc" = 2 ] && [ "$(torch_pins)" = "torch==2.17.2 torchvision==0.31.0 " ] || fail "torch ${v}: exit ${rc}, $(torch_pins), ${out}"
  case "$v" in
    3.0.0) grep -qF 'no torchvision release on PyPI admits torch 3.0.0' <<<"$out" ;;
    2.18.0) grep -qF "has none of the torchvision releases that admit torch 2.18.0 (0.31.1) built for ${cu}" <<<"$out" ;;
    2.16.0) grep -qF "has no torch 2.16.0 built for ${cu}" <<<"$out" ;;
  esac || fail "torch ${v}: ${out}"
done
bash "$bot" ml-bump tensorflow 2.22.0 >/dev/null || fail "ml-bump tensorflow"
grep -qxF 'tensorflow-cpu==2.22.0' "$repo/runtimes/tensorflow/requirements-cpu.txt" && grep -qxF 'tensorflow[and-cuda]==2.22.0' "$repo/runtimes/tensorflow/requirements-cuda.txt" \
  || fail "the tensorflow pins"
bash "$bot" ml-bump python 3.16.0 >/dev/null 2>&1 && fail "ml-bump of a language"
echo "ok - an ML bump: torch with the newest torchvision whose torch requirement admits it (an exact pin or a range), both built for the -gpu image's CUDA, tensorflow's CPU and CUDA pins together"

# --- WebAssembly toolchain bump ---------------------------------------------------------------------
sum() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }
arg_of() { sed -n "s/^ARG $2=//p" "$repo/runtimes/$1/Dockerfile"; }
# spin: every image has it; the checksums of its release assets
spin_asset() { echo "https://github.com/spinframework/spin/releases/download/v$1/spin-v$1-static-linux-$2.tar.gz"; }
fx "$(spin_asset "$spin_new" amd64)" 'spin amd64'
fx "$(spin_asset "$spin_new" aarch64)" 'spin arm64'
out="$(bash "$bot" wasm-bump spin "$spin_new")" || fail "wasm-bump spin: ${out}"
[ "$out" = "{\"pin\":\"spin ${spin_new} (was ${spin_old})\",\"images\":[\"wasm-exec\",\"wasm-go\",\"wasm-js\",\"wasm-python\",\"wasm-rust\"],\"mirror\":[]}" ] || fail "wasm-bump spin: ${out}"
for img in wasm-exec wasm-go wasm-js wasm-python wasm-rust; do
  [ "$(arg_of "$img" SPIN_VERSION)|$(arg_of "$img" SPIN_SHA256_AMD64)|$(arg_of "$img" SPIN_SHA256_ARM64)" = "${spin_new}|$(sum 'spin amd64')|$(sum 'spin arm64')" ] \
    || fail "spin in ${img}: $(grep '^ARG SPIN' "$repo/runtimes/$img/Dockerfile")"
done
# zig: wasm-exec alone; the checksums of ziglang.org's index
fx https://ziglang.org/download/index.json "{\"${zig_new}\": {\"x86_64-linux\": {\"shasum\": \"$(printf 'a%.0s' {1..64})\"}, \"aarch64-linux\": {\"shasum\": \"$(printf 'b%.0s' {1..64})\"}}}"
out="$(bash "$bot" wasm-bump zig "$zig_new")" || fail "wasm-bump zig: ${out}"
[ "$(jq -c '[.pin, .images]' <<<"$out")" = "[\"zig ${zig_new} (was ${zig_old})\",[\"wasm-exec\"]]" ] && [ "$(arg_of wasm-exec ZIG_VERSION)|$(arg_of wasm-exec ZIG_SHA256_AMD64)" = "${zig_new}|$(printf 'a%.0s' {1..64})" ] \
  || fail "zig: ${out} $(grep '^ARG ZIG' "$repo/runtimes/wasm-exec/Dockerfile")"
# tinygo and rust: their base image follows in the reqs mirror, the old line goes, others stay
out="$(bash "$bot" wasm-bump tinygo "$tinygo_new")" || fail "wasm-bump tinygo: ${out}"
[ "$out" = "{\"pin\":\"tinygo ${tinygo_new} (was ${tinygo_old})\",\"images\":[\"wasm-exec\",\"wasm-go\"],\"mirror\":[\"tinygo:${tinygo_new}\"]}" ] || fail "wasm-bump tinygo: ${out}"
grep -qxF "  \"tinygo:${tinygo_new}|tinygo/tinygo:${tinygo_new}\"" "$repo/lib/mirror.sh" && ! grep -qF "\"tinygo:${tinygo_old}|" "$repo/lib/mirror.sh" \
  || fail "tinygo's mirror line: $(grep tinygo "$repo/lib/mirror.sh")"
old_rust="$(arg_of wasm-rust RUST_VERSION)"
new_rust="$(next "$old_rust")"
out="$(bash "$bot" wasm-bump rust "$new_rust")" || fail "wasm-bump rust: ${out}"
[ "$(jq -c '[.images, .mirror]' <<<"$out")" = "[[\"wasm-rust\"],[\"rust:${new_rust}-slim-bookworm\"]]" ] || fail "wasm-bump rust: ${out}"
grep -qxF "  \"rust:${new_rust}-slim-bookworm|rust:${new_rust}-slim-bookworm\"" "$repo/lib/mirror.sh" && ! grep -qF "\"rust:${old_rust}-slim-bookworm|" "$repo/lib/mirror.sh" \
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
fx "$(maven "$maven_new")" "maven ${maven_new}"
fx "$(maven "$maven_new").sha512" "$(sha512 "maven ${maven_new}")"
out="$(bash "$bot" tool-bump maven "$maven_new")" || fail "tool-bump maven: ${out}"
[ "$out" = "{\"pin\":\"maven ${maven_new} (was ${maven_old})\",\"image\":\"java\",\"images\":[\"java\"]}" ] || fail "tool-bump maven: ${out}"
[ "$(arg_of java MAVEN_VERSION)|$(arg_of java MAVEN_SHA512)" = "${maven_new}|$(sha512 "maven ${maven_new}")" ] \
  || fail "maven in exec-java: $(grep '^ARG MAVEN' "$repo/runtimes/java/Dockerfile")"
# the dependency plugin: no download of its own (Maven checks what it fetches)
out="$(bash "$bot" tool-bump maven-dependency-plugin "$plugin_new")" || fail "tool-bump maven-dependency-plugin: ${out}"
[ "$(jq -r .pin <<<"$out")|$(arg_of java MAVEN_DEPENDENCY_PLUGIN)" = "maven-dependency-plugin ${plugin_new} (was ${plugin_old})|${plugin_new}" ] \
  || fail "the dependency plugin: ${out} $(grep '^ARG MAVEN_DEPENDENCY' "$repo/runtimes/java/Dockerfile")"
# a download whose SHA-512 is not the published one, or without one, changes nothing
bad1="$(next "$maven_new")" bad2="$(next "$(next "$maven_new")")" bad3="$(next "$(next "$(next "$maven_new")")")"
fx "$(maven "$bad1")" "maven ${bad1}"
fx "$(maven "$bad1").sha512" "$(sha512 'something else')"
fx "$(maven "$bad2")" "maven ${bad2}"
before="$(sha256sum < "$repo/runtimes/java/Dockerfile")"
for v in "$bad1" "$bad2" "$bad3"; do
  rc=0; bash "$bot" tool-bump maven "$v" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ "$(sha256sum < "$repo/runtimes/java/Dockerfile")" = "$before" ] || fail "maven ${v} without its published checksum: exit ${rc}"
done
bash "$bot" tool-bump spin "$spin_new" >/dev/null 2>&1 && fail "tool-bump of a WebAssembly toolchain"
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

# --- an upstream outage -------------------------------------------------------------------------------
# what the run of 2026-11-09 showed: helm's chart from GitHub in RunR's e2e, wasi-sdk in a RUN step
cat > "$tmp/outage.log" <<'EOF'
  [installing] zot_install...
  Registry setup error: Zot Helm install failed: Error: failed to fetch https://github.com/project-zot/helm-charts/releases/download/zot-0.1.130/zot-0.1.130.tgz : 504 Gateway Timeout
EOF
[ "$(bash "$bot" upstream "$tmp/outage.log")" = "$(sed -n 2p "$tmp/outage.log")" ] || fail "helm's 504 is no outage"
printf '#10 16.33 /tmp/spin.tar.gz: OK\n#10 28.19 curl: (22) The requested URL returned error: 504\n' > "$tmp/outage.log"
bash "$bot" upstream "$tmp/outage.log" >/dev/null || fail "a RUN step's curl 504 is no outage"
printf 'ERROR: failed to solve: unexpected status from HEAD request to https://ghcr.io/v2/brf-tech/runr/reqs/rust/manifests/1.99.1: 503 Service Unavailable\n' > "$tmp/outage.log"
bash "$bot" upstream "$tmp/outage.log" >/dev/null || fail "a registry's 503 is no outage"
# the candidate's own answers, local addresses, digests and curl outside a RUN step are none
cat > "$tmp/outage.log" <<'EOF'
- **ml-pytorch-2.15-http** [verify]: HTTP 500
- **xaas-python-3.16-http** [ready]: error: 503 Service Unavailable
Error: failed to call http://172.18.0.5/fn: 502 Bad Gateway
Error: failed to call https://127.0.0.1:8443/fn: 502 Bad Gateway
Error: failed to call https://10.96.0.1/api: 503
Error: failed to push https://zot.runr-e2e.svc/v2/x: 503
Error: failed to call https://fn.127.0.0.1.nip.io/: 504
ERROR: failed to push ghcr.io/x@sha256:ee7421c3504dfc5d009f71 https://ghcr.io/v2/x: unauthorized
  | curl: (22) The requested URL returned error: 503
https://github.com/x/y/releases/download/v1/z.tar.gz: no answer after its retries, the release asset through the GitHub API instead
EOF
out="$(bash "$bot" upstream "$tmp/outage.log")" && fail "not an outage: ${out}"
bash "$bot" upstream "$tmp/no-such.log" >/dev/null && fail "a log that is not there"
# the registry inside RunR's Kind cluster (run 43020609005, maven 3.10.0): every failed case of the
# e2e's summary failed on it, so the suite is an outage; one case that failed on its own is none
flake='  ✗ xaas-java-25.0-http [version]: Build failed: error building image: unable to complete operation after 0 attempts, last error: GET http://10.96.189.218:5000/v2/ghcr.io/brf-tech/runr/candidates/exec-java/manifests/sha256:c50468b110658e86979291c0595d1f11aecab266c833bac54abf120115b96754: MANIFEST_UNKNOWN: synchronization failed'
summary() { printf '  ✗ [1/9] xaas-java-25.0-http — build: Build failed\n  ✓ [2/9] xaas-java-25.0-schedule (29.3s)\n\n  Passed: 20/21  Failed: 1\n\n── Failures ──\n'; printf '%s\n' "$@"; printf '\n── Slowest ──\n  1. rt-c-http  44.1s\n'; }
summary "$flake" > "$tmp/outage.log"
[ "$(bash "$bot" upstream "$tmp/outage.log")" = "$flake" ] || fail "the e2e cluster's registry is no outage: $(bash "$bot" upstream "$tmp/outage.log")"
summary "$flake" '  ✗ xaas-java-25.0-schedule [build]: Build failed: Main.java:3: error: cannot find symbol' > "$tmp/outage.log"
out="$(bash "$bot" upstream "$tmp/outage.log")" && fail "a compile error next to the registry's flake: ${out}"
summary '  ✗ xaas-java-25.0-http [verify]: HTTP 500 from http://10.96.2.210/fn' > "$tmp/outage.log"
out="$(bash "$bot" upstream "$tmp/outage.log")" && fail "the candidate's own answer: ${out}"
summary '  ✗ xaas-java-25.0-http [version]: Build failed: GET http://10.96.189.218:5000/v2/x/manifests/y: UNAUTHORIZED: authentication required' > "$tmp/outage.log"
out="$(bash "$bot" upstream "$tmp/outage.log")" && fail "a registry that refuses: ${out}"
# the summary decides: an upstream 5xx earlier in the log does not make a failed case an outage
{ echo 'Error: failed to fetch https://github.com/x/y.tgz : 504 Gateway Timeout'; summary '  ✗ faas-java-25.0-http [ready]: timed out'; } > "$tmp/outage.log"
out="$(bash "$bot" upstream "$tmp/outage.log")" && fail "a failed case next to an earlier 504: ${out}"
echo "ok - an outage: an upstream server's 5xx on a line that failed, the e2e cluster's registry for every failed case; never the candidate's answer, a local address or a case that failed on its own"

# --- landing ----------------------------------------------------------------------------------------
# the bot's identity on main (lang-test.yml): Burak's, its commits marked by their trailer
bot_name="Burak Faruk ŞAHİN" bot_email="19393636+brkfun@users.noreply.github.com"
bot_id="${bot_name} <${bot_email}>"
origin="$tmp/origin.git"
git init -q --bare -b main "$origin"
work="$tmp/work"
git init -q -b main "$work"
mkdir -p "$work/runtimes"
for rt in python bun java pytorch wasm-exec wasm-go wasm-rust; do cp -r "$here/runtimes/$rt" "$work/runtimes/"; done
cp -r "$here/ci" "$here/lib" "$work/"
tested_fixture python > "$work/runtimes/python/tested-versions"
tested_fixture bun "1.4 1.4.4" > "$work/runtimes/bun/tested-versions"
no_lifecycle "$here/runtimes/bun/runtime.yaml" > "$work/runtimes/bun/runtime.yaml"
(cd "$work" && git add -A && git commit -q -m base && git remote add origin "$origin" && git push -q origin main)
tested="$(git -C "$work" rev-parse HEAD)"
dir="$tmp/lang"
mkdir -p "$dir/results" "$dir/pins"
# 45: the second chance after an upstream outage, green; 51: an upstream outage in the build; 52:
# its second one in a row, in RunR's suite; 53: a red build whose step printed nothing
cat > "$dir/tests.json" <<EOF
[{"issue": 31, "kind": "language", "runtime": "python", "version": "3.16", "full": "3.16.0", "key": "python-3.16", "suites": ["test"]},
 {"issue": 30, "kind": "language", "runtime": "python", "version": "3.13", "full": "3.13.10", "key": "python-3.13", "suites": ["test"]},
 {"issue": 43, "kind": "language", "runtime": "nodejs", "version": "24.23", "full": "24.23.0", "key": "nodejs-24.23", "suites": ["test"]},
 {"issue": 33, "kind": "ml", "runtime": "pytorch", "version": "${torch_new%.*}", "full": "${torch_new}", "key": "pytorch", "suites": ["test-ml"]},
 {"issue": 34, "kind": "wasm", "runtime": "tinygo", "version": "${tinygo_new}", "full": "${tinygo_new}", "key": "wasm-tinygo", "suites": ["test-images"]},
 {"issue": 47, "kind": "language", "runtime": "bun", "version": "1.5", "full": "1.5.0", "key": "bun-1.5", "suites": ["test"]},
 {"issue": 45, "kind": "tool", "runtime": "maven", "version": "${maven_new}", "full": "${maven_new}", "key": "java-maven", "suites": ["test"], "outage": true},
 {"issue": 51, "kind": "wasm", "runtime": "zig", "version": "${zig_new}", "full": "${zig_new}", "key": "wasm-zig", "suites": ["test-images"], "outage": false},
 {"issue": 52, "kind": "wasm", "runtime": "rust", "version": "1.99.1", "full": "1.99.1", "key": "wasm-rust", "suites": ["test-wasm"], "outage": true},
 {"issue": 53, "kind": "wasm", "runtime": "wasm-tools", "version": "1.263.0", "full": "1.263.0", "key": "wasm-wasm-tools", "suites": ["test-images"]}]
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
(cd "$work" && sed -i "s/^torch==.*/torch==${torch_new}/" runtimes/pytorch/requirements-torch.txt && git diff > "$dir/results/lang-result-pytorch-build/pin.patch" && git checkout -q -- .)
echo "torch ${torch_new}, torchvision 0.30.0" > "$dir/results/lang-result-pytorch-build/pin"
# RunR's last release before its ML case: the suite is skipped, the build decides
mkdir -p "$dir/results/lang-result-pytorch-e2e-test-ml"
echo skipped > "$dir/results/lang-result-pytorch-e2e-test-ml/status"
echo "RunR v0.6.7 has no ML case yet (test:e2e --ml): it comes with its next release" > "$dir/results/lang-result-pytorch-e2e-test-ml/reason"
# tinygo: the build job's bump, as lang-test.yml runs it
result wasm-tinygo-build success
(cd "$work" && bash ci/lang-bot.sh wasm-bump tinygo "$tinygo_new" > "$tmp/bump.json" && git diff > "$dir/results/lang-result-wasm-tinygo-build/pin.patch" && git checkout -q -- .)
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
(cd "$work" && bash ci/lang-bot.sh tool-bump maven "$maven_new" > "$tmp/bump.json" && git diff > "$dir/results/lang-result-java-maven-build/pin.patch" && git checkout -q -- .)
jq -r .pin "$tmp/bump.json" > "$dir/results/lang-result-java-maven-build/pin"
jq -r '.images | join(" ")' "$tmp/bump.json" > "$dir/results/lang-result-java-maven-build/images"
result java-maven-e2e-test success
# zig: wasi-sdk's download gave 504 in the build (lang-bot.sh upstream found it); no e2e ran
result wasm-zig-build failure
echo "#10 28.19 download failed: https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz (HTTP 504)" > "$dir/results/lang-result-wasm-zig-build/upstream"
result wasm-zig-e2e-test-images failure
# rust: helm's chart gave 504 in RunR's e2e, which ran once more and hit it again; the run before
# was an outage too
result wasm-rust-build success
echo wasm-rust > "$dir/results/lang-result-wasm-rust-build/images"
result wasm-rust-e2e-test-wasm failure
echo "Error: failed to fetch https://github.com/project-zot/helm-charts/releases/download/zot-0.1.130/zot-0.1.130.tgz : 504 Gateway Timeout" \
  | tee "$dir/results/lang-result-wasm-rust-e2e-test-wasm/upstream" > "$dir/results/lang-result-wasm-rust-e2e-test-wasm/retried"
# wasm-tools: a red build whose failed step printed nothing into the log
result wasm-wasm-tools-build failure
: > "$dir/results/lang-result-wasm-wasm-tools-build/tail.txt"
echo "RunR v0.6.7 has no bun runtime yet: its next release brings it and discovers its versions in the registry, nothing to move" > "$dir/pins/bun"
echo "a tool inside the image, which RunR v0.6.7 does not pin: nothing to move" > "$dir/pins/maven"
echo "pins no version of python: it discovers them in the registry, nothing to move" > "$dir/pins/python"
echo "the images keep their version, which RunR v0.6.7 pins (WASM_RUNTIME_VERSION): nothing to move" > "$dir/pins/tinygo"
(cd "$work" && LANG_TODAY=2026-11-07 LANG_BOT_NAME="$bot_name" LANG_BOT_EMAIL="$bot_email" bash ci/lang-bot.sh land "$dir" https://example.test/run/9) > "$tmp/out" 2>&1 \
  || fail "land: $(cat "$tmp/out")"
log="$(git --git-dir="$origin" log --format='%an <%ae>|%cn <%ce>|%s' main)"
[ "$(head -n 6 <<<"$log")" = "${bot_id}|${bot_id}|fix(java): maven ${maven_new} (was ${maven_old})
${bot_id}|${bot_id}|feat(bun): bun 1.5 (1.5.0)
${bot_id}|${bot_id}|fix(wasm): tinygo ${tinygo_new} (was ${tinygo_old})
${bot_id}|${bot_id}|fix(pytorch): torch ${torch_new}, torchvision 0.30.0
${bot_id}|${bot_id}|feat(python): python 3.16 (3.16.0)
someone <someone@example.test>|someone <someone@example.test>|base" ] || fail "main: ${log}"
# each of the bot's commits says it is the bot's: RunR-Lang-Bot: <name> <version>
[ "$(git --git-dir="$origin" log -5 --format='%(trailers:key=RunR-Lang-Bot,valueonly,separator=%x2C)' main | grep -v '^$')" = "maven ${maven_new}
bun 1.5.0
tinygo ${tinygo_new}
pytorch ${torch_new}
python 3.16.0" ] || fail "the trailers: $(git --git-dir="$origin" log -5 --format=%B main)"
[ "$(git --git-dir="$origin" show main:runtimes/python/tested-versions | grep -v '^#')" = "3.16 3.16.0" ] || fail "main's tested-versions"
git --git-dir="$origin" show main:runtimes/pytorch/requirements-torch.txt | grep -qxF "torch==${torch_new}" || fail "main's torch pin"
git --git-dir="$origin" show main:runtimes/wasm-go/Dockerfile | grep -qxF "ARG TINYGO_VERSION=${tinygo_new}" && git --git-dir="$origin" show main:lib/mirror.sh | grep -qF "\"tinygo:${tinygo_new}|tinygo/tinygo:${tinygo_new}\"" \
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
git --git-dir="$origin" show main:runtimes/java/Dockerfile | grep -qxF "ARG MAVEN_VERSION=${maven_new}" \
  && git --git-dir="$origin" show main:runtimes/java/Dockerfile | grep -qxF "ARG MAVEN_SHA512=$(sha512 "maven ${maven_new}")" || fail "main's maven"
[ "$(git --git-dir="$origin" for-each-ref --format='%(refname)')" = refs/heads/main ] || fail "other refs pushed"
actions="$(cat "$dir/actions")"
grep -qF "$(printf 'label\t31\tlang: passed')" <<<"$actions" || fail "green: ${actions}"
# one publish, the last action, for main as the run left it: every image the landed tests touched,
# once, in the order they landed (python, pytorch, tinygo's wasm-exec and wasm-go, bun, maven's java)
[ "$(grep -c "$(printf '^publish\t')" <<<"$actions")" = 1 ] && [ "$(tail -n 1 <<<"$actions")" = "$(printf 'publish\tpython,pytorch,wasm-exec,wasm-go,bun,java')" ] \
  || fail "one publish of the landed images: ${actions}"
grep -qF "$(printf 'label\t30\tneeds attention')" <<<"$actions" || fail "red: ${actions}"
grep -qF 'the end of the python-3.13-e2e-test log' "$dir/comments/30.md" || fail "red: the log: $(cat "$dir/comments/30.md")"
grep -qF 'nothing to move' "$dir/comments/31.md" || fail "green: RunR's pins: $(cat "$dir/comments/31.md")"
grep -qF "$(printf 'label\t43\tneeds attention')" <<<"$actions" && grep -qF 'test` on the candidate: no result' "$dir/comments/43.md" || fail "no e2e result: ${actions} $(cat "$dir/comments/43.md" 2>/dev/null)"
grep -qF 'test-ml` on the candidate: skipped (RunR v0.6.7 has no ML case yet' "$dir/comments/33.md" || fail "ml: the skipped suite: $(cat "$dir/comments/33.md")"
grep -qF "$(printf 'label\t34\tlang: passed')" <<<"$actions" || fail "wasm: ${actions}"
grep -qF 'test-images` on the candidate: success' "$dir/comments/34.md" && grep -qF 'WASM_RUNTIME_VERSION' "$dir/comments/34.md" || fail "wasm: the comment: $(cat "$dir/comments/34.md")"
grep -qF "$(printf 'label\t47\tlang: passed')" <<<"$actions" || fail "bun: ${actions}"
grep -qF 'test` on the candidate: skipped (RunR v0.6.7 has no bun runtime yet' "$dir/comments/47.md" && grep -qF 'deprecates 1.4: deprecated 2026-11-07, sunset 2027-02-06' "$dir/comments/47.md" \
  || fail "bun: the comment: $(cat "$dir/comments/47.md")"
grep -qF "$(printf 'label\t45\tlang: passed')" <<<"$actions" || fail "maven: ${actions}"
# maven passed on its second chance: the outage label goes
grep -qF "$(printf 'unlabel\t45\tlang: upstream outage')" <<<"$actions" || fail "the outage label stayed on a green one: ${actions}"
# zig: an outage, nobody is asked; the next run tests it again
grep -qF "$(printf 'label\t51\tlang: upstream outage')" <<<"$actions" && ! grep -qF "$(printf 'label\t51\tneeds attention')" <<<"$actions" || fail "the outage: ${actions}"
grep -qF '**Outage: zig' "$dir/comments/51.md" && grep -qF 'wasi-sdk-34.0-x86_64-linux.tar.gz (HTTP 504)' "$dir/comments/51.md" \
  && grep -qF 'test-images` on the candidate: not run (the build failed)' "$dir/comments/51.md" || fail "the outage's comment: $(cat "$dir/comments/51.md")"
# rust: the second outage in a row asks a person, the outage label goes
grep -qF "$(printf 'label\t52\tneeds attention')" <<<"$actions" && grep -qF "$(printf 'unlabel\t52\tlang: upstream outage')" <<<"$actions" || fail "a second outage: ${actions}"
grep -qF 'the second run in a row' "$dir/comments/52.md" && grep -qF 'test-wasm` on the candidate: failure (run once more after an outage) (an outage)' "$dir/comments/52.md" \
  || fail "a second outage's comment: $(cat "$dir/comments/52.md")"
# wasm-tools: red, and its comment says the log is empty instead of an empty block
grep -qF "$(printf 'label\t53\tneeds attention')" <<<"$actions" && grep -qF 'the log is empty' "$dir/comments/53.md" || fail "an empty log: $(cat "$dir/comments/53.md")"
for c in "$dir"/comments/*.md; do
  if awk 'prev == "```" && $0 == "```" { found = 1 } { prev = $0 } END { exit !found }' "$c"; then fail "an empty block in $(basename "$c"): $(cat "$c")"; fi
done
echo "ok - landing: green versions, tool and ML pins and toolchains on main as fast-forwards with the bot's identity and their publish, a new Bun minor deprecating the one before, a suite or runtime RunR has not yet skipped, a red one or one without a result labelled with its log (never an empty one), an upstream outage tested again by the next run, the second in a row labelled"

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
grep -q "$(printf '^publish\t')" "$dir/actions" && fail "a publish with nothing landed: $(cat "$dir/actions")"
echo "ok - a version whose runtime changed on main since the tested commit is left for the next run"

# --- several green toolchains of one run, all on one base (run 43020609005) -----------------------
# rust, spin, tinygo, wasm-tools and zig, each bumped on the same main by its build job: they land
# one after the other; a patch the landings before it moved the lines around (tinygo's mirror line
# after rust's, zig's ARGs after wasm-tools') is made again on the new main and committed when it
# changes the same lines
wt_old="$(arg_in wasm-exec WASM_TOOLS_VERSION)" wt_new="$(next "$(arg_in wasm-exec WASM_TOOLS_VERSION)")"
wt_asset() { echo "https://github.com/bytecodealliance/wasm-tools/releases/download/v$1/wasm-tools-$1-$2-linux.tar.gz"; }
fx "$(wt_asset "$wt_new" x86_64)" 'wasm-tools amd64'
fx "$(wt_asset "$wt_new" aarch64)" 'wasm-tools arm64'
# zig's checksums of this release alone (never the checkout's: its patch changes them, so the
# landing of wasm-tools moves the lines after them)
zig_index="{\"${zig_new}\": {\"x86_64-linux\": {\"shasum\": \"$(sum "zig ${zig_new} amd64")\"}, \"aarch64-linux\": {\"shasum\": \"$(sum "zig ${zig_new} arm64")\"}}}"
fx https://ziglang.org/download/index.json "$zig_index"
# combo NAME [EXTRA_TEST_JSON] — a main with the WebAssembly images ($tmp/NAME.git), the five bumps
# made on it as the build jobs make them, their results green ($tmp/NAME-lang); EXTRA_TEST_JSON goes
# after the third
combo() {
  corigin="$tmp/$1.git" cwork="$tmp/$1" cdir="$tmp/$1-lang"
  git init -q --bare -b main "$corigin"
  git init -q -b main "$cwork"
  mkdir -p "$cwork/runtimes" "$cdir/results" "$cdir/pins"
  for rt in wasm-exec wasm-go wasm-js wasm-python wasm-rust; do cp -r "$here/runtimes/$rt" "$cwork/runtimes/"; done
  cp -r "$here/ci" "$here/lib" "$cwork/"
  (cd "$cwork" && git add -A && git commit -q -m base && git remote add origin "$corigin" && git push -q origin main)
  ctested="$(git -C "$cwork" rev-parse HEAD)"
  local spec issue tool ver suite key r n=0
  : > "$cdir/tests.lines"
  for spec in "60 rust ${new_rust} test-wasm" "61 spin ${spin_new} test-wasm" "62 tinygo ${tinygo_new} test-images" \
    "63 wasm-tools ${wt_new} test-images" "64 zig ${zig_new} test-images"; do
    read -r issue tool ver suite <<<"$spec"
    key="wasm-${tool}" r="$cdir/results/lang-result-wasm-${tool}-build"
    mkdir -p "$r" "$cdir/results/lang-result-${key}-e2e-${suite}"
    (cd "$cwork" && bash ci/lang-bot.sh wasm-bump "$tool" "$ver" > "$r/bump.json" && git diff > "$r/pin.patch" && git checkout -q -- .)
    jq -r .pin "$r/bump.json" > "$r/pin"
    jq -r '.images | join(" ")' "$r/bump.json" > "$r/images"
    echo success > "$r/status"; echo "$ctested" > "$r/sha"; echo "the end of the log" > "$r/tail.txt"
    echo success > "$cdir/results/lang-result-${key}-e2e-${suite}/status"
    jq -nc --argjson i "$issue" --arg r "$tool" --arg v "$ver" --arg k "$key" --arg s "$suite" \
      '{issue: $i, kind: "wasm", runtime: $r, version: $v, full: $v, key: $k, suites: [$s]}' >> "$cdir/tests.lines"
    n=$((n + 1))
    if [ "$n" = 3 ] && [ -n "${2:-}" ]; then echo "$2" >> "$cdir/tests.lines"; fi
  done
  jq -s . "$cdir/tests.lines" > "$cdir/tests.json"
}
# what main should hold: the five bumps one after the other on the base
combo combo
cp -r "$cwork" "$tmp/combo-ref"
for spec in "rust ${new_rust}" "spin ${spin_new}" "tinygo ${tinygo_new}" "wasm-tools ${wt_new}" "zig ${zig_new}"; do
  read -r tool ver <<<"$spec"
  (cd "$tmp/combo-ref" && bash ci/lang-bot.sh wasm-bump "$tool" "$ver" >/dev/null) || fail "the reference's ${tool} bump"
done
(cd "$cwork" && LANG_BOT_NAME="$bot_name" LANG_BOT_EMAIL="$bot_email" bash ci/lang-bot.sh land "$cdir" https://example.test/run/11) > "$tmp/out" 2>&1 \
  || fail "land of the five: $(cat "$tmp/out")"
[ "$(git --git-dir="$corigin" log --format='%s' main)" = "fix(wasm): zig ${zig_new} (was ${zig_old})
fix(wasm): wasm-tools ${wt_new} (was ${wt_old})
fix(wasm): tinygo ${tinygo_new} (was ${tinygo_old})
fix(wasm): spin ${spin_new} (was ${spin_old})
fix(wasm): rust ${new_rust} (was ${old_rust})
base" ] || fail "the five on main: $(git --git-dir="$corigin" log --format='%s' main) $(cat "$tmp/out")"
for f in runtimes/wasm-exec/Dockerfile runtimes/wasm-go/Dockerfile runtimes/wasm-js/Dockerfile runtimes/wasm-python/Dockerfile runtimes/wasm-rust/Dockerfile lib/mirror.sh; do
  [ "$(git --git-dir="$corigin" show "main:$f")" = "$(cat "$tmp/combo-ref/$f")" ] || fail "main's ${f} is not the five bumps: $(git --git-dir="$corigin" diff "$ctested" main -- "$f")"
done
actions="$(cat "$cdir/actions")"
for i in 60 61 62 63 64; do
  grep -qF "$(printf 'label\t%s\tlang: passed' "$i")" <<<"$actions" && grep -qF "$(printf 'close\t%s' "$i")" <<<"$actions" || fail "#${i} not passed: ${actions}"
done
grep -qF 'made again on main' "$cdir/comments/62.md" && git --git-dir="$corigin" log -1 --format=%B --grep="^fix(wasm): tinygo" main | tr '\n' ' ' | grep -qF 'Made again on main' \
  || fail "tinygo was not made again after rust's mirror line: $(cat "$cdir/comments/62.md")"
[ "$(git --git-dir="$corigin" log -5 --format='%an <%ae>|%(trailers:key=RunR-Lang-Bot,valueonly,separator=%x2C)' main | grep -c "^${bot_id}|[a-z-]* [0-9.]*$")" = 5 ] \
  || fail "the five commits' identity and trailer: $(git --git-dir="$corigin" log -5 --format='%an <%ae>|%B' main)"
# one publish for the five (run 43047649717 dispatched five of the same commit): their images once
[ "$(grep -c "$(printf '^publish\t')" <<<"$actions")" = 1 ] && [ "$(tail -n 1 <<<"$actions")" = "$(printf 'publish\twasm-rust,wasm-exec,wasm-go,wasm-js,wasm-python')" ] \
  || fail "one publish of the five: ${actions}"
echo "ok - five green toolchains of one base land one after the other, those whose lines moved made again on the new main: main holds the five bumps, published once"

# made again, zig's checksums are other ones (its index changed since the build): not committed, the
# next run tests it; a test the bot cannot land (its result has no tested commit) is reported and the
# others still land
combo combo2 '{"issue": 65, "kind": "wasm", "runtime": "spin-sdk", "version": "9.9.9", "full": "9.9.9", "key": "wasm-broken", "suites": []}'
mkdir -p "$cdir/results/lang-result-wasm-broken-build"
echo success > "$cdir/results/lang-result-wasm-broken-build/status"
echo wasm-python > "$cdir/results/lang-result-wasm-broken-build/images"
fx https://ziglang.org/download/index.json "{\"${zig_new}\": {\"x86_64-linux\": {\"shasum\": \"$(printf 'c%.0s' {1..64})\"}, \"aarch64-linux\": {\"shasum\": \"$(printf 'd%.0s' {1..64})\"}}}"
(cd "$cwork" && LANG_BOT_NAME="$bot_name" LANG_BOT_EMAIL="$bot_email" bash ci/lang-bot.sh land "$cdir" https://example.test/run/12) > "$tmp/out" 2>&1 \
  || fail "land with a broken one: $(cat "$tmp/out")"
fx https://ziglang.org/download/index.json "$zig_index"
[ "$(git --git-dir="$corigin" log --format='%s' main | head -n 4 | sed 's/ .*//' | paste -sd ' ' -)" = "fix(wasm): fix(wasm): fix(wasm): fix(wasm):" ] \
  && ! git --git-dir="$corigin" log --format='%s' main | grep -qF 'zig' || fail "zig with other checksums was committed: $(git --git-dir="$corigin" log --format='%s' main)"
actions="$(cat "$cdir/actions")"
grep -qF 'is not the change the bot tested' "$cdir/comments/64.md" && grep -qF "$(printf 'comment\t64\t')" <<<"$actions" \
  && ! grep -qE "$(printf '(label|close)\t64')" <<<"$actions" || fail "zig made again otherwise: ${actions} $(cat "$cdir/comments/64.md" 2>/dev/null)"
grep -qF "$(printf 'label\t65\tneeds attention')" <<<"$actions" && grep -qF 'the bot could not land spin-sdk 9.9.9' "$cdir/comments/65.md" \
  || fail "the broken one: ${actions} $(cat "$cdir/comments/65.md" 2>/dev/null)"
for i in 60 61 62 63; do grep -qF "$(printf 'label\t%s\tlang: passed' "$i")" <<<"$actions" || fail "#${i} after the broken one: ${actions}"; done
# the one publish: the images of the four that landed (zig's wasm-exec through tinygo's and spin's)
[ "$(grep -c "$(printf '^publish\t')" <<<"$actions")" = 1 ] && [ "$(tail -n 1 <<<"$actions")" = "$(printf 'publish\twasm-rust,wasm-exec,wasm-go,wasm-js,wasm-python')" ] \
  || fail "one publish of the four: ${actions}"
[ -z "$(git -C "$cwork" status --porcelain)" ] || fail "the checkout is left dirty: $(git -C "$cwork" status --porcelain)"
echo "ok - a bump made again with other lines waits for the next run; a test the bot cannot land is reported, the others still land"
