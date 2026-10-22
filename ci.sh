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
source "${SCRIPT_DIR}/lib/patch.sh"
source "${SCRIPT_DIR}/lib/feed.sh"

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
                                      ones, build exec-<runtime>:<major.minor>; --push publishes each
                                      changed one as a routine patch (multi-arch, + <full>-r<n>)
  patch [--push] [--check] [--no-feed] [--results FILE] [--only RUNTIME] [--versions all|LIST]
        --level LEVEL [--reason-en TEXT --reason-tr TEXT] [--cves LIST] [--url URL]
        [--deadline-hours N | --deadline-at TIME] [--promote-unchanged] RUNTIME...|all
                                      Patch the language runtimes on request (zero-day): build and
                                      smoke-test the versions named, publish each changed one as a
                                      patch of LEVEL (routine|security|critical|zero-day), update the
                                      patch feed. A dry run without --push; --check only checks the
                                      request (JSON on stdout); --only builds one runtime of it;
                                      --promote-unchanged: an unchanged version's current patch
                                      carries the fix and takes LEVEL in the feed.
                                      LIST: 8.3,8.4 for one runtime, php:8.3,python:3.12 for several.
  feed show [--verify]                The current patch feed (--verify: its signature first)
  feed update [--push] [--results FILE...] [--out FILE]
                                      The next patch feed: the registry's patches it lacks, the
                                      results of patch builds; --push signs and publishes it and
                                      deletes old patch tags (retention). A dry run without --push.
  feed platform [--push] --version V --level LEVEL --reason-en TEXT --reason-tr TEXT [--url URL]
        [--out FILE]                  Add a RunR platform release to the patch feed
  feed validate FILE...               Check feed files against schema/patch-feed.v1.json
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
  REQS_RETRY_PAUSE
                  Seconds before the one retry of such a copy refused with DENIED (default: 10)
  GHCR_USERNAME, GHCR_TOKEN
                  Registry reads of private packages; GHCR_TOKEN also deletes package versions
                  (eol --prune, the patch retention of feed update --push)
  PATCH_LEVEL, PATCH_REASON_EN, PATCH_REASON_TR, PATCH_CVES, PATCH_URL, PATCH_DEADLINE_HOURS,
  PATCH_DEADLINE_AT, PATCH_PROMOTE_UNCHANGED, PATCH_RUNTIMES, PATCH_VERSIONS
                  Defaults of the patch flags (the patch workflow sets them)
  PLATFORM_VERSION, PLATFORM_LEVEL, PLATFORM_REASON_EN, PLATFORM_REASON_TR, PLATFORM_URL
                  Defaults of the feed platform flags
  PATCH_FEED_SIGNING_KEY
                  cosign key reference that signs the feed (default: env://RUNR_PATCH_FEED_COSIGN_KEY);
                  RUNR_PATCH_FEED_COSIGN_PASSWORD is its password
  PATCH_KEEP      Patches kept per runtime version, in the feed and the registry (default: 5)

Examples:
  ci.sh build python             Build + smoke-test the Python images (local, this host's platform)
  ci.sh build --push             Build, smoke-test, then publish every changed language runtime
  ci.sh patch php --level zero-day --reason-en "…" --reason-tr "…" --cves CVE-2026-1234
                                 Dry run of a zero-day patch of every current PHP version
  ci.sh feed show                Print the current patch feed
  ci.sh feed update              What the next feed update would publish and delete
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
  patch)           cmd_patch "$@" ;;
  feed)            cmd_feed "$@" ;;
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
