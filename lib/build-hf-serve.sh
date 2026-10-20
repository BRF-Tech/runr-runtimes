# cmd_build_hf_serve — RunR's serving engine of the "transformers" / "diffusers" model services
# (hf-serve/): ${REGISTRY}/hf-serve:<version> (CPU, Dockerfile, multi-arch: PLATFORMS) and
# :<version>-cuda (CUDA PyTorch + diffusers, Dockerfile.cuda, linux/amd64 only: HF_SERVE_CUDA_PLATFORM).
# <version> is __version__ of hf-serve/runr_hf_serve/__init__.py, the version the image prints.
#
#   ci.sh hf-serve                  local builds of both images, each one smoke-tested
#   ci.sh hf-serve cpu              only this one (cpu, cuda)
#   ci.sh hf-serve --no-smoke       local builds without the smoke test
#   ci.sh hf-serve --push           build + smoke test, then push: the CPU image built again for
#                                   every platform of PLATFORMS (buildx), the CUDA image pushed as
#                                   tested (`docker push` of the same image ID, as ci.sh ml-runtimes)
#   ci.sh hf-serve --list           print the image references, build nothing

HF_SERVE_CUDA_PLATFORM="${HF_SERVE_CUDA_PLATFORM:-linux/amd64}"

# hf_serve_version — __version__ of runr_hf_serve
hf_serve_version() {
  sed -n -E 's/^__version__ = "([^"]+)"$/\1/p' "${SCRIPT_DIR}/hf-serve/runr_hf_serve/__init__.py" | head -1
}

# hf_serve_images [cpu|cuda...] — "variant|Dockerfile|tag", one per image
hf_serve_images() {
  local variants=("$@") version variant
  [ "${#variants[@]}" -eq 0 ] && variants=(cpu cuda)
  version="$(hf_serve_version)"
  if [ -z "$version" ]; then
    echo -e "${RED}hf-serve: no __version__ in hf-serve/runr_hf_serve/__init__.py${NC}" >&2
    return 1
  fi
  for variant in "${variants[@]}"; do
    if [ "$variant" = cpu ]; then
      echo "cpu|Dockerfile|${version}"
    else
      echo "cuda|Dockerfile.cuda|${version}-cuda"
    fi
  done
}

cmd_build_hf_serve() {
  local list=0 variants=() arg
  build_options "ci.sh hf-serve" "$@" || return 1
  local push="$_push" smoke="$_smoke"
  for arg in ${_args[@]+"${_args[@]}"}; do
    case "$arg" in
      --list) list=1 ;;
      cpu|cuda) variants+=("$arg") ;;
      *) echo -e "${RED}unknown argument: ${arg} (cpu, cuda, --push, --list, --no-smoke)${NC}"; return 1 ;;
    esac
  done

  local images
  images="$(hf_serve_images ${variants[@]+"${variants[@]}"})" || return 1

  local variant dockerfile tag
  if [ "$list" = "1" ]; then
    while IFS='|' read -r variant dockerfile tag; do
      echo "${REGISTRY}/hf-serve:${tag}"
    done <<< "$images"
    return 0
  fi

  local dir="${SCRIPT_DIR}/hf-serve" image version id multiarch=() tested=()
  version="$(hf_serve_version)"
  echo -e "${BOLD}── hf-serve ${version} (transformers / diffusers model services) ──${NC}"
  # the list on fd 3: docker (and what wraps it) may read stdin
  while IFS='|' read -r variant dockerfile tag <&3; do
    image="${REGISTRY}/hf-serve:${tag}"
    echo "==> Building ${image}"
    if [ "$variant" = cpu ]; then
      do_build "$image" "$dir" 0 -f "${dir}/${dockerfile}" || return 1
    else
      do_build "$image" "$dir" 0 --platform "$HF_SERVE_CUDA_PLATFORM" --load -f "${dir}/${dockerfile}" || return 1
    fi
    echo "  size (docker image inspect): $(( $(docker image inspect -f '{{.Size}}' "$image") / 1000000 )) MB"
    if [ "$smoke" = "1" ]; then
      hf_serve_smoke "$image" "$version" "$variant" || return 1
    fi
    if [ "$variant" = cpu ]; then
      multiarch+=("${image}|${dir}|-f|${dir}/${dockerfile}")
    else
      id="$(docker image inspect -f '{{.Id}}' "$image")"
      tested+=("${image}|${id}")
    fi
    echo ""
  done 3<<< "$images"

  if [ "$push" = "1" ]; then
    local entry
    # the CUDA image exactly as it was tested (same image ID), checked before anything is pushed
    for entry in ${tested[@]+"${tested[@]}"}; do
      if [ "$(docker image inspect -f '{{.Id}}' "${entry%|*}" 2>/dev/null)" != "${entry##*|}" ]; then
        echo -e "${RED}${entry%|*} is no longer the image the smoke test ran (${entry##*|}): nothing pushed${NC}"
        return 1
      fi
    done
    if [ "${#multiarch[@]}" -gt 0 ]; then
      push_built "${multiarch[@]}" || return 1
    fi
    for entry in ${tested[@]+"${tested[@]}"}; do
      echo "==> Pushing ${entry%|*} (${entry##*|}, smoke-tested)"
      docker push "${entry%|*}" || return 1
    done
    echo -e "${GREEN}Done. hf-serve images built, smoke-tested and pushed.${NC}"
    return 0
  fi

  echo -e "${GREEN}Done.${NC}"
  echo "To push: ci.sh hf-serve --push"
  return 0
}
