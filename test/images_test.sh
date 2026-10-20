#!/usr/bin/env bash
# Tests ci/images.sh, the image selection of the workflows: the keys a change touches (the image's
# directory, the Python handler server of the ML runtimes, the GPU images with their CPU sources;
# nothing for Markdown, tests, catalog-only manifests and the build tooling), the keys a manual
# run names, the ci.sh command of every key, a first push and a force push. `changed` runs on a
# throwaway git repository.
#
#   bash test/images_test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

images() { bash "$here/ci/images.sh" "$@"; }
# touched PATH... — the keys a change of these paths touches, on one line
touched() { printf '%s\n' "$@" | images paths | paste -sd' ' -; }

# --- what a change touches ------------------------------------------------------------------------
[ "$(touched runtimes/python/Dockerfile)" = "python" ] || fail "python Dockerfile: $(touched runtimes/python/Dockerfile)"
[ "$(touched runtimes/python/server.py)" = "python pytorch tensorflow pytorch-gpu tensorflow-gpu" ] \
  || fail "python server: $(touched runtimes/python/server.py)"
[ "$(touched runtimes/nodejs/server.js runtimes/php/server.php runtimes/go/wrapper_http.go)" = "nodejs go php" ] \
  || fail "nodejs, php, go: $(touched runtimes/nodejs/server.js runtimes/php/server.php runtimes/go/wrapper_http.go)"
[ "$(touched runtimes/pytorch/requirements-torch.txt)" = "pytorch pytorch-gpu" ] || fail "pytorch pin"
[ "$(touched runtimes/tensorflow/Dockerfile.gpu)" = "tensorflow tensorflow-gpu" ] || fail "tensorflow gpu Dockerfile"
[ "$(touched runtimes/wasm-rust/Cargo.toml runtimes/wasm-exec/runr-wasm-exec)" = "wasm-rust wasm-exec" ] || fail "wasm"
[ "$(touched runtimes/wasm-js/runtime.yaml)" = "wasm-js" ] || fail "a wasm runtime.yaml (its tag) touched nothing"
[ "$(touched wrapper/main.go)" = "wrapper" ] || fail "wrapper"
[ "$(touched hf-serve/runr_hf_serve/server.py)" = "hf-serve hf-serve-cuda" ] || fail "hf-serve"
[ -z "$(touched README.md runtimes/python/README.md wrapper/main_test.go hf-serve/tests/test_server.py \
  hf-serve/requirements-test.txt runtimes/python/runtime.yaml runtimes/pytorch/runtime.yaml ci.sh lib/build.sh \
  test/build_push_test.sh .github/workflows/publish.yml)" ] || fail "a change without an image effect touched an image"
# every directory under runtimes/ is a key's (a new runtime needs one)
for dir in "$here"/runtimes/*/; do
  name="$(basename "$dir")"
  [ -n "$(touched "runtimes/${name}/Dockerfile")" ] || fail "runtimes/${name} belongs to no image key"
done
echo "ok - paths: the image's directory, the ML runtimes' handler server, nothing for docs, tests and tooling"

# --- manual selection ---------------------------------------------------------------------------------
[ "$(images select all | wc -l)" = 16 ] || fail "all: $(images select all)"
[ "$(images select cpu | paste -sd' ' -)" = "python nodejs go php wrapper wasm-rust wasm-go wasm-js wasm-python wasm-exec pytorch tensorflow hf-serve" ] \
  || fail "cpu: $(images select cpu)"
[ "$(images select gpu | paste -sd' ' -)" = "pytorch-gpu tensorflow-gpu hf-serve-cuda" ] || fail "gpu"
[ "$(images select "wrapper, python wrapper" | paste -sd' ' -)" = "python wrapper" ] || fail "keys: $(images select "wrapper, python wrapper")"
[ "$(images select languages | paste -sd' ' -)" = "python nodejs go php" ] || fail "languages"
out=$(images select ruby 2>&1) && fail "an unknown key passed: $out"
[[ "$out" == "unknown image: ruby"* ]] || fail "unknown key: $out"
out=$(images select "" 2>&1) && fail "an empty selection passed"
[ "$(images json python wrapper)" = '["python","wrapper"]' ] || fail "json: $(images json python wrapper)"
[ "$(images json)" = '[]' ] || fail "json of nothing: $(images json)"
echo "ok - select: all, cpu, gpu, languages, named keys; unknown keys fail"

# --- the command of every key ----------------------------------------------------------------------
for key in $(images list); do
  args="$(images command "$key")" || fail "${key}: no command"
  # shellcheck disable=SC2086 # ci.sh's arguments
  case "${args%% *}" in
    build|wrapper|wasm|ml-runtimes|hf-serve) ;;
    *) fail "${key}: ${args}" ;;
  esac
  grep -q "^  ${args%% *})" "$here/ci.sh" || fail "${key}: ci.sh has no command ${args%% *}"
done
[ "$(images command pytorch-gpu)" = "ml-runtimes pytorch gpu" ] || fail "pytorch-gpu: $(images command pytorch-gpu)"
[ "$(images command wasm-exec)" = "wasm exec" ] || fail "wasm-exec"
[ "$(images command hf-serve-cuda)" = "hf-serve cuda" ] || fail "hf-serve-cuda"
images command ruby >/dev/null 2>&1 && fail "a command for an unknown key"
echo "ok - command: a ci.sh command for every key"

# --- changed: between two commits --------------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo/runtimes/php" "$repo/wrapper"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
echo x > "$repo/runtimes/php/server.php"
echo y > "$repo/wrapper/README.md"
git -C "$repo" add .
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m change
[ "$(cd "$repo" && images changed HEAD~1 HEAD)" = "php" ] || fail "changed: $(cd "$repo" && images changed HEAD~1 HEAD)"
out=$(cd "$repo" && images changed 0000000000000000000000000000000000000000 HEAD 2>&1)
[[ "$out" == "first push"* ]] || fail "first push: $out"
out=$(cd "$repo" && images changed 1111111111111111111111111111111111111111 HEAD 2>&1) && fail "an unknown base passed: $out"
[[ "$out" == "cannot compare"* ]] || fail "unknown base: $out"
echo "ok - changed: the keys of a commit range; nothing on a first push, a failure on an unknown base"
