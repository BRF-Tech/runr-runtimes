# cmd_mirror_reqs  — Mirror upstream images to $REGISTRY/reqs/ as multi-arch
# cmd_mirror_bases — Mirror runtime base images (dynamic version discovery)
#
# Copies the upstream manifest list as is, using crane copy.
# Downloads no layers (registry-to-registry), only manifest + blob redirect.
# Requires: crane (go-containerregistry)
#
# A source that names its registry (ghcr.io/…, quay.io/…: registry_qualified of lib/common.sh) is
# copied from that registry directly — no Docker Hub, no mirror of it. Any copy refused with DENIED
# is made once more after REQS_RETRY_PAUSE (_crane_copy_retry), before the next upstream.
#
# Upstreams of a Docker Hub source (REQS_UPSTREAMS, tried in order): Docker Hub, then pull-through
# mirrors of it that serve its repositories under their own prefix — mirror.gcr.io/library/alpine,
# public.ecr.aws/docker/library/alpine (official images only). When Docker Hub refuses a copy
# (its anonymous pull limit: 429 TOOMANYREQUESTS), the image is copied from the first mirror that
# has Docker Hub's digest of it, by that digest: `crane digest docker.io/…` is a HEAD request,
# which the pull limit does not count, and a copy by digest is the same image or no copy at all.
#
#   REQS_UPSTREAMS="mirror.gcr.io public.ecr.aws/docker" ci.sh mirror-reqs   no Docker Hub pulls
REQS_UPSTREAMS="${REQS_UPSTREAMS:-docker.io mirror.gcr.io public.ecr.aws/docker}"

# A copy that fails with DENIED — from Docker Hub, a mirror of it or a source's own registry — is
# made once more after this many seconds: GHCR can refuse some of crane's parallel uploads to a
# package that the first push is still creating
REQS_RETRY_PAUSE="${REQS_RETRY_PAUSE:-10}"

# target|source — target = $REGISTRY/reqs/{target}, source = a Docker Hub repository with its tag
# (library/ implied for official images), or tag@digest for an image pinned by digest, or a
# reference with its registry (ghcr.io/org/name:tag, quay.io/org/name:tag) for an image Docker Hub
# does not carry
#
# Every $REGISTRY/reqs/ image RunR references — the product, its Helm chart, Compose files, CI and
# e2e in BRF-Tech/runr, and the files of this repository — is either here or a runtime base image
# of cmd_mirror_bases (RUNTIME_DEFS). This repository's ci/check-reqs-mirror.sh checks its own
# references against the two lists; BRF-Tech/runr's checks that each of its references resolves
# anonymously, so an image it starts to use is added here (and mirrored) first. The mirror
# workflow (.github/workflows/mirror.yml) runs mirror-reqs and mirror-bases weekly and on demand.
REQS_IMAGES=(
  # ── Utility (Knative pods, init containers, sidecars, CaaS test image) ──
  "alpine:3.20|alpine:3.20"
  "alpine:3.21|alpine:3.21"
  "redis:7-alpine|redis:7-alpine"
  "caddy:2-alpine|caddy:2-alpine"
  "curl:latest|curlimages/curl:latest"
  "busybox:latest|busybox:latest"
  "nginx:1.27-alpine|nginx:1.27-alpine"

  # ── Region ingress: the image of the pinned Traefik chart (KnativeConstants::TRAEFIK_IMAGE), and
  #    the one before it, which regions run until region:reconcile moves them ──
  "traefik:v3.7.17|traefik:v3.7.17"
  "traefik:v3.7.4|traefik:v3.7.4"

  # ── Region tracing backend: the images of the pinned collector and Tempo charts
  #    (ManagedTracing::COLLECTOR_IMAGE / TEMPO_IMAGE) ──
  "opentelemetry-collector-contrib:0.162.0|otel/opentelemetry-collector-contrib:0.162.0"
  "tempo:3.1.0|grafana/tempo:3.1.0"

  # ── Bindings data services (docs/bindings.md) ──
  "garage:v2.1.0|dxflrs/garage:v2.1.0"
  "rclone:1.68.2|rclone/rclone:1.68.2"

  # ── Example runtimes (examples/runtimes) ──
  "bash:5.2|bash:5.2"
  "rust:1.83-alpine|rust:1.83-alpine"

  # ── Compose stacks (docker-compose.yml, compose/), Helm chart ──
  "postgres:17-alpine|postgres:17-alpine"
  "mailpit:latest|axllent/mailpit:latest"

  # ── Dockerfile base images ──
  "frankenphp:1-php8.3-alpine|dunglas/frankenphp:1-php8.3-alpine"
  "composer:latest|composer:latest"
  "composer:2.7|composer:2.7"
  "php:8.3-fpm-alpine|php:8.3-fpm-alpine"
  "node:20-alpine|node:20-alpine"
  "node:22-alpine|node:22-alpine"
  "golang:1.26-alpine|golang:1.26-alpine"
  "golang:1.27-alpine|golang:1.27-alpine"

  # ── WebAssembly build images (runtimes/wasm-*) and the Spin shim's Rust toolchain
  #    (runtime/wasm-shim-spin of BRF-Tech/runr, pinned by digest) ──
  "tinygo:0.44.0|tinygo/tinygo:0.44.0"
  "node:22-bookworm-slim|node:22-bookworm-slim"
  "python:3.13-slim-bookworm|python:3.13-slim-bookworm"
  "rust:1.99.1-slim-bookworm|rust:1.99.1-slim-bookworm"
  "rust:1.95.0-slim-bookworm|rust:1.95.0-slim-bookworm@sha256:d7482085ff5b415f84dba5647ae71606650bdef00db7aeb69f4b3d170c3e4082"
  "rust:1.97.0-slim-bookworm|rust:1.97.0-slim-bookworm@sha256:6d220bf85c74e842a79da63997af8d2e74455c0b8847d8bb3a5888572334991d"

  # ── CUDA base of hf-serve's GPU image (the pytorch / tensorflow GPU runtimes take NVIDIA's pip wheels) ──
  "pytorch:2.14.1-cuda12.6-cudnn9-runtime|pytorch/pytorch:2.14.1-cuda12.6-cudnn9-runtime"

  # ── FaaS kaniko build base images ──
  "python:3.12-slim|python:3.12-slim"
  "node:22-slim|node:22-slim"
  # the mcp-node runtime template of RunR 0.7.0 (every platform: the tag had linux/amd64 only)
  "node:24-slim|node:24-slim"

  # ── CI images ──
  "docker:27|docker:27"
  "docker:27-dind|docker:27-dind"
  "php:8.2-cli-alpine|php:8.2-cli-alpine"
  "helm:3.15|alpine/helm:3.15"
  "binfmt:latest|tonistiigi/binfmt:latest"

  # ── Load tests: the k6 runner (LoadTestManifests::IMAGE, docs/load-test.md) ──
  "k6:1.8.2|grafana/k6:1.8.2"

  # ── Secret stores: External Secrets Operator in the region and the OpenBao RunR runs there
  #    (config/secrets.php, docs/secret-stores.md) ──
  "external-secrets:v0.19.2|ghcr.io/external-secrets/external-secrets:v0.19.2"
  "openbao:2.4.1|openbao/openbao:2.4.1"

  # ── Global projects: the PowerDNS Authoritative server of a region's global DNS
  #    (config/global_dns.php, docs/global-projects.md) ──
  "pdns-auth:5.0.8|powerdns/pdns-auth-50:5.0.8"

  # ── Custom domains: the cert-manager a region installs where its cluster runs none
  #    (CertManager, docs/regions.md#cert-manager) ──
  "cert-manager-controller:v1.21.2|quay.io/jetstack/cert-manager-controller:v1.21.2"
  "cert-manager-webhook:v1.21.2|quay.io/jetstack/cert-manager-webhook:v1.21.2"
  "cert-manager-cainjector:v1.21.2|quay.io/jetstack/cert-manager-cainjector:v1.21.2"
  "cert-manager-acmesolver:v1.21.2|quay.io/jetstack/cert-manager-acmesolver:v1.21.2"

  # ── Test: the Kind node image of the e2e runs, by the digest of the Kind release that built it
  #    (v0.33.0, the pin of BRF-Tech/runr's kind-suite.yml): RunR's CI runs the newest Kubernetes
  #    only (from RunR 0.7.0). The older node images (v1.32.0, v1.34.3, v1.35.0) stay in the
  #    registry for RunR 0.6.x's CI; they are no longer copied again ──
  "kindest-node:v1.37.0|kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"

  # ── e2e trigger-sources suite: the brokers of the event sources — Kafka, NATS, RabbitMQ, MQTT
  #    and email (E2eTestTriggerSourcesTrait, runtime/lib/test-trigger-sources.sh) ──
  "kafka:3.9.1|apache/kafka:3.9.1"
  "nats:2.11-alpine|nats:2.11-alpine"
  "rabbitmq:4.1-management-alpine|rabbitmq:4.1-management-alpine"
  "eclipse-mosquitto:2.0.20|eclipse-mosquitto:2.0.20"
  "greenmail:2.1.3|greenmail/standalone:2.1.3"

  # ── e2e git-deploy suite: the throwaway Forgejo the suite pushes to (FORGEJO_IMAGE of
  #    runtime/lib/test-git-deploy.sh in BRF-Tech/runr). From Forgejo's own registry, by the digest
  #    codeberg.org/forgejo/forgejo:9.0.3 has too: Codeberg's registry refuses anonymous pulls while
  #    it is under load ──
  "forgejo:9.0.3|data.forgejo.org/forgejo/forgejo:9.0.3@sha256:3c34f11fe8b9983096eef3f8f25c2d2c21c4ae7504960cb203f0b075d1d8ed73"

  # ── CI tools of BRF-Tech/runr's scripts: pandoc of ci/build-runr-sh.sh (the runr.sh site), and
  #    the Caddy, curl, Alpine and Terraform of ci/runr-sh/verify.sh (its python:3.12-slim is above),
  #    by the digests Docker Hub and mirror.gcr.io list (public.ecr.aws too for caddy, alpine and
  #    terraform) ──
  "pandoc:3.6.4|pandoc/core:3.6.4@sha256:5b8a29d9b70d5d8ca766e5d1dcfc41916b23ab79276a80527be70516110f4c1e"
  "caddy:2.11.4|caddy:2.11.4@sha256:0c994536bddb66445885237f1a5dcc1916bccea922661c76b4e9fc24061f9b52"
  "curl:8.11.1|curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69"
  "alpine:3.22|alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
  "terraform:1.16.5|hashicorp/terraform:1.16.5@sha256:c7926feace05d0f7e73542842bf3945924e955a1f782cf000ccbb8d18fa42d77"
)

_require_crane() {
  if ! command -v crane &>/dev/null; then
    echo -e "${RED}crane not found. Install:${NC}"
    echo '  curl -fsSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz" | sudo tar xz -C /usr/local/bin crane'
    exit 1
  fi
}

# _crane_copy SOURCE TARGET DRY_RUN — SOURCE (a REQS_IMAGES source) from the first upstream of
# REQS_UPSTREAMS that has it; from a mirror only by Docker Hub's digest. A source with its registry
# (registry_qualified) from that registry only. Every copy is made once more when it is refused
# with DENIED (_crane_copy_retry: the first push to a new package).
_crane_copy() {
  local source="$1" target="$2" dry_run="$3" path upstream want="" out note=""
  if registry_qualified "$source"; then
    if [ "$dry_run" = "1" ]; then
      echo "  [dry-run] ${source} → ${target}"
      return 0
    fi
    echo -n "  ${source} → ${target} ... "
    if out=$(_crane_copy_retry "$source" "$target"); then
      echo -e "${GREEN}ok${NC}${out:+ on the second copy, the first:${out}}"
      return 0
    fi
    echo -e "${RED}fail${NC} ${source%%/*}:${out}"
    return 1
  fi

  path="$(dockerhub_path "$source")"
  if [ "$dry_run" = "1" ]; then
    echo "  [dry-run] docker.io/${path} → ${target}"
    return 0
  fi
  echo -n "  docker.io/${path} → ${target} ... "

  for upstream in $REQS_UPSTREAMS; do
    if [ "$upstream" = "docker.io" ]; then
      if out=$(_crane_copy_retry "docker.io/${path}" "${target}"); then
        echo -e "${GREEN}ok${NC}${note}${out:+ on the second copy, the first:${out}}"
        return 0
      fi
      note="${note} docker.io:${out}"
      continue
    fi

    if [ -z "$want" ] && ! want=$(dockerhub_digest "$path"); then
      echo -e "${RED}fail${NC}${note} no Docker Hub digest to check ${upstream} against"
      return 1
    fi
    if out=$(_crane_copy_retry "${upstream}/${path%%[:@]*}@${want}" "${target}"); then
      if [ "$(crane digest "${target}" 2>/dev/null)" = "$want" ]; then
        echo -e "${GREEN}ok${NC}${note} from ${upstream}, Docker Hub's digest ${want}${out:+ on the second copy, the first:${out}}"
        return 0
      fi
      out=" ${target} is not at ${want} after the copy;"
    fi
    note="${note} ${upstream}:${out}"
  done

  echo -e "${RED}fail${NC}${note}"
  return 1
}

# _crane_copy_retry SOURCE TARGET — crane copy SOURCE TARGET; when it is refused with DENIED, once
# more after REQS_RETRY_PAUSE seconds (GHCR can refuse part of the first push to a package it is
# still creating). Prints the answers for the report: nothing when the first copy worked,
# " <first answer>;" when the second did; " <answer>;" or " <first>; again after <n>s: <second>;"
# with status 1 when no copy worked.
_crane_copy_retry() {
  local err first
  if err=$(crane copy "$1" "$2" 2>&1); then
    return 0
  fi
  first="$(_crane_error "$err")"
  if [[ "$first" != DENIED:* ]]; then
    echo " ${first};"
    return 1
  fi
  sleep "$REQS_RETRY_PAUSE"
  if err=$(crane copy "$1" "$2" 2>&1); then
    echo " ${first};"
    return 0
  fi
  echo " ${first}; again after ${REQS_RETRY_PAUSE}s: $(_crane_error "$err");"
  return 1
}

# the last line of crane's error output: the registry's error code and message when it has one
# (TOOMANYREQUESTS: …, NAME_UNKNOWN: …), else the line without its log prefix
_crane_error() {
  local line
  line=$(printf '%s\n' "$1" | tail -n 1 | sed 's/^Error: //')
  if [[ "$line" =~ ([A-Z][A-Z_]{4,}:.*)$ ]]; then
    line="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "${line:0:200}"
}

# cmd_mirror_reqs [--dry-run] [IMAGE...] — every REQS_IMAGES entry, or the ones named (target
# image:tag or image name)
cmd_mirror_reqs() {
  local dry_run=0 only=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      -*) echo -e "${RED}unknown argument: ${arg} (--dry-run, image names)${NC}"; exit 1 ;;
      *) only+=("$arg") ;;
    esac
  done

  _require_crane

  echo -e "${BOLD}Upstream → ${REGISTRY}/reqs/ multi-arch mirror${NC} (upstreams: ${REQS_UPSTREAMS})"
  echo ""

  local ok=0 fail=0 entry target source name
  for entry in "${REQS_IMAGES[@]}"; do
    IFS='|' read -r target source <<< "$entry"
    if [ "${#only[@]}" -gt 0 ]; then
      local wanted=0
      for name in "${only[@]}"; do
        if [ "$name" = "$target" ] || [ "$name" = "${target%%:*}" ]; then
          wanted=1
        fi
      done
      [ "$wanted" = "1" ] || continue
    fi
    if _crane_copy "$source" "${REGISTRY}/reqs/${target}" "$dry_run"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done

  echo ""
  if [ "$fail" = "0" ]; then
    echo -e "${GREEN}Done. ${ok} images mirrored.${NC}"
  else
    echo -e "${RED}Done. ${ok} ok, ${fail} failed.${NC}"
    return 1
  fi
}

# Runtime base images — discover versions dynamically, then mirror: for every version of every
# language runtime (runtime_versions of lib/common.sh), its base images (runtime_base_images: the
# image its Dockerfile builds on, for .NET also the runtime-deps image its functions run on)
cmd_mirror_bases() {
  local dry_run=0
  for arg in "$@"; do
    case "$arg" in --dry-run) dry_run=1 ;; esac
  done

  _require_crane

  echo -e "${BOLD}Runtime base images → ${REGISTRY}/reqs/ multi-arch mirror${NC} (upstreams: ${REQS_UPSTREAMS})"
  echo ""

  local ok=0 fail=0 def runtime repo suffix versions ver pair target source

  for def in "${RUNTIME_DEFS[@]}"; do
    IFS='|' read -r runtime repo suffix _ <<< "$def"

    echo -e "${BOLD}── ${runtime} (${repo}:*${suffix}) ──${NC}"
    versions=$(runtime_versions "$runtime")

    for ver in $versions; do
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        target="${pair%%|*}"
        source="${pair#*|}"
        if _crane_copy "$source" "${REGISTRY}/reqs/${target}" "$dry_run"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
        fi
      done < <(runtime_base_images "$runtime" "$ver")
    done
    echo ""
  done

  if [ "$fail" = "0" ]; then
    echo -e "${GREEN}Done. ${ok} base images mirrored.${NC}"
  else
    echo -e "${RED}Done. ${ok} ok, ${fail} failed.${NC}"
    return 1
  fi
}
