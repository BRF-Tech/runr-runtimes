#!/usr/bin/env bash
# Tests the image builds of ci.sh without Docker: docker is a shell function that records every
# command and succeeds, the smoke tests are shell functions that record the image they test. Every
# build command exits 0 with and without --push (each used to end with
# `[ "$push" = "0" ] && echo …`, the exit status 1 of a successful push); every image build —
# buildx and plain docker build — pulls its base images (--pull) and labels the image with this
# repository (org.opencontainers.image.source); a push is a buildx build in the command's own
# builder (never the host's current one, removed afterwards) that comes after the smoke test of
# every image of the command; --push --no-smoke is refused.
#
#   bash test/build_push_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/build.sh
source "$here/lib/build.sh"
# shellcheck source=../lib/build-wasm.sh
source "$here/lib/build-wasm.sh"
# shellcheck source=../lib/build-hf-serve.sh
source "$here/lib/build-hf-serve.sh"

REGISTRY="registry.test/brf-tech"
log="$tmp/docker.log"
local_images="$tmp/local-images"
: > "$local_images"

# docker: records the command; `image inspect IMAGE` finds the images listed in $local_images,
# `image inspect -f …` answers for a built image (its size, an ID of its name)
docker() {
  echo "docker $*" >> "$log"
  case "$1 ${2:-}" in
    "image inspect")
      case "$*" in
        *'{{.Size}}'*) echo 1000000 ;;
        *'{{.Id}}'*) echo "sha256:$(echo "${*: -1}" | cksum | cut -d' ' -f1)" ;;
        *) grep -qxF -- "${*: -1}" "$local_images" ;;
      esac
      return ;;
  esac
  return 0
}
# the smoke tests: record the image they test
runtime_smoke() { echo "smoke $1" >> "$log"; }
wrapper_smoke() { echo "smoke $1 $2" >> "$log"; }
wasm_smoke() { echo "smoke $1" >> "$log"; }
hf_serve_smoke() { echo "smoke $1 $2 $3" >> "$log"; }

# Docker Hub and endoflife.date: one current Python version
discover_versions() { echo "3.12"; }
check_eol() { echo "supported|2099-10-31"; }
# shellcheck disable=SC2034 # read by cmd_build
RUNTIME_DEFS=("python|library/python|-slim|3.10|major.minor")

# run ARGS… — a ci.sh command in a subshell with ci.sh's shell options; its exit status must be 0
run() {
  : > "$log"
  local status=0
  ( set -euo pipefail; "$@" ) > "$tmp/out" 2>&1 || status=$?
  [ "$status" = "0" ] || { cat "$tmp/out" >&2; fail "$* exited ${status}"; }
}

# every image build of the last command pulls its bases and carries the source label; prints how
# many builds there were
builds_pull() {
  local builds
  builds=$(grep -cE '^docker (buildx )?build ' "$log" || true)
  [ "$builds" -gt 0 ] || fail "$1: no image build"
  if grep -E '^docker (buildx )?build ' "$log" | grep -vqE ' --pull( |$)'; then
    fail "$1: an image build without --pull: $(grep -E '^docker (buildx )?build ' "$log" | grep -vE ' --pull( |$)' | head -n 1)"
  fi
  if grep -E '^docker (buildx )?build ' "$log" | grep -vqF -- '--label org.opencontainers.image.source=https://github.com/BRF-Tech/runr-runtimes '; then
    fail "$1: an image build without the source label: $(grep -E '^docker (buildx )?build ' "$log" | head -n 1)"
  fi
  echo "$builds"
}

# the push of the last command: buildx in its own builder, after every smoke test
pushed() {
  grep -E '^docker buildx build ' "$log" | grep -q -- '--output type=image,push=true' || fail "$1: no buildx push"
  if grep -E '^docker buildx build ' "$log" | grep -vq -- '--builder runr-multiarch '; then
    fail "$1: a push build without --builder runr-multiarch"
  fi
  grep -qE '^docker buildx use ' "$log" && fail "$1: the push builder became the host's current builder"
  grep -qxF 'docker buildx rm runr-multiarch' "$log" || fail "$1: the push builder was not removed"
  local last_smoke first_push
  last_smoke=$(grep -n '^smoke ' "$log" | tail -n 1 | cut -d: -f1)
  first_push=$(grep -nE '^docker (buildx build|push) ' "$log" | head -n 1 | cut -d: -f1)
  [ -n "$last_smoke" ] && [ "$last_smoke" -lt "$first_push" ] || fail "$1: pushed before every image was smoke-tested: $(cat "$log")"
}

# --- every build command, local and --push ------------------------------------------------------
for cmd in cmd_build cmd_build_wrapper cmd_build_wasm "cmd_build_hf_serve cpu"; do
  # shellcheck disable=SC2086 # the command and its argument
  run $cmd
  builds_pull "$cmd" > /dev/null
  grep -qE '^docker buildx build ' "$log" && fail "$cmd: a local build went through buildx"
  grep -q '^smoke ' "$log" || fail "$cmd: no smoke test"

  # shellcheck disable=SC2086
  run $cmd --push
  builds_pull "$cmd --push" > /dev/null
  pushed "$cmd --push"

  # shellcheck disable=SC2086
  run $cmd --no-smoke
  grep -q '^smoke ' "$log" && fail "$cmd --no-smoke: smoke-tested"
  # shellcheck disable=SC2086
  out=$( (set -euo pipefail; $cmd --push --no-smoke) 2>&1) && fail "$cmd --push --no-smoke passed: $out"
  [[ "$out" == *"--no-smoke is for local builds"* ]] || fail "$cmd --push --no-smoke: $out"
done
echo "ok - build commands exit 0 with and without --push, every build with --pull and the source label, smoke before push"

# --- the language runtimes: the version discovered, the runtime's directory --------------------
run cmd_build --push python
grep -qE "^docker build --pull .*--build-arg VERSION=3.12 -t ${REGISTRY}/exec-python:3.12 ${here}/runtimes/python$" "$log" \
  || fail "exec-python: local build $(grep '^docker build' "$log")"
grep -qE "^docker buildx build .*--platform linux/amd64,linux/arm64 .*--build-arg VERSION=3.12 -t ${REGISTRY}/exec-python:3.12 .*${here}/runtimes/python$" "$log" \
  || fail "exec-python: multi-arch push $(grep '^docker buildx build' "$log")"
grep -qxF "smoke ${REGISTRY}/exec-python:3.12" "$log" || fail "exec-python: smoke $(grep '^smoke' "$log")"
out=$( (set -euo pipefail; cmd_build ruby) 2>&1) && fail "an unknown runtime passed: $out"
run cmd_build nodejs
grep -q '^docker build' "$log" && fail "a runtime that was not named was built: $(grep '^docker build' "$log")"
echo "ok - ci.sh build: exec-<runtime>:<version> from runtimes/<runtime>, only the runtimes named"

# --- the wrapper: the version of its binary -------------------------------------------------------
wrapper="$(wrapper_version)"
[[ "$wrapper" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "wrapper version: '${wrapper}'"
run cmd_build_wrapper
grep -qxF "smoke ${REGISTRY}/wrapper:${wrapper} ${wrapper}" "$log" || fail "wrapper: $(cat "$log")"
echo "ok - ci.sh wrapper: wrapper:${wrapper} (const version of wrapper/main.go)"

# --- WebAssembly ------------------------------------------------------------------------------------
run cmd_build_wasm --push
[ "$(grep -c '^docker buildx build ' "$log")" = "5" ] || fail "cmd_build_wasm --push: not five pushes"
[ "$(grep -c '^smoke ' "$log")" = "5" ] || fail "cmd_build_wasm --push: not five smoke tests"
for lang in rust go js python exec; do
  version="$(wasm_runtime_version "$lang")"
  [ -n "$version" ] || fail "wasm-${lang}: no version in runtime.yaml"
  grep -qE "^docker buildx build .* -t ${REGISTRY}/exec-wasm-${lang}:${version} .*${here}/runtimes/wasm-${lang}$" "$log" \
    || fail "wasm-${lang}: push $(grep '^docker buildx build' "$log")"
done
run cmd_build_wasm rust go
[ "$(builds_pull "cmd_build_wasm rust go")" = "2" ] || fail "cmd_build_wasm rust go: not two images"
echo "ok - ci.sh wasm builds every runtime with --pull, smoke-tests each and exits 0 after a push"

# wasm exec next to a receiver image built on this host: a local build uses that receiver, the
# other bases are pulled on their own; a --push build takes the registry's
upload="${REGISTRY}/image-upload:1.0.0"
echo "$upload" > "$local_images"
toolchain=$(dockerfile_bases "$here/runtimes/wasm-exec/Dockerfile" | grep -v '/image-upload:')
[ -n "$toolchain" ] || fail "wasm-exec: no toolchain base in its Dockerfile"
run cmd_build_wasm exec
grep -qE "^docker build --pull .*--build-arg IMAGE_UPLOAD_IMAGE=${upload} --pull=false " "$log" \
  || fail "wasm exec with a local receiver: not built on it ($(grep '^docker build' "$log"))"
grep -qxF "docker pull -q ${toolchain}" "$log" || fail "wasm exec: the toolchain base ${toolchain} was not pulled"
grep -qF "docker pull -q ${upload}" "$log" && fail "wasm exec: the local receiver was pulled"
run cmd_build_wasm exec --push
grep -qF -- '--pull=false' "$log" && fail "wasm exec --push: built on the local receiver"
grep -qE "^docker buildx build .*--build-arg IMAGE_UPLOAD_IMAGE=${upload} " "$log" || fail "wasm exec --push: no receiver build arg"
: > "$local_images"
run cmd_build_wasm exec
grep -qF -- '--pull=false' "$log" && fail "wasm exec without a local receiver: --pull=false"
echo "ok - ci.sh wasm exec builds on a receiver image of this host, the toolchain base pulled"

# --- hf-serve: CPU multi-arch, CUDA pushed as tested -------------------------------------------------
hf="$(hf_serve_version)"
[[ "$hf" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "hf-serve version: '${hf}'"
[ "$(cmd_build_hf_serve --list | paste -sd' ' -)" = "${REGISTRY}/hf-serve:${hf} ${REGISTRY}/hf-serve:${hf}-cuda" ] \
  || fail "hf-serve --list: $(cmd_build_hf_serve --list)"
run cmd_build_hf_serve --push
grep -qxF "smoke ${REGISTRY}/hf-serve:${hf} ${hf} cpu" "$log" || fail "hf-serve cpu smoke: $(grep '^smoke' "$log")"
grep -qxF "smoke ${REGISTRY}/hf-serve:${hf}-cuda ${hf} cuda" "$log" || fail "hf-serve cuda smoke: $(grep '^smoke' "$log")"
grep -qE "^docker build --pull .*--platform linux/amd64 --load -f ${here}/hf-serve/Dockerfile.cuda -t ${REGISTRY}/hf-serve:${hf}-cuda " "$log" \
  || fail "hf-serve cuda: local build $(grep '^docker build' "$log")"
grep -qE "^docker buildx build .* -f ${here}/hf-serve/Dockerfile -t ${REGISTRY}/hf-serve:${hf} " "$log" \
  || fail "hf-serve cpu: multi-arch push $(grep '^docker buildx build' "$log")"
grep -qE "^docker buildx build .*hf-serve:${hf}-cuda" "$log" && fail "hf-serve cuda went through buildx"
grep -qxF "docker push ${REGISTRY}/hf-serve:${hf}-cuda" "$log" || fail "hf-serve cuda: not pushed as tested $(cat "$log")"
echo "ok - ci.sh hf-serve: ${hf} (multi-arch) and ${hf}-cuda (linux/amd64, pushed as tested)"
