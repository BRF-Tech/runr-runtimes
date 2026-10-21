#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load the lib files ──
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/build.sh"
source "${SCRIPT_DIR}/lib/smoke.sh"
source "${SCRIPT_DIR}/lib/build-wasm.sh"
source "${SCRIPT_DIR}/lib/build-ml.sh"
source "${SCRIPT_DIR}/lib/build-hf-serve.sh"
source "${SCRIPT_DIR}/lib/mirror.sh"
source "${SCRIPT_DIR}/lib/registry.sh"
source "${SCRIPT_DIR}/lib/eol.sh"

# ── Help ──
cmd_help() {
  cat <<EOF
Usage: ci.sh <command> [flags]

Every build command builds its images locally and smoke-tests each one (lib/smoke.sh, the ML
runtimes: lib/build-ml.sh); --push pushes them once all passed. --no-smoke skips the smoke test of
a local build and is refused with --push. Every build pulls its base images (--pull).

Commands:
  build [--push] [--no-smoke] [python|nodejs|go|php...]
                                      Language runtimes: discover the upstream versions, skip EOL
                                      ones, build exec-<runtime>:<major.minor> (multi-arch on --push)
  wrapper [--push] [--no-smoke]       The universal runtime wrapper (wrapper:<version of wrapper/main.go>,
                                      multi-arch on --push)
  wasm [--push] [--no-smoke] [rust|go|js|python|exec...]
                                      WebAssembly runtime build images exec-wasm-<lang>:<runtime.yaml version>
                                      (multi-arch on --push)
  ml-runtimes [--push] [--list] [--no-smoke] [pytorch|tensorflow] [cpu|gpu]
                                      PyTorch / TensorFlow runtime images, CPU and -gpu (linux/amd64);
                                      pushed exactly as smoke-tested, --list prints the image references
  hf-serve [--push] [--list] [--no-smoke] [cpu|cuda]
                                      hf-serve:<version> (CPU, multi-arch on --push) and <version>-cuda
                                      (linux/amd64, pushed exactly as smoke-tested)
  mirror-reqs [--dry-run] [image...]  Multi-arch mirror of the upstream reqs images (all, or the ones named)
  mirror-bases [--dry-run]            Multi-arch mirror of the language runtimes' base images
  eol [--prune] [--yes]               EOL check of the GHCR exec-* images + optional cleanup
  help                                Show this message

Environment:
  REGISTRY        Image namespace (default: ghcr.io/brf-tech/runr)
  PLATFORMS       Platforms of multi-arch pushes (default: linux/amd64,linux/arm64)
  BUILDER_NAME    The docker-container buildx builder of multi-arch pushes, created when missing,
                  never made the host's current builder, removed afterwards (default: runr-multiarch)
  ML_SMOKE_GPU    -gpu / -cuda smoke tests: auto (default: on the GPU where docker run --gpus all
                  gives one) | 1 (a GPU is required) | 0 (never on the GPU)
  REQS_UPSTREAMS  Mirror sources in order (default: docker.io mirror.gcr.io public.ecr.aws/docker);
                  a Docker Hub mirror is copied from only by Docker Hub's digest; a REQS_IMAGES
                  source with its registry (quay.io/…) is copied from that registry alone

Examples:
  ci.sh build python             Build + smoke-test the Python images (local, this host's platform)
  ci.sh build --push             Build, smoke-test, then push every language runtime (amd64 + arm64)
  ci.sh wrapper --push           The wrapper image
  ci.sh wasm rust js             Two WebAssembly build images, local
  ci.sh ml-runtimes --list       The ML runtime image references
  ci.sh hf-serve cpu             hf-serve's CPU image, local
  ci.sh mirror-reqs --dry-run    Show the mirror list (no push)
  ci.sh eol                      Show the EOL report
EOF
}

# ── Entrypoint ──
command="${1:-help}"
shift || true

case "$command" in
  build)           cmd_build "$@" ;;
  wrapper)         cmd_build_wrapper "$@" ;;
  wasm)            cmd_build_wasm "$@" ;;
  ml-runtimes)     cmd_build_ml_runtimes "$@" ;;
  hf-serve)        cmd_build_hf_serve "$@" ;;
  mirror-reqs)     cmd_mirror_reqs "$@" ;;
  mirror-bases)    cmd_mirror_bases "$@" ;;
  eol)             cmd_eol "$@" ;;
  help)            cmd_help ;;
  *)               echo "Unknown command: $command"; cmd_help; exit 1 ;;
esac
