#!/usr/bin/env bash
# Tests `ci.sh watch` (lib/watch.sh) without a network: every upstream answers from a fixture file
# (WATCH_FIXTURES), the pins and tested-versions are a throwaway runtimes directory (RUNTIMES_DIR).
# Checks that a new patch release of a published version, a new version (Node.js: the newest minor
# of an even major only; Java: an LTS major, from Temurin's tags; .NET: a released version, its
# releases those of the runtime-deps image; Bun: the newest minor, which deprecates the older; not
# an odd major, a pre-release, a version below the minimum or one past its end of life), a
# published version past or near its end of life, a release of a tool a language image pins
# (Maven), a framework release newer than its pin, a WebAssembly toolchain newer than its ARG and
# a newer released series of a base image the reqs mirror pins (alpine, debian by its codename,
# node's even majors, python, golang; not a pre-release or an odd node major)
# are findings with the titles the workflows file issues by, that an image that follows its
# upstream or a release the language bot tested already is none, and that an upstream that does
# not answer fails the watch with the rest still checked (an end of life also without Docker Hub).
#
#   bash test/watch_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skip: watch_test needs jq"; exit 0; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"
# shellcheck source=../lib/patch.sh
source "$here/lib/patch.sh"
# shellcheck source=../lib/watch.sh
source "$here/lib/watch.sh"

export WATCH_FIXTURES="$tmp/fixtures" WATCH_TODAY=2026-11-07 RUNTIMES_DIR="$tmp/runtimes"
mkdir -p "$WATCH_FIXTURES" "$RUNTIMES_DIR/pytorch" "$RUNTIMES_DIR/tensorflow" "$RUNTIMES_DIR/wasm-rust" "$RUNTIMES_DIR/wasm-exec"
# fx URL BODY — the answer of URL
fx() { printf '%s\n' "$2" > "${WATCH_FIXTURES}/${1//[^A-Za-z0-9._-]/_}"; }
# hub REPO TAG... — Docker Hub's tags of REPO, one page
hub() {
  local repo="$1"
  shift
  fx "https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100" "$(printf '%s\n' "$@" | jq -R . | jq -s -c '{results: map({name: .}), next: null}')"
}
published() { local rt="$1"; shift; printf '%s\n' "$@" > "${WATCH_FIXTURES}/published-exec-${rt}"; }
eol() { fx "https://endoflife.date/api/$1/$2.json" "{\"cycle\": \"$2\", \"eol\": $3}"; }

hub library/python 3.9-slim 3.9.20-slim 3.10-slim 3.10.19-slim 3.13-slim 3.13.9-slim 3.13.10-slim 3.13.10 3.16-slim 3.16.0-slim 3.17.0rc1-slim 3.17-slim
published python 3.10 3.10.19-r1 3.13 3.13.9-r1 3.13.9-r2 latest
eol python 3.10 '"2026-10-31"'
eol python 3.13 '"2029-10-31"'
eol python 3.16 '"2032-10-31"'
eol python 3.17 true
hub library/node 20-slim 20.20-slim 20.20.2-slim 24-slim 24.22-slim 24.22.1-slim 24.23-slim 24.23.0-slim 25-slim 25.1-slim 25.1.0-slim 26-slim
published nodejs 20.20 20.20.2-r1 24.22 24.22.1-r1
# Node.js: endoflife.date's cycles are majors
eol nodejs 24 '"2028-04-30"'
eol nodejs 20 '"2026-04-30"'
hub library/golang 1.25-alpine 1.25.4-alpine
published go 1.25 1.25.4-r1
eol go 1.25 false
hub library/php 8.3-cli-alpine 8.3.27-cli-alpine 8.3-cli
published php 8.3 8.3.27-r1
eol php 8.3 '"2026-12-31"'
# Java: Temurin's tags <X.Y.Z>[.<n>]_<build>-jdk (a GA <X>_<build>-jdk) and <X>-jdk, the LTS majors
# from 21 (endoflife.date's cycles are majors); 21.0.12.1 is 21.0.12, as the JVM reports it
hub library/eclipse-temurin 17-jdk 17.0.21_9-jdk 21-jdk 21.0.12_8-jdk 21.0.12.1_1-jdk 21.0.13_9-jdk 21.0.14_7-jre 21-jre \
  25-jdk 25.0.5_8-jdk 26-jdk 26.0.2_10-jdk 29-jdk 29_30-jdk
published java 21.0 21.0.12-r1 25.0 25.0.5-r1
fx https://endoflife.date/api/eclipse-temurin/21.json '{"lts": true, "eol": "2029-12-31"}'
fx https://endoflife.date/api/eclipse-temurin/25.json '{"lts": true, "eol": "2031-09-30"}'
fx https://endoflife.date/api/eclipse-temurin/26.json '{"lts": false, "eol": "2026-09-22"}'
fx https://endoflife.date/api/eclipse-temurin/29.json '{"lts": true, "eol": "2035-09-30"}'
# .NET: its versions are the SDK image's on MCR, its releases the runtime-deps image's (the runtime's
# version, not the SDK's); 11.0 is not released yet; 10.0.14 is tested, not yet published
fx https://mcr.microsoft.com/v2/dotnet/sdk/tags/list '{"name": "dotnet/sdk", "tags": ["9.0", "10.0", "10.0.403", "11.0", "11.0.100-rc.2", "latest"]}'
fx https://mcr.microsoft.com/v2/dotnet/runtime-deps/tags/list '{"name": "dotnet/runtime-deps", "tags": ["10.0-resolute-chiseled-extra", "10.0.13-resolute-chiseled-extra", "10.0.14-resolute-chiseled-extra", "10.0.15-noble-chiseled", "11.0.0-rc.2-resolute-chiseled-extra", "11.0.0-resolute-chiseled-extra"]}'
published dotnet 10.0 10.0.13-r1
fx https://endoflife.date/api/dotnet/10.json '{"releaseDate": "2025-11-11", "lts": true, "eol": "2028-11-14"}'
fx https://endoflife.date/api/dotnet/11.json '{"releaseDate": "2026-11-10", "lts": false, "eol": "2028-05-09"}'
mkdir -p "$RUNTIMES_DIR/dotnet" "$RUNTIMES_DIR/ruby" "$RUNTIMES_DIR/java"
printf '# header\n10.0 10.0.14\n' > "$RUNTIMES_DIR/dotnet/tested-versions"
# Ruby: nothing published yet; 3.3 and 3.4 tested (the next publish publishes them), 4.0 not
hub library/ruby 3.2-slim 3.2.9-slim 3.3-slim 3.3.13-slim 3.4-slim 3.4.12-slim 4.0-slim 4.0.9-slim 4.1-rc-slim 4.1.0-preview1-slim
published ruby
eol ruby 3.3 '"2027-03-31"'
eol ruby 3.4 '"2028-03-31"'
eol ruby 4.0 '"2029-03-31"'
printf '# header\n3.3 3.3.13\n3.4 3.4.12\n' > "$RUNTIMES_DIR/ruby/tested-versions"
# Bun: the newest minor of each major; endoflife.date has majors without an end of life
hub oven/bun 1-slim 1.3-slim 1.3.14-slim 1.4-slim 1.4.4-slim 1.5-slim 1.5.0-slim canary-slim slim
published bun 1.4 1.4.4-r1
fx https://endoflife.date/api/bun/1.json '{"eol": false}'
# the tools of exec-java on Maven Central: Maven's 3.x line (not Maven 4), the dependency plugin
printf 'ARG MAVEN_VERSION=3.9.16\nARG MAVEN_SHA512=0000\nARG MAVEN_DEPENDENCY_PLUGIN=3.11.0\n' > "$RUNTIMES_DIR/java/Dockerfile"
fx https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml \
  "$(printf '<metadata>\n  <versioning>\n    <latest>4.0.0</latest>\n    <versions>\n      <version>3.9.16</version>\n      <version>3.9.17</version>\n      <version>4.0.0-rc-7</version>\n      <version>4.0.0</version>\n    </versions>\n  </versioning>\n</metadata>')"
fx https://repo.maven.apache.org/maven2/org/apache/maven/plugins/maven-dependency-plugin/maven-metadata.xml \
  '<metadata><versioning><versions><version>3.10.0</version><version>3.11.0</version></versions></versioning></metadata>'

printf '# torch\ntorch==2.14.1\ntorchvision==0.29.1\n' > "$RUNTIMES_DIR/pytorch/requirements-torch.txt"
printf 'tensorflow-cpu==2.21.0\n' > "$RUNTIMES_DIR/tensorflow/requirements-cpu.txt"
fx https://pypi.org/pypi/torch/json '{"info": {"version": "2.15.0"}}'
fx https://pypi.org/pypi/tensorflow-cpu/json '{"info": {"version": "2.21.0"}}'
printf 'ARG RUST_VERSION=1.98.1\nARG SPIN_VERSION=4.1.0\n' > "$RUNTIMES_DIR/wasm-rust/Dockerfile"
printf 'ARG TINYGO_VERSION=0.42.0\nARG SPIN_VERSION=4.1.0\nARG WASI_SDK_VERSION=34\nARG ZIG_VERSION=0.16.0\nARG WASM_TOOLS_VERSION=1.240.0\nARG COMPONENTIZE_PY_VERSION=0.25.1\nARG SPIN_SDK_VERSION=5.0.0\n' > "$RUNTIMES_DIR/wasm-exec/Dockerfile"
fx https://api.github.com/repos/spinframework/spin/releases/latest '{"tag_name": "v4.1.0"}'
fx https://api.github.com/repos/tinygo-org/tinygo/releases/latest '{"tag_name": "v0.43.0"}'
fx https://api.github.com/repos/WebAssembly/wasi-sdk/releases/latest '{"tag_name": "wasi-sdk-34"}'
fx https://api.github.com/repos/bytecodealliance/wasm-tools/releases/latest '{"tag_name": "v1.240.0"}'
fx https://ziglang.org/download/index.json '{"master": {}, "0.15.1": {}, "0.16.0": {}}'
fx https://pypi.org/pypi/componentize-py/json '{"info": {"version": "0.25.1"}}'
fx https://pypi.org/pypi/spin-sdk/json '{"info": {"version": "5.0.0"}}'
hub library/rust 1.98.1-slim-bookworm 1.99.0-slim-bookworm 1.99.0-alpine 2.0.0-beta-slim-bookworm
# the base-image series of the reqs mirror (WATCH_REQS_FILE): alpine 3.21, Debian bookworm (12),
# node 22, python 3.13, golang 1.25; upstream alpine 3.23 (3.24 without a release yet), Debian 13
# (14 without a point release), node 24 (25 odd, 26 without a release), python 3.16 (3.17 a
# release candidate), golang 1.25
cat > "$tmp/mirror.sh" <<'EOF'
REQS_IMAGES=(
  # ── a comment ──
  "alpine:3.21|alpine:3.21"
  "redis:7-alpine|redis:7-alpine"
  "alpine-helm:3.15|alpine/helm:3.15"
  "node:22-bookworm-slim|node:22-bookworm-slim"
  "python:3.13-slim-bookworm|python:3.13-slim-bookworm"
  "golang:1.25-alpine|golang:1.25-alpine"
  "rust:1.95.0-slim-bookworm|rust:1.95.0-slim-bookworm@sha256:d7482085ff5b415f84dba5647ae71606650bdef00db7aeb69f4b3d170c3e4082"
)
EOF
export WATCH_REQS_FILE="$tmp/mirror.sh"
hub library/alpine 3.21 3.21.4 3.22 3.22.2 3.23 3.23.0 3.24 edge latest
hub library/debian 12 12.12 bookworm 13 13.1 trixie 14 forky testing latest

reports="$tmp/reports"
rc=0
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "watch: exit ${rc}: $(cat "$tmp/out")"
titles="$(for f in "$reports"/*.md; do head -n 1 "$f"; done | sort)"
expected="lang: bun 1.5.0 released
lang: java 21.0.13 released
lang: java 29.0.0 released
lang: maven 3.9.17 released
lang: nodejs 20.20 end of life 2026-04-30
lang: nodejs 24.23.0 released
lang: php 8.3 end of life 2026-12-31
lang: python 3.10 end of life 2026-10-31
lang: python 3.13.10 released
lang: python 3.16.0 released
lang: pytorch 2.15.0 released
lang: ruby 4.0.9 released
lang: rust 1.99.0 released
lang: tinygo 0.43.0 released"
expected="base: alpine 3.23 available
base: debian 13 (trixie) available
base: node 24 available
base: python 3.16 available
${expected}"
[ "$titles" = "$expected" ] || fail "findings: $(printf '%s\n' "$titles") $(cat "$tmp/out")"
grep -qF 'runs 3.13.9' "$reports/python-3.13.10.md" || fail "the patch finding names what the tag runs: $(cat "$reports/python-3.13.10.md")"
grep -qF 'not published yet' "$reports/python-3.16.0.md" || fail "the new version: $(cat "$reports/python-3.16.0.md")"
grep -qF 'reached its end of life on 2026-10-31' "$reports/python-3.10-eol.md" || fail "a past end of life"
grep -qF 'in 54 days' "$reports/php-8.3-eol.md" || fail "a near end of life: $(cat "$reports/php-8.3-eol.md")"
grep -qF 'a new tag `exec-pytorch:2.15`' "$reports/pytorch-2.15.0.md" || fail "a new ML tag: $(cat "$reports/pytorch-2.15.0.md")"
grep -qF "whether RunR's Spin shim runs" "$reports/tinygo-0.43.0.md" && fail "tinygo is no Spin"
grep -qF 'and the mirrored base image' "$reports/tinygo-0.43.0.md" || fail "tinygo's base image: $(cat "$reports/tinygo-0.43.0.md")"
grep -qF "RunR's ML e2e case" "$reports/pytorch-2.15.0.md" || fail "the ML test: $(cat "$reports/pytorch-2.15.0.md")"
grep -qF '✓ 1.25: publishes 1.25.4' "$tmp/out" || fail "go follows its upstream: $(cat "$tmp/out")"
grep -qF 'nodejs 25' "$tmp/out" && fail "an odd Node.js major"
# the base-image series: what the mirror pins, the newest released upstream series, a person decides
grep -qF -- '- `alpine:3.21`' "$reports/base-alpine-3.23.md" && ! grep -qF 'alpine/helm' "$reports/base-alpine-3.23.md" \
  && grep -qF 'pins alpine up to 3.21' "$reports/base-alpine-3.23.md" && grep -qF 'nothing is mirrored by itself' "$reports/base-alpine-3.23.md" \
  || fail "the alpine series: $(cat "$reports/base-alpine-3.23.md")"
grep -qF -- '- `rust:1.95.0-slim-bookworm`' "$reports/base-debian-13.md" && grep -qF 'pins debian up to 12' "$reports/base-debian-13.md" \
  && grep -qF '(`debian:13`)' "$reports/base-debian-13.md" || fail "the debian series: $(cat "$reports/base-debian-13.md")"
grep -qF '(`node:24-slim`)' "$reports/base-node-24.md" || fail "the node series: $(cat "$reports/base-node-24.md")"
grep -qF '✓ golang: the reqs mirror pins up to 1.25, the newest upstream is 1.25' "$tmp/out" || fail "golang follows its upstream: $(cat "$tmp/out")"
echo "ok - findings: a patch release, a new version, end of life past and near, a framework release, WebAssembly toolchains, newer base-image series of the reqs mirror; no odd Node.js major, pre-release, version below the minimum or end-of-life version"

# Java, .NET, Ruby and Bun as the build discovers them; a version the bot tested is the publish's
grep -qF 'runs 21.0.12' "$reports/java-21.0.13.md" && grep -qF '`library/eclipse-temurin:21.0.13_9-jdk`' "$reports/java-21.0.13.md" \
  || fail "java's patch release (21.0.12.1 is 21.0.12, a -jre tag is none): $(cat "$reports/java-21.0.13.md")"
grep -qF '`library/eclipse-temurin:29-jdk`' "$reports/java-29.0.0.md" || fail "a new Temurin LTS from its GA tag: $(cat "$reports/java-29.0.0.md")"
grep -qE 'java (17|26)' <<< "$titles" && fail "a Temurin below the minimum or not LTS: ${titles}"
grep -qF '✓ 25.0: publishes 25.0.5' "$tmp/out" || fail "java 25 follows its upstream: $(cat "$tmp/out")"
grep -qF '✓ 10.0: publishes 10.0.13; 10.0.14 is tested (tested-versions), the next publish publishes it' "$tmp/out" \
  || fail ".NET's runtime release from runtime-deps, tested: $(cat "$tmp/out")"
grep -qE 'dotnet (10\.0\.403|10\.0\.15|11)' "$tmp/out" && fail "an SDK version, another image's tag or a .NET not released yet: $(cat "$tmp/out")"
for v in 3.3.13 3.4.12; do
  grep -qF "✓ ${v%.*}: ${v} is tested (tested-versions), not published yet" "$tmp/out" || fail "ruby ${v}, tested, unpublished: $(cat "$tmp/out")"
done
grep -qF 'ruby 3.2' "$tmp/out" && fail "a Ruby below the minimum"
grep -qF 'ruby 4.1' "$tmp/out" && fail "a Ruby preview or release candidate"
grep -qF 'not published yet' "$reports/ruby-4.0.9.md" || fail "ruby 4.0: $(cat "$reports/ruby-4.0.9.md")"
grep -qF 'It also deprecates bun 1.4 with a sunset date' "$reports/bun-1.5.0.md" || fail "bun 1.5 deprecates 1.4: $(cat "$reports/bun-1.5.0.md")"
grep -qF 'bun 1.4' <<< "$titles" && fail "bun 1.4 after 1.5"
grep -qF 'runtimes/java/Dockerfile` pins `ARG MAVEN_VERSION=3.9.16`' "$reports/maven-3.9.17.md" && grep -qF 'SHA-512' "$reports/maven-3.9.17.md" \
  || fail "maven: $(cat "$reports/maven-3.9.17.md")"
grep -qF '✓ maven-dependency-plugin: MAVEN_DEPENDENCY_PLUGIN=3.11.0, the newest 3.x is 3.11.0' "$tmp/out" || fail "the dependency plugin: $(cat "$tmp/out")"
echo "ok - Java (Temurin's tags, LTS), .NET (MCR, the runtime's releases, released only), Ruby, Bun (the newest minor, the older deprecated), Maven's pins; a tested version waits for the publish"

# Spin's finding says RunR's suites check its shim
fx https://api.github.com/repos/spinframework/spin/releases/latest '{"tag_name": "v4.2.0"}'
rm -rf "$reports"
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || fail "watch with spin: $(cat "$tmp/out")"
grep -qF "whether RunR's Spin shim runs what the new Spin CLI builds" "$reports/spin-4.2.0.md" || fail "spin: $(cat "$reports/spin-4.2.0.md")"

# an upstream that does not answer fails the watch, the others are still checked: the published
# versions' end of life also when Docker Hub does not answer; endoflife.date's error is none of its
# 404s
rm -f "$WATCH_FIXTURES/published-exec-go" "${WATCH_FIXTURES}/https___pypi.org_pypi_torch_json"
rm -f "${WATCH_FIXTURES}/https___hub.docker.com_v2_repositories_library_node_tags__page_size_100"
rm -f "${WATCH_FIXTURES}/https___endoflife.date_api_ruby_4.0.json"
touch "${WATCH_FIXTURES}/https___endoflife.date_api_ruby_4.0.json@500"
rm -f "${WATCH_FIXTURES}/https___repo.maven.apache.org_maven2_org_apache_maven_apache-maven_maven-metadata.xml"
rm -rf "$reports"
rc=0
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an upstream that does not answer: exit ${rc}"
grep -qF 'the tags of ghcr.io/brf-tech/runr/exec-go cannot be read' "$tmp/out" || fail "the published tags: $(cat "$tmp/out")"
grep -qF 'pytorch: torch on PyPI or its pin' "$tmp/out" || fail "PyPI: $(cat "$tmp/out")"
grep -qF 'the tags of library/node cannot be read' "$tmp/out" && [ -f "$reports/nodejs-20.20-eol.md" ] \
  || fail "Node.js 20's end of life without Docker Hub: $(cat "$tmp/out")"
grep -qF '✗ 4.0: endoflife.date (ruby) cannot be read' "$tmp/out" && [ ! -f "$reports/ruby-4.0.9.md" ] || fail "endoflife.date's error: $(cat "$tmp/out")"
grep -qF 'maven: its releases on Maven Central (org.apache.maven:apache-maven) cannot be read' "$tmp/out" || fail "Maven Central: $(cat "$tmp/out")"
[ -f "$reports/php-8.3-eol.md" ] && [ -f "$reports/rust-1.99.0.md" ] && [ -f "$reports/bun-1.5.0.md" ] || fail "the others were not checked"
echo "ok - an upstream that does not answer fails the watch; the rest is still checked and reported, an end of life also without Docker Hub"

# a version the language bot archived (runtimes/<runtime>/archived-versions) is followed no more
mkdir -p "$RUNTIMES_DIR/python"
echo "3.13 2029-10-31 sha256:$(printf '0%.0s' {1..64})" > "$RUNTIMES_DIR/python/archived-versions"
rm -rf "$reports"
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || true
[ ! -f "$reports/python-3.13.10.md" ] && [ -f "$reports/python-3.16.0.md" ] && grep -qF '✓ 3.13: archived (ghcr.io/brf-tech/runr/exec-python:eol-3.13)' "$tmp/out" \
  || fail "an archived version was followed: $(cat "$tmp/out")"
grep -qF 'archives it by itself and closes this issue' "$reports/python-3.10-eol.md" || fail "the end-of-life notice: $(cat "$reports/python-3.10-eol.md")"
echo "ok - an archived version is followed no more; the end-of-life notice says the bot archives it"
