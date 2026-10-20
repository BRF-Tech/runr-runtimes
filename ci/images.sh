#!/usr/bin/env bash
# The images this repository publishes, as the workflows select them: one key per image (or per
# language runtime with its versions), the ci.sh command that builds it, and which keys a change
# touches.
#
#   ci/images.sh list [cpu|gpu|languages]   the keys (default: every one)
#   ci/images.sh select SPEC                the keys SPEC names: "all", "cpu", "gpu", "languages",
#                                           or keys separated by blanks or commas; an unknown
#                                           key fails
#   ci/images.sh changed BASE HEAD          the keys whose sources changed between two commits
#                                           (git diff --name-only BASE HEAD); nothing for an
#                                           all-zero BASE (the first push of a branch)
#   ci/images.sh paths                      the same for a list of changed paths on stdin
#   ci/images.sh command KEY                the ci.sh arguments that build KEY (without --push)
#   ci/images.sh json KEY...                the keys as a JSON array (a workflow matrix)
#
# Keys: python nodejs go php (exec-<runtime>, every version ci.sh build discovers), wrapper,
# wasm-rust wasm-go wasm-js wasm-python wasm-exec, pytorch tensorflow (the CPU images), hf-serve
# (CPU) — the "cpu" keys of the publish workflow — and pytorch-gpu tensorflow-gpu hf-serve-cuda,
# the "gpu" keys of the heavy-images workflow.
#
# What a change touches: the directory of the image (runtimes/<runtime>/, wrapper/, hf-serve/),
# the ML runtimes also the Python runtime's handler server (their build context runtime-python),
# the GPU images the sources of their CPU image. Not an image change: Markdown files, the tests
# of the wrapper and of hf-serve, and the runtime.yaml of a runtime whose tag does not come from
# it (the catalog manifest the API bundles; the WebAssembly runtimes take their tag from it). The
# build tooling (ci.sh, lib/) is covered by the shell tests; a change to it publishes nothing by
# itself — run the publish workflow for the images it should rebuild.
set -euo pipefail

CPU_KEYS="python nodejs go php wrapper wasm-rust wasm-go wasm-js wasm-python wasm-exec pytorch tensorflow hf-serve"
GPU_KEYS="pytorch-gpu tensorflow-gpu hf-serve-cuda"
LANGUAGE_KEYS="python nodejs go php"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 2
}

# keys_of_path PATH — the keys a change of PATH touches, one per line
keys_of_path() {
  local path="$1"
  case "$path" in
    *.md) return 0 ;;
    wrapper/*_test.go) return 0 ;;
    hf-serve/tests/*|hf-serve/requirements-test.txt) return 0 ;;
    runtimes/python/runtime.yaml|runtimes/nodejs/runtime.yaml|runtimes/go/runtime.yaml|runtimes/php/runtime.yaml) return 0 ;;
    runtimes/pytorch/runtime.yaml|runtimes/tensorflow/runtime.yaml) return 0 ;;
  esac
  case "$path" in
    runtimes/python/server.py|runtimes/python/runner.py|runtimes/python/entrypoint.sh)
      printf '%s\n' python pytorch tensorflow pytorch-gpu tensorflow-gpu ;;
    runtimes/python/*) echo python ;;
    runtimes/nodejs/*) echo nodejs ;;
    runtimes/go/*) echo go ;;
    runtimes/php/*) echo php ;;
    runtimes/pytorch/*) printf '%s\n' pytorch pytorch-gpu ;;
    runtimes/tensorflow/*) printf '%s\n' tensorflow tensorflow-gpu ;;
    runtimes/wasm-rust/*) echo wasm-rust ;;
    runtimes/wasm-go/*) echo wasm-go ;;
    runtimes/wasm-js/*) echo wasm-js ;;
    runtimes/wasm-python/*) echo wasm-python ;;
    runtimes/wasm-exec/*) echo wasm-exec ;;
    wrapper/*) echo wrapper ;;
    hf-serve/*) printf '%s\n' hf-serve hf-serve-cuda ;;
  esac
}

# in_order KEY... — the keys deduplicated, in the order of CPU_KEYS then GPU_KEYS
in_order() {
  local key wanted=" $* "
  for key in $CPU_KEYS $GPU_KEYS; do
    [[ "$wanted" == *" ${key} "* ]] && echo "$key"
  done
  return 0
}

cmd_paths() {
  local path keys=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r key; do
      [ -n "$key" ] && keys+=("$key")
    done < <(keys_of_path "$path")
  done
  in_order ${keys[@]+"${keys[@]}"}
}

cmd_changed() {
  local base="${1:-}" head="${2:-}" files
  [ -n "$base" ] && [ -n "$head" ] || usage
  if [[ "$base" =~ ^0+$ ]]; then
    echo "first push of the branch (no previous commit): no image selected; run the workflow by hand to publish" >&2
    return 0
  fi
  if ! files=$(git diff --name-only "$base" "$head" 2>/dev/null); then
    echo "cannot compare ${base}..${head} (a force push?): run the workflow by hand with the images to publish" >&2
    return 1
  fi
  printf '%s\n' "$files" | cmd_paths
}

# shellcheck disable=SC2206 # the key lists are split into their words
cmd_select() {
  local spec="${*//,/ }" word keys=() unknown=""
  [ -n "${spec// /}" ] || { echo "no image named (all, cpu, gpu, languages, or keys: ${CPU_KEYS} ${GPU_KEYS})" >&2; return 1; }
  for word in $spec; do
    case "$word" in
      all) keys+=($CPU_KEYS $GPU_KEYS) ;;
      cpu) keys+=($CPU_KEYS) ;;
      gpu) keys+=($GPU_KEYS) ;;
      languages) keys+=($LANGUAGE_KEYS) ;;
      *)
        if [[ " ${CPU_KEYS} ${GPU_KEYS} " == *" ${word} "* ]]; then
          keys+=("$word")
        else
          unknown="${unknown:+${unknown}, }${word}"
        fi ;;
    esac
  done
  if [ -n "$unknown" ]; then
    echo "unknown image: ${unknown} (all, cpu, gpu, languages, or keys: ${CPU_KEYS} ${GPU_KEYS})" >&2
    return 1
  fi
  in_order "${keys[@]}"
}

cmd_list() {
  case "${1:-}" in
    "") in_order $CPU_KEYS $GPU_KEYS ;;
    cpu) in_order $CPU_KEYS ;;
    gpu) in_order $GPU_KEYS ;;
    languages) in_order $LANGUAGE_KEYS ;;
    *) usage ;;
  esac
}

cmd_command() {
  case "${1:-}" in
    python|nodejs|go|php) echo "build $1" ;;
    wrapper) echo "wrapper" ;;
    wasm-rust|wasm-go|wasm-js|wasm-python|wasm-exec) echo "wasm ${1#wasm-}" ;;
    pytorch|tensorflow) echo "ml-runtimes $1 cpu" ;;
    pytorch-gpu|tensorflow-gpu) echo "ml-runtimes ${1%-gpu} gpu" ;;
    hf-serve) echo "hf-serve cpu" ;;
    hf-serve-cuda) echo "hf-serve cuda" ;;
    *) echo "unknown image: ${1:-} (keys: ${CPU_KEYS} ${GPU_KEYS})" >&2; return 1 ;;
  esac
}

cmd_json() {
  local key out=""
  for key in "$@"; do
    out="${out:+${out},}\"${key}\""
  done
  echo "[${out}]"
}

command="${1:-}"
shift || true
case "$command" in
  list) cmd_list "$@" ;;
  select) cmd_select "$@" ;;
  changed) cmd_changed "$@" ;;
  paths) cmd_paths ;;
  command) cmd_command "$@" ;;
  json) cmd_json "$@" ;;
  *) usage ;;
esac
