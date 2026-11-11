# ── Multiplatform buildx ─────────────────────────────────────────────────────
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
# The docker-container builder of --push builds: created when missing, named on each build
# (--builder) and removed after the push. It never becomes the host's current builder, so other
# builds on a shared host (and the local smoke builds of ci.sh) keep theirs.
BUILDER_NAME="${BUILDER_NAME:-runr-multiarch}"

ensure_buildx() {
  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "Creating buildx builder (${BUILDER_NAME})..."
    docker buildx create --name "$BUILDER_NAME" --driver docker-container
    docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null
  fi
}

cleanup_buildx() {
  if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "Removing buildx builder (${BUILDER_NAME})..."
    docker buildx rm "$BUILDER_NAME" 2>/dev/null || true
  fi
}

# Build helper — multiplatform push or local single-platform. --pull: base images come from their
# registry, never from a copy the build host's Docker already holds (an old pull of a
# ghcr.io/brf-tech/runr/reqs tag would otherwise be built on); a caller's --pull=false, after it, wins.
# Every image carries org.opencontainers.image.source (IMAGE_SOURCE): GHCR links its package to
# this repository.
do_build() {
  local tag="$1" context="$2" push="$3"
  shift 3
  # Remaining args: extra docker build flags (e.g. --build-arg)

  if [ "$push" = "1" ]; then
    ensure_buildx
    docker buildx build \
      --builder "${BUILDER_NAME}" \
      --pull \
      --platform "${PLATFORMS}" \
      --provenance=false \
      --sbom=false \
      --label "org.opencontainers.image.source=${IMAGE_SOURCE}" \
      "$@" \
      -t "${tag}" \
      --output "type=image,push=true,oci-mediatypes=true" \
      "${context}"
  else
    docker build --pull --label "org.opencontainers.image.source=${IMAGE_SOURCE}" "$@" -t "${tag}" "${context}"
  fi
}

# build_options CMD ARG... — the flags every build command takes: --push (build and smoke-test
# every image, then push them), --no-smoke (local builds only). Sets _push and _smoke; the other
# arguments go to _args.
build_options() {
  local cmd="$1"
  shift
  _push=0
  _smoke=1
  _args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --push) _push=1 ;;
      --no-smoke) _smoke=0 ;;
      *) _args+=("$arg") ;;
    esac
  done
  if [ "$_push" = "1" ] && [ "$_smoke" = "0" ]; then
    echo -e "${RED}${cmd} --push smoke-tests every image before it is pushed: --no-smoke is for local builds${NC}"
    return 1
  fi
  return 0
}

# push_built ENTRY... — the second phase of a multi-arch --push build, once every image of the
# command was built and smoke-tested locally: each ENTRY ("tag|context|build flag|…") built for
# every platform of PLATFORMS and pushed. The smoke-tested image is the build host's platform,
# built from the same sources; buildx builds the platforms again and pushes the index.
push_built() {
  local entry tag context flags=()
  for entry in "$@"; do
    IFS='|' read -r -a flags <<< "$entry"
    tag="${flags[0]}"
    context="${flags[1]}"
    flags=("${flags[@]:2}")
    echo "==> Pushing ${tag} (${PLATFORMS}, smoke-tested)"
    do_build "$tag" "$context" 1 ${flags[@]+"${flags[@]}"} || return 1
    echo ""
  done
  cleanup_buildx
}

# discover_language_versions [RUNTIME...] — the versions of the language runtimes (all of them, or
# the ones named) that are not end-of-life, from the tags of their upstream images (runtime_versions:
# Docker Hub, or the image's own registry) and endoflife.date, without the versions the language bot
# archived (runtimes/<runtime>/archived-versions): DISCOVERED[<runtime>]="<version> <version>…" (a
# global), with a report
discover_language_versions() {
  local def runtime repo suffix min_ver depth filter product versions ver result status active_versions
  declare -gA DISCOVERED=()

  echo "Fetching available versions from the upstream images..."
  echo ""

  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime repo suffix min_ver depth filter product <<< "$def"
    if [ "$#" -gt 0 ] && [[ " $* " != *" ${runtime} "* ]]; then
      continue
    fi

    echo -e "${BOLD}── ${runtime} (${repo}, >= ${min_ver}, ${depth}${filter:+, ${filter}}) ──${NC}"
    versions=$(runtime_versions "$runtime")

    if [ -z "$versions" ]; then
      echo -e "  ${YELLOW}Warning: could not fetch versions of ${repo}, skipping.${NC}"
      echo ""
      continue
    fi

    active_versions=""
    for ver in $versions; do
      # archived by the language bot (past its end of life): never built or pushed again
      if is_archived "$runtime" "$ver"; then
        echo -e "  ${RED}✗ ${ver} (archived as ${ARCHIVE_TAG_PREFIX}${ver}: skipping build)${NC}"
        continue
      fi
      result=$(check_eol "${product:-$runtime}" "$ver")
      status="${result%%|*}"

      if [ "$status" = "eol" ]; then
        echo -e "  ${RED}✗ ${ver} (EOL — skipping build)${NC}"
      else
        echo -e "  ${GREEN}✓ ${ver}${NC}"
        active_versions="${active_versions} ${ver}"
      fi
    done

    DISCOVERED[$runtime]="$active_versions"
    echo ""
  done
}

# cmd_build — Discover + EOL check + build the language runtime images
# (exec-<runtime>:<major.minor> of the runtimes of RUNTIME_DEFS: all of them, or the ones named).
# --push publishes each one as a routine patch (lib/patch.sh): exec-<runtime>:<major.minor> and
# the immutable <full version>-r<n>, or nothing when the build is the image already published.
cmd_build() {
  build_options "ci.sh build" "$@" || return 1
  local push="$_push" smoke="$_smoke" only=() arg ids one=""
  ids="$(runtime_ids)"
  for arg in ${_args[@]+"${_args[@]}"}; do
    case "$arg" in
      --version=*) one="${arg#--version=}" ;;
      *)
        if [[ " ${ids} " == *" ${arg} "* ]]; then
          only+=("$arg")
        else
          echo -e "${RED}unknown argument: ${arg} (${ids// /, }, --version=X.Y, --push, --no-smoke)${NC}"
          return 1
        fi ;;
    esac
  done
  # --version=X.Y: that version of the one runtime named (the language bot's test build)
  if [ -n "$one" ] && { [ "${#only[@]}" != 1 ] || ! [[ "$one" =~ ^[0-9]+\.[0-9]+$ ]]; }; then
    echo -e "${RED}--version=X.Y builds one version of one runtime: ci.sh build python --version=3.16${NC}"
    return 1
  fi
  if [ "$push" = "1" ]; then
    patch_tools || return 1
  fi

  discover_language_versions ${only[@]+"${only[@]}"}

  echo "========================================="
  echo "Starting build..."
  echo "========================================="
  echo ""

  local total=0 def runtime repo suffix min_ver depth versions built=() tag version dir
  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime repo suffix min_ver depth <<< "$def"
    versions="${DISCOVERED[$runtime]:-}"
    [ -z "$versions" ] && continue
    dir="$(runtime_dir "$runtime")"

    if [ -n "$one" ]; then
      if [[ " ${versions} " != *" ${one} "* ]]; then
        echo -e "${RED}${runtime} ${one} is not a current version (${versions# }): not upstream, below the minimum, or end-of-life${NC}"
        return 1
      fi
      versions="$one"
    fi
    for version in $versions; do
      tag="${REGISTRY}/exec-${runtime}:${version}"

      # Local check: do not skip in push mode (every pushed image is smoke-tested first)
      if [ "$push" = "0" ] && docker image inspect "${tag}" >/dev/null 2>&1; then
        echo "==> Skipping ${tag} (already exists locally)"
        echo ""
        continue
      fi

      echo "==> Building ${tag}"
      SMOKE_FULL_VERSION=""
      do_build "${tag}" "${dir}" 0 --build-arg "VERSION=${version}" || return 1
      if [ "$smoke" = "1" ]; then
        runtime_smoke "$tag" "$runtime" "$version" || return 1
      fi
      # BUILD_REPORT: "runtime version full" of every image built and smoke-tested (the language bot)
      if [ -n "${BUILD_REPORT:-}" ]; then echo "${runtime} ${version} ${SMOKE_FULL_VERSION}" >> "$BUILD_REPORT"; fi
      built+=("${runtime}|${version}|${SMOKE_FULL_VERSION}|${dir}|--build-arg|VERSION=${version}")
      total=$((total + 1))
      echo ""
    done
  done

  if [ "$push" = "1" ] && [ "${#built[@]}" -gt 0 ]; then
    # a routine patch: its reason comes from what changed (patch_publish_image)
    patch_request_reset routine
    patch_push_images 1 "${built[@]}" || return 1
  fi

  echo "========================================="
  if [ "$push" = "1" ]; then
    echo "Done. ${total} images built and smoke-tested: ${PATCH_PUBLISHED:-0} new patches pushed, ${PATCH_UNCHANGED:-0} unchanged, ${PATCH_HELD:-0} held for the language bot."
    echo "The patch feed lists them after its next update (ci.sh feed update --push)."
  else
    echo "Done. ${total} images built."
    echo "To push: ci.sh build --push"
  fi
  return 0
}

# wrapper_version — the version the wrapper binary prints (const version of wrapper/main.go): the
# tag of ghcr.io/brf-tech/runr/wrapper
wrapper_version() {
  sed -n -E 's/^const version = "([^"]+)"$/\1/p' "${SCRIPT_DIR}/wrapper/main.go" | head -1
}

# cmd_build_wrapper — Build the universal runtime wrapper image (runr-wrapper, FROM scratch)
cmd_build_wrapper() {
  build_options "ci.sh wrapper" "$@" || return 1
  if [ "${#_args[@]}" -gt 0 ]; then
    echo -e "${RED}unknown argument: ${_args[0]} (--push, --no-smoke)${NC}"
    return 1
  fi
  local push="$_push" smoke="$_smoke"

  local dir="${SCRIPT_DIR}/wrapper" version
  version="${WRAPPER_VERSION:-$(wrapper_version)}"
  local tag="${REGISTRY}/wrapper:${version}"

  if [ ! -d "$dir" ] || [ -z "$version" ]; then
    echo -e "${RED}wrapper directory or version (const version of wrapper/main.go) not found: ${dir}${NC}"
    return 1
  fi

  echo -e "${BOLD}── runr-wrapper (universal runtime wrapper, exec / persistent / http) ──${NC}"

  echo "==> Building ${tag}"
  do_build "${tag}" "${dir}" 0 || return 1
  if [ "$smoke" = "1" ]; then
    wrapper_smoke "$tag" "$version" || return 1
  fi
  echo ""

  if [ "$push" = "1" ]; then
    push_built "${tag}|${dir}" || return 1
  fi

  echo -e "${GREEN}Done.${NC}"
  if [ "$push" = "0" ]; then
    echo "To push: ci.sh wrapper --push"
  fi
  return 0
}
