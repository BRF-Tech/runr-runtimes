#!/usr/bin/env bash
# Tests the smoke tests of lib/smoke.sh without Docker: docker is a shell function that records
# every call and answers like a working image — or like a broken one (another language version,
# a wrong result, an error status, a Spin CLI or hf-serve version that is not the one pinned, no
# CUDA build). Checks that each smoke test passes a working image and fails every broken one, that
# the language runtimes get their handler in /app/code and are called over http from a curl
# container in the server's network namespace (no published port) and once with
# RUNR_MODE=schedule, and that the containers are removed.
#
#   bash test/smoke_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

SCRIPT_DIR="$here"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/smoke.sh
source "$here/lib/smoke.sh"

calls="$tmp/calls"
: > "$calls"

# How the image answers: the language version it reports, the sum, the http status, the trigger of
# the schedule run, the versions of the other images
lang_version=""
sum=42
status=200
schedule_trigger=schedule
wrapper_prints=1.1.0
spin_prints="spin 4.1.0 (8d2c1a3 2026-05-04)"
upload_ok=1
hf_prints=1.1.1
hf_cuda=null
hf_diffusers=null
gpu_host=0
gpu_seen=false

# answer RUNTIME TRIGGER — the JSON body of the smoke handler as the runtime's server prints it
# (Python with blanks after the separators, the others without)
answer() {
  local sep=":" comma=","
  if [ "$1" = python ]; then sep=": " comma=", "; fi
  printf '{"runtime"%s"%s"%s"version"%s"%s"%s"sum"%s%s%s"trigger"%s"%s"}' \
    "$sep" "$1" "$comma" "$sep" "$lang_version" "$comma" "$sep" "$sum" "$comma" "$sep" "$2"
}

docker() {
  echo "docker $*" >> "$calls"
  case "$1" in
    create) return 0 ;;
    cp)
      # the archive of the handler on stdin: its file names
      tar -tf - | sed 's/^/copied /' >> "$calls"
      return 0 ;;
    start)
      if [ "$2" = "-a" ]; then
        echo "RunR runtime starting"
        printf '{"statusCode"%s200,"headers":{"Content-Type":"application/json"},"body":%s}\n' ":" \
          "$(answer "$current" "$schedule_trigger")"
      fi
      return 0 ;;
    logs) echo "server log"; return 0 ;;
    rm) return 0 ;;
    run)
      case "$*" in
        *"--network container:"*)
          printf '%s %s' "$(answer "$current" http)" "$status"
          return 0 ;;
        *"--entrypoint spin "*) echo "$spin_prints"; return 0 ;;
        *"--entrypoint runr-image-upload "*) [ "$upload_ok" = 1 ] && echo "1.0.0"; [ "$upload_ok" = 1 ]; return ;;
        *"--entrypoint sh "*) [ "$upload_ok" = 1 ]; return ;;
        *"--entrypoint nvidia-smi "*) [ "$gpu_host" = 1 ] && echo "GPU 0: NVIDIA L4 (UUID: GPU-0)"; return 0 ;;
        *"--entrypoint python "*)
          local gpu=false
          if [[ "$*" == *"--gpus all"* ]]; then gpu="$gpu_seen"; fi
          printf '{"torch": "2.14.1", "cuda": %s, "gpu": %s, "transformers": "5.20.0", "diffusers": %s}\n' "$hf_cuda" "$gpu" "$hf_diffusers"
          return 0 ;;
        *" version") case "$*" in *hf-serve*) echo "$hf_prints" ;; *) echo "$wrapper_prints" ;; esac; return 0 ;;
      esac ;;
  esac
  return 0
}
# ml_docker_gpu of build-ml.sh: `docker run --gpus all` gives the image a GPU
ml_docker_gpu() {
  docker run --rm --gpus all --entrypoint nvidia-smi "$1" -L 2>/dev/null | grep -q '^GPU '
}

# smoke RUNTIME VERSION — runtime_smoke of exec-RUNTIME:VERSION; its exit status
smoke() {
  current="$1"
  : > "$calls"
  runtime_smoke "registry.test/exec-$1:$2" "$1" "$2" > "$tmp/out" 2>&1
}

# --- the language runtimes ---------------------------------------------------------------------
for spec in python:3.12:3.12.7:main.py nodejs:22.22:22.22.0:main.js php:8.4:8.4.13:main.php go:1.26:1.26.2:main.go; do
  IFS=: read -r runtime version reported file <<< "$spec"
  lang_version="$reported" sum=42 status=200 schedule_trigger=schedule
  smoke "$runtime" "$version" || { cat "$tmp/out"; fail "${runtime}: a working image failed"; }
  grep -q '✓ smoke test' "$tmp/out" || fail "${runtime}: $(cat "$tmp/out")"
  [ "$(grep -c "^copied ${file}$" "$calls")" = 2 ] || fail "${runtime}: ${file} not copied into both containers: $(grep '^copied' "$calls")"
  grep -q "^docker cp - runr-smoke-${runtime}-[0-9]*:/app/code$" "$calls" || fail "${runtime}: not copied to /app/code"
  grep -q "^docker create --name runr-smoke-${runtime}-[0-9]*-schedule -e RUNR_MODE=schedule registry.test/exec-${runtime}:${version}$" "$calls" \
    || fail "${runtime}: no schedule run: $(grep '^docker create' "$calls")"
  curl_call=$(grep -- '--network container:' "$calls")
  [[ "$curl_call" == "docker run --rm --network container:runr-smoke-${runtime}-"*" ${SMOKE_CURL_IMAGE} "*" http://127.0.0.1:8080/smoke" ]] \
    || fail "${runtime}: request: ${curl_call}"
  grep -q -- ' -p \| --publish' "$calls" && fail "${runtime}: a port was published"
  grep -q "^docker rm -f runr-smoke-${runtime}-[0-9]* runr-smoke-${runtime}-[0-9]*-schedule$" "$calls" || fail "${runtime}: containers not removed"

  lang_version="9.9.0"
  smoke "$runtime" "$version" && fail "${runtime}: another language version passed"
  grep -q "missing \"version\":\"${version}." "$tmp/out" || fail "${runtime}: version not reported: $(cat "$tmp/out")"
  lang_version="$reported" sum=41
  smoke "$runtime" "$version" && fail "${runtime}: a wrong result passed"
  sum=42 status=500
  smoke "$runtime" "$version" && fail "${runtime}: HTTP 500 passed"
  status=200 schedule_trigger=http
  smoke "$runtime" "$version" && fail "${runtime}: a schedule run that was not one passed"
  schedule_trigger=schedule
done
current=ruby
runtime_smoke registry.test/exec-ruby:3.4 ruby 3.4 > "$tmp/out" 2>&1 && fail "a runtime without a smoke handler passed"
echo "ok - runtime_smoke: handler in /app/code, http from a curl container, schedule run, each value checked"

# --- the wrapper ---------------------------------------------------------------------------------
wrapper_smoke registry.test/wrapper:1.1.0 1.1.0 > "$tmp/out" 2>&1 || fail "wrapper: $(cat "$tmp/out")"
wrapper_prints=1.0.9
wrapper_smoke registry.test/wrapper:1.1.0 1.1.0 > "$tmp/out" 2>&1 && fail "wrapper: another binary version passed"
echo "ok - wrapper_smoke: the binary prints the tag's version"

# --- WebAssembly -----------------------------------------------------------------------------------
for lang in rust go js python exec; do
  wasm_smoke "registry.test/exec-wasm-${lang}:4.1" "$lang" "$here/runtimes/wasm-${lang}" > "$tmp/out" 2>&1 \
    || { cat "$tmp/out"; fail "wasm-${lang}: a working image failed"; }
done
spin_prints="spin 3.9.0 (abc 2025-01-01)"
wasm_smoke registry.test/exec-wasm-rust:4.1 rust "$here/runtimes/wasm-rust" > "$tmp/out" 2>&1 && fail "wasm: another Spin CLI passed"
spin_prints="spin 4.1.0 (8d2c1a3 2026-05-04)" upload_ok=0
wasm_smoke registry.test/exec-wasm-exec:4.1 exec "$here/runtimes/wasm-exec" > "$tmp/out" 2>&1 && fail "wasm-exec without runr-image-upload passed"
wasm_smoke registry.test/exec-wasm-go:4.1 go "$here/runtimes/wasm-go" > "$tmp/out" 2>&1 || fail "wasm-go needs no runr-image-upload"
upload_ok=1
echo "ok - wasm_smoke: the Spin CLI the Dockerfile pins; wasm-exec with its build and upload tools"

# --- hf-serve ------------------------------------------------------------------------------------------
hf_serve_smoke registry.test/hf-serve:1.1.1 1.1.1 cpu > "$tmp/out" 2>&1 || fail "hf-serve cpu: $(cat "$tmp/out")"
hf_prints=1.1.0
hf_serve_smoke registry.test/hf-serve:1.1.1 1.1.1 cpu > "$tmp/out" 2>&1 && fail "hf-serve: another version passed"
hf_prints=1.1.1
hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda > "$tmp/out" 2>&1 && fail "hf-serve cuda: a CPU build of torch passed"
hf_cuda='"12.6"' hf_diffusers='"0.41.0"'
hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda > "$tmp/out" 2>&1 || fail "hf-serve cuda: $(cat "$tmp/out")"
grep -q 'GPU:      skipped (docker run --gpus all gives no GPU on this host)' "$tmp/out" || fail "hf-serve cuda: GPU skip not reported: $(cat "$tmp/out")"
out=$(ML_SMOKE_GPU=1 hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda 2>&1) && fail "ML_SMOKE_GPU=1 without a GPU passed"
gpu_host=1 gpu_seen=true
: > "$calls"
hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda > "$tmp/out" 2>&1 || fail "hf-serve cuda on a GPU: $(cat "$tmp/out")"
grep -q -- '--gpus all --entrypoint python' "$calls" || fail "hf-serve cuda: imports not on the GPU: $(cat "$calls")"
gpu_seen=false
hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda > "$tmp/out" 2>&1 && fail "hf-serve cuda: torch without the host's GPU passed"
: > "$calls"
ML_SMOKE_GPU=0 hf_serve_smoke registry.test/hf-serve:1.1.1-cuda 1.1.1 cuda > "$tmp/out" 2>&1 || fail "ML_SMOKE_GPU=0: $(cat "$tmp/out")"
grep -q -- '--gpus' "$calls" && fail "ML_SMOKE_GPU=0 used the GPU"
gpu_host=0 hf_cuda=null hf_diffusers=null
hf_serve_smoke registry.test/hf-serve:1.1.1 1.1.1 cpu > "$tmp/out" 2>&1 || fail "hf-serve cpu: $(cat "$tmp/out")"
echo "ok - hf_serve_smoke: version, imports, the CUDA build, on the GPU where there is one"
