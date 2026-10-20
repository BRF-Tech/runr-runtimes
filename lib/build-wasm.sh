# cmd_build_wasm — build images of the WebAssembly runtimes (runtimes/wasm-<lang>):
# ghcr.io/brf-tech/runr/exec-wasm-<lang>:<version>, the version from the runtime's runtime.yaml.
#
#   ci.sh wasm                 all five (rust, go, js, python, exec), local single-platform build,
#                              each one smoke-tested (wasm_smoke)
#   ci.sh wasm rust js         only these
#   ci.sh wasm exec            the wasm-exec toolchain image (wasi-sdk, Zig, TinyGo); it copies
#                              runr-image-upload from IMAGE_UPLOAD_IMAGE (default: the published
#                              ghcr.io/brf-tech/runr/image-upload:1.0.0 of BRF-Tech/runr; a local
#                              build uses a receiver image of this host as it is)
#   ci.sh wasm --push          build + smoke test, then a multi-arch build + push (PLATFORMS)

WASM_RUNTIME_LANGS=(rust go js python exec)

# version of a WebAssembly runtime: the first `- version: "X"` of its runtime.yaml
wasm_runtime_version() {
  awk '/^[[:space:]]*-[[:space:]]*version:/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["'"'"' ]/, "", v); print v; exit }' \
    "$(runtime_dir "wasm-$1")/runtime.yaml"
}

cmd_build_wasm() {
  build_options "ci.sh wasm" "$@" || return 1
  local push="$_push" smoke="$_smoke" langs=() arg
  for arg in ${_args[@]+"${_args[@]}"}; do
    case "$arg" in
      rust|go|js|python|exec) langs+=("$arg") ;;
      *) echo -e "${RED}unknown argument: ${arg} (rust, go, js, python, exec, --push, --no-smoke)${NC}"; return 1 ;;
    esac
  done
  [ "${#langs[@]}" -eq 0 ] && langs=("${WASM_RUNTIME_LANGS[@]}")

  echo -e "${BOLD}── WebAssembly runtime build images (Spin toolchains) ──${NC}"
  local lang dir version tag built=()
  for lang in "${langs[@]}"; do
    dir="$(runtime_dir "wasm-${lang}")"
    version="$(wasm_runtime_version "$lang" 2>/dev/null || true)"
    if [ ! -d "$dir" ] || [ -z "$version" ]; then
      echo -e "${RED}wasm-${lang}: runtime directory or version not found (${dir})${NC}"
      return 1
    fi
    tag="${REGISTRY}/exec-wasm-${lang}:${version}"
    echo "==> Building ${tag}"
    local extra=() push_extra=()
    if [ "$lang" = "exec" ]; then
      # the receiver image carries runr-image-upload, which the toolchain image copies
      local upload="${IMAGE_UPLOAD_IMAGE:-${REGISTRY}/image-upload:${IMAGE_UPLOAD_VERSION:-1.0.0}}"
      extra=(--build-arg "IMAGE_UPLOAD_IMAGE=${upload}")
      push_extra=("${extra[@]}")
      if [ "$push" = "0" ] && docker image inspect "$upload" >/dev/null 2>&1; then
        # a local build on a receiver image of this host uses it as it is, which --pull would
        # replace with the registry's: the other bases are pulled on their own instead (a --push
        # build, its smoke build included, takes the registry's)
        local base
        for base in $(dockerfile_bases "${dir}/Dockerfile" "IMAGE_UPLOAD_IMAGE=${upload}"); do
          if [ "$base" != "$upload" ]; then
            docker pull -q "$base" >/dev/null
          fi
        done
        extra+=(--pull=false)
      fi
    fi
    do_build "${tag}" "${dir}" 0 ${extra[@]+"${extra[@]}"} || return 1
    if [ "$smoke" = "1" ]; then
      wasm_smoke "$tag" "$lang" "$dir" || return 1
    fi
    local entry="${tag}|${dir}"
    if [ "${#push_extra[@]}" -gt 0 ]; then
      entry="${entry}|$(IFS='|'; echo "${push_extra[*]}")"
    fi
    built+=("$entry")
    echo ""
  done

  if [ "$push" = "1" ]; then
    push_built "${built[@]}" || return 1
  fi

  echo -e "${GREEN}Done.${NC}"
  if [ "$push" = "0" ]; then
    echo "To push: ci.sh wasm --push"
  fi
  return 0
}
