#!/usr/bin/env bash
# Tests `ci.sh watch` (lib/watch.sh) without a network: every upstream answers from a fixture file
# (WATCH_FIXTURES), the pins are a throwaway runtimes directory (RUNTIMES_DIR). Checks that a new
# patch release of a published version, a new version (Node.js: the newest minor of an even major
# only; not an odd major, a pre-release, a version below the minimum or one past its end of life),
# a published version past or near its end of life, a framework release newer than its pin and a
# WebAssembly toolchain newer than its ARG are findings with the titles the workflows file issues
# by, that an image that follows its upstream is none, and that an upstream that does not answer
# fails the watch with the rest still checked.
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
hub library/node 20.20-slim 20.20.2-slim 24.22-slim 24.22.1-slim 24.23-slim 24.23.0-slim 25.1-slim 25.1.0-slim
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

reports="$tmp/reports"
rc=0
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "watch: exit ${rc}: $(cat "$tmp/out")"
titles="$(for f in "$reports"/*.md; do head -n 1 "$f"; done | sort)"
expected="lang: nodejs 20.20 end of life 2026-04-30
lang: nodejs 24.23.0 released
lang: php 8.3 end of life 2026-12-31
lang: python 3.10 end of life 2026-10-31
lang: python 3.13.10 released
lang: python 3.16.0 released
lang: pytorch 2.15.0 released
lang: rust 1.99.0 released
lang: tinygo 0.43.0 released"
[ "$titles" = "$expected" ] || fail "findings: $(printf '%s\n' "$titles") $(cat "$tmp/out")"
grep -qF 'runs 3.13.9' "$reports/python-3.13.10.md" || fail "the patch finding names what the tag runs: $(cat "$reports/python-3.13.10.md")"
grep -qF 'not published yet' "$reports/python-3.16.0.md" || fail "the new version: $(cat "$reports/python-3.16.0.md")"
grep -qF 'reached its end of life on 2026-10-31' "$reports/python-3.10-eol.md" || fail "a past end of life"
grep -qF 'in 54 days' "$reports/php-8.3-eol.md" || fail "a near end of life: $(cat "$reports/php-8.3-eol.md")"
grep -qF 'a new tag `exec-pytorch:2.15`' "$reports/pytorch-2.15.0.md" || fail "a new ML tag: $(cat "$reports/pytorch-2.15.0.md")"
grep -qF 'the shim moves first' "$reports/tinygo-0.43.0.md" && fail "tinygo is no Spin"
grep -qF '✓ 1.25: publishes 1.25.4' "$tmp/out" || fail "go follows its upstream: $(cat "$tmp/out")"
grep -qF 'nodejs 25' "$tmp/out" && fail "an odd Node.js major"
echo "ok - findings: a patch release, a new version, end of life past and near, a framework release, WebAssembly toolchains; no odd Node.js major, pre-release, version below the minimum or end-of-life version"

# Spin's finding says the shim moves first
fx https://api.github.com/repos/spinframework/spin/releases/latest '{"tag_name": "v4.2.0"}'
rm -rf "$reports"
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || fail "watch with spin: $(cat "$tmp/out")"
grep -qF 'the shim moves first' "$reports/spin-4.2.0.md" || fail "spin: $(cat "$reports/spin-4.2.0.md")"

# an upstream that does not answer fails the watch, the others are still checked
rm -f "$WATCH_FIXTURES/published-exec-go" "${WATCH_FIXTURES}/https___pypi.org_pypi_torch_json"
rm -rf "$reports"
rc=0
cmd_watch --report="$reports" > "$tmp/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "an upstream that does not answer: exit ${rc}"
grep -qF 'the tags of ghcr.io/brf-tech/runr/exec-go cannot be read' "$tmp/out" || fail "the published tags: $(cat "$tmp/out")"
grep -qF 'pytorch: torch on PyPI or its pin' "$tmp/out" || fail "PyPI: $(cat "$tmp/out")"
[ -f "$reports/php-8.3-eol.md" ] && [ -f "$reports/rust-1.99.0.md" ] || fail "the others were not checked"
echo "ok - an upstream that does not answer fails the watch; the rest is still checked and reported"
