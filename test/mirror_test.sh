#!/usr/bin/env bash
# Tests `ci.sh mirror-reqs` without a registry: crane is a shell function that answers like Docker
# Hub (digests by HEAD, copies refused with 429 TOOMANYREQUESTS for the images listed in $limited)
# and like the pull-through mirrors of REQS_UPSTREAMS (each holds what $tmp/mirrors lists), and
# records what lands in the target registry. A mirror's copy is taken only by Docker Hub's digest.
# ghcr.io and quay.io hold what $tmp/others lists: a source with its registry is copied from there,
# and the target refuses the copies $tmp/denied lists with DENIED (GHCR creating a new package).
#
#   bash test/mirror_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/mirror.sh
source "$here/lib/mirror.sh"
repository_images=("${REQS_IMAGES[@]}")

REGISTRY="registry.test/brf-tech"
log="$tmp/crane.log"
hub="$tmp/hub"            # <docker hub path> <digest>
limited="$tmp/limited"    # Docker Hub paths whose copy answers 429
mirrors="$tmp/mirrors"    # <mirror>/<repository>@<digest> a mirror holds
registry="$tmp/registry"  # <target ref> <digest> of every copy
others="$tmp/others"      # <ghcr.io / quay.io reference> <digest> those registries hold
denied="$tmp/denied"      # <target ref> <n>: the target refuses the next n copies to it (DENIED)
hub_down=0

# the pause before a retry: recorded, not waited for
sleep() { echo "sleep $*" >> "$log"; }

cat > "$hub" <<'EOF'
library/alpine:3.21 sha256:a1
tonistiigi/binfmt:latest sha256:b1
library/node:22-bookworm-slim sha256:c1
grafana/tempo:3.1.0 sha256:d1
EOF

crane() {
  echo "crane $*" >> "$log"
  local ref path digest
  case "$1" in
    digest)
      ref="$2"
      case "$ref" in
        docker.io/*)
          [ "$hub_down" = "0" ] || { echo "Error: HEAD https://index.docker.io/v2/: 503 Service Unavailable" >&2; return 1; }
          path="${ref#docker.io/}"
          awk -v p="$path" '$1 == p { print $2; found = 1 } END { exit !found }' "$hub" ;;
        *)
          awk -v r="$ref" '$1 == r { d = $2 } END { if (d == "") exit 1; print d }' "$registry" ;;
      esac ;;
    copy)
      ref="$2"
      case "$ref" in
        docker.io/*)
          path="${ref#docker.io/}"
          if grep -qxF "$path" "$limited"; then
            echo "Error: GET https://index.docker.io/v2/${path%%:*}/manifests/${path#*:}: TOOMANYREQUESTS: You have reached your unauthenticated pull rate limit." >&2
            return 1
          fi
          digest=$(awk -v p="${path%@*}" '$1 == p { print $2 }' "$hub")
          [ -n "$digest" ] || digest="${path##*@}"
          echo "$3 ${digest}" >> "$registry" ;;
        ghcr.io/*|quay.io/*)
          digest=$(awk -v r="$ref" '$1 == r { print $2 }' "$others")
          if [ -z "$digest" ]; then
            echo "Error: fetching \"${ref}\": GET https://${ref%%/*}/v2/${ref#*/}: MANIFEST_UNKNOWN: manifest unknown; unknown tag=${ref##*:}" >&2
            return 1
          fi
          # GHCR creating a new package: crane's form of a refused upload to the target
          if awk -v t="$3" '$1 == t && $2 > 0 { found = 1 } END { exit !found }' "$denied"; then
            awk -v t="$3" '$1 == t { $2 = $2 - 1 } { print }' "$denied" > "$denied.new" && mv "$denied.new" "$denied"
            echo "Error: PUT https://${3%%/*}/v2/${3#*/}/blobs/uploads/: DENIED: requested access to the resource is denied" >&2
            return 1
          fi
          echo "$3 ${digest}" >> "$registry" ;;
        *@sha256:*)
          if ! grep -qxF "$ref" "$mirrors"; then
            # crane's form: the reference, the request, then the registry's code and message
            echo "Error: fetching \"${ref}\": GET https://${ref%%/*}/v2/${ref#*/}/manifests/${ref##*@}: MANIFEST_UNKNOWN: manifest unknown; unknown tag=${ref##*@}" >&2
            return 1
          fi
          echo "$3 ${ref##*@}" >> "$registry" ;;
        *) echo "Error: copied by tag from a mirror: $ref" >&2; return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

REQS_IMAGES=(
  "alpine:3.21|alpine:3.21"
  "binfmt:latest|tonistiigi/binfmt:latest"
  "node:22-bookworm-slim|node:22-bookworm-slim"
  "rust:1.95.0-slim-bookworm|rust:1.95.0-slim-bookworm@sha256:e1"
  "external-secrets:v0.19.2|ghcr.io/external-secrets/external-secrets:v0.19.2"
  "cert-manager-webhook:v1.21.2|quay.io/jetstack/cert-manager-webhook:v1.21.2"
)

# reset LIMITED MIRRORS — Docker Hub paths that answer 429, what the mirrors hold (ghcr.io and
# quay.io hold the two images of the list)
reset() {
  : > "$log"
  : > "$registry"
  tr ' ' '\n' <<< "$1" > "$limited"
  tr ' ' '\n' <<< "$2" > "$mirrors"
  printf '%s\n' "ghcr.io/external-secrets/external-secrets:v0.19.2 sha256:f1" \
    "quay.io/jetstack/cert-manager-webhook:v1.21.2 sha256:f2" > "$others"
  : > "$denied"
  hub_down=0
}

copied() { awk -v r="${REGISTRY}/reqs/$1" '$1 == r { print $2 }' "$registry"; }

# --- Docker Hub answers: everything from docker.io, no mirror asked ---------------------------
reset "" ""
cmd_mirror_reqs > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "mirror-reqs failed with Docker Hub answering"; }
[ "$(copied alpine:3.21)" = "sha256:a1" ] || fail "alpine:3.21 not copied from Docker Hub"
[ "$(copied rust:1.95.0-slim-bookworm)" = "sha256:e1" ] || fail "the digest-pinned rust not copied at its digest"
[ "$(copied external-secrets:v0.19.2)" = "sha256:f1" ] || fail "external-secrets not copied from ghcr.io"
[ "$(copied cert-manager-webhook:v1.21.2)" = "sha256:f2" ] || fail "cert-manager-webhook not copied from quay.io"
grep -q 'mirror.gcr.io\|public.ecr.aws' "$log" && fail "a mirror was asked although Docker Hub answered"
grep -q '^crane digest docker.io' "$log" && fail "Docker Hub's digest was read although Docker Hub answered"
echo "ok - Docker Hub answering: every image from docker.io"

# --- Docker Hub's pull limit: the mirrors, by Docker Hub's digest -----------------------------
reset "library/alpine:3.21 tonistiigi/binfmt:latest library/node:22-bookworm-slim library/rust:1.95.0-slim-bookworm@sha256:e1" \
      "mirror.gcr.io/library/alpine@sha256:a1 mirror.gcr.io/tonistiigi/binfmt@sha256:b1 public.ecr.aws/docker/library/node@sha256:c1 public.ecr.aws/docker/library/rust@sha256:e1"
cmd_mirror_reqs > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "mirror-reqs failed although the mirrors have every image"; }
[ "$(copied alpine:3.21)" = "sha256:a1" ] || fail "alpine:3.21 not copied from mirror.gcr.io"
[ "$(copied binfmt:latest)" = "sha256:b1" ] || fail "binfmt:latest not copied from mirror.gcr.io"
[ "$(copied node:22-bookworm-slim)" = "sha256:c1" ] || fail "node not copied from public.ecr.aws (mirror.gcr.io lacks it)"
[ "$(copied rust:1.95.0-slim-bookworm)" = "sha256:e1" ] || fail "the digest-pinned rust not copied from a mirror"
[ "$(copied external-secrets:v0.19.2)" = "sha256:f1" ] || fail "external-secrets not copied from ghcr.io during Docker Hub's pull limit"
grep -qE '(mirror\.gcr\.io|public\.ecr\.aws/docker|docker\.io)/(ghcr|quay)\.io' "$log" \
  && fail "a source with its registry went to Docker Hub or a mirror: $(cat "$log")"
grep -qxF 'crane copy mirror.gcr.io/library/alpine@sha256:a1 registry.test/brf-tech/reqs/alpine:3.21' "$log" \
  || fail "alpine:3.21 not copied by Docker Hub's digest"
grep -qF 'crane digest docker.io/library/rust' "$log" && fail "the digest of a pinned image was read from Docker Hub"
grep -qF 'TOOMANYREQUESTS' "$tmp/out" || fail "Docker Hub's refusal is not reported"
grep -qF "from mirror.gcr.io, Docker Hub's digest sha256:a1" "$tmp/out" || fail "the mirror copy is not reported"
echo "ok - Docker Hub's pull limit: the images from mirror.gcr.io / public.ecr.aws by Docker Hub's digest"

# --- a mirror with another image under the tag: never copied ------------------------------------
reset "library/alpine:3.21" "mirror.gcr.io/library/alpine@sha256:old public.ecr.aws/docker/library/alpine@sha256:old"
status=0
cmd_mirror_reqs alpine:3.21 > "$tmp/out" 2>&1 || status=$?
[ "$status" = "1" ] || { cat "$tmp/out"; fail "mirror-reqs did not fail when no mirror has Docker Hub's digest"; }
[ -z "$(copied alpine:3.21)" ] || fail "alpine:3.21 copied without Docker Hub's digest"
grep -qF 'mirror.gcr.io: MANIFEST_UNKNOWN: manifest unknown' "$tmp/out" || fail "the mirrors' answers are not reported: $(cat "$tmp/out")"
echo "ok - a mirror without Docker Hub's digest is not copied, mirror-reqs exits 1"

# --- Docker Hub down (no digest to check against): no mirror copy ------------------------------
reset "library/alpine:3.21" "mirror.gcr.io/library/alpine@sha256:a1"
hub_down=1
status=0
cmd_mirror_reqs alpine:3.21 > "$tmp/out" 2>&1 || status=$?
[ "$status" = "1" ] || fail "mirror-reqs copied from a mirror without Docker Hub's digest"
grep -q '^crane copy mirror' "$log" && fail "a mirror was copied without Docker Hub's digest"
grep -qF 'no Docker Hub digest' "$tmp/out" || fail "the missing digest is not reported"
echo "ok - without Docker Hub's digest nothing is copied from a mirror"

# --- REQS_UPSTREAMS without Docker Hub, a selection of images, a dry run -------------------------
reset "" "mirror.gcr.io/library/alpine@sha256:a1 mirror.gcr.io/tonistiigi/binfmt@sha256:b1"
REQS_UPSTREAMS="mirror.gcr.io" cmd_mirror_reqs alpine:3.21 binfmt > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "mirror-reqs from mirror.gcr.io failed"; }
grep -q '^crane copy docker.io' "$log" && fail "Docker Hub was pulled although REQS_UPSTREAMS leaves it out"
if [ "$(copied alpine:3.21)" != "sha256:a1" ] || [ "$(copied binfmt:latest)" != "sha256:b1" ]; then
  fail "the two images selected were not copied"
fi
[ "$(wc -l < "$registry")" = "2" ] || fail "more than the two images selected were copied"
reset "" ""
cmd_mirror_reqs --dry-run > "$tmp/out" 2>&1
[ ! -s "$log" ] || fail "the dry run called crane: $(cat "$log")"
grep -qF '[dry-run] docker.io/library/rust:1.95.0-slim-bookworm@sha256:e1 → registry.test/brf-tech/reqs/rust:1.95.0-slim-bookworm' "$tmp/out" \
  || fail "the dry run does not list the Docker Hub source"
grep -qF '[dry-run] quay.io/jetstack/cert-manager-webhook:v1.21.2 → registry.test/brf-tech/reqs/cert-manager-webhook:v1.21.2' "$tmp/out" \
  || fail "the dry run does not list the source with its registry as is: $(cat "$tmp/out")"
echo "ok - REQS_UPSTREAMS, image selection and --dry-run"

# --- a source with its registry: copied from that registry, never via Docker Hub or a mirror ------
reset "" ""
REQS_UPSTREAMS="mirror.gcr.io" cmd_mirror_reqs external-secrets cert-manager-webhook:v1.21.2 > "$tmp/out" 2>&1 \
  || { cat "$tmp/out"; fail "mirror-reqs of the ghcr.io / quay.io sources failed"; }
want="crane copy ghcr.io/external-secrets/external-secrets:v0.19.2 registry.test/brf-tech/reqs/external-secrets:v0.19.2
crane copy quay.io/jetstack/cert-manager-webhook:v1.21.2 registry.test/brf-tech/reqs/cert-manager-webhook:v1.21.2"
[ "$(cat "$log")" = "$want" ] || fail "the sources with their registry were not copied from it alone, by tag: $(cat "$log")"
grep -qF 'ghcr.io/external-secrets/external-secrets:v0.19.2 → registry.test/brf-tech/reqs/external-secrets:v0.19.2 ... ' "$tmp/out" \
  || fail "the copy from ghcr.io is not reported: $(cat "$tmp/out")"
# the registry lacks the tag: mirror-reqs fails with its answer, nothing else is asked
reset "" "mirror.gcr.io/jetstack/cert-manager-webhook@sha256:f2"
: > "$others"
status=0
cmd_mirror_reqs cert-manager-webhook > "$tmp/out" 2>&1 || status=$?
[ "$status" = "1" ] || { cat "$tmp/out"; fail "mirror-reqs did not fail when quay.io lacks the tag"; }
[ "$(cat "$log")" = "crane copy quay.io/jetstack/cert-manager-webhook:v1.21.2 registry.test/brf-tech/reqs/cert-manager-webhook:v1.21.2" ] \
  || fail "a failed copy from quay.io fell back to Docker Hub or a mirror: $(cat "$log")"
grep -qF 'quay.io: MANIFEST_UNKNOWN: manifest unknown' "$tmp/out" || fail "quay.io's answer is not reported: $(cat "$tmp/out")"
[ -z "$(copied cert-manager-webhook:v1.21.2)" ] || fail "cert-manager-webhook copied although quay.io lacks it"
echo "ok - a source with its registry: copied from that registry only, its refusal reported"

# --- a direct copy refused with DENIED (a new package's first push): once more after the pause ---
copy_es="crane copy ghcr.io/external-secrets/external-secrets:v0.19.2 registry.test/brf-tech/reqs/external-secrets:v0.19.2"
reset "" ""
echo "registry.test/brf-tech/reqs/external-secrets:v0.19.2 1" > "$denied"
cmd_mirror_reqs external-secrets > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "mirror-reqs failed although the second copy is accepted"; }
[ "$(cat "$log")" = "$(printf '%s\n' "$copy_es" "sleep 10" "$copy_es")" ] \
  || fail "the copy refused with DENIED was not tried once more after the default pause: $(cat "$log")"
[ "$(copied external-secrets:v0.19.2)" = "sha256:f1" ] || fail "external-secrets not copied by the second copy"
grep -qF 'on the second copy, the first: DENIED: requested access to the resource is denied;' "$tmp/out" \
  || fail "the retry is not reported: $(cat "$tmp/out")"
# refused again: one retry only, then the failure with both answers
reset "" ""
echo "registry.test/brf-tech/reqs/external-secrets:v0.19.2 5" > "$denied"
status=0
REQS_RETRY_PAUSE=3 cmd_mirror_reqs external-secrets > "$tmp/out" 2>&1 || status=$?
[ "$status" = "1" ] || { cat "$tmp/out"; fail "mirror-reqs did not fail when the target refuses every copy"; }
[ "$(cat "$log")" = "$(printf '%s\n' "$copy_es" "sleep 3" "$copy_es")" ] \
  || fail "not exactly one retry after REQS_RETRY_PAUSE: $(cat "$log")"
grep -qF 'ghcr.io: DENIED: requested access to the resource is denied; again after 3s: DENIED: requested access to the resource is denied;' "$tmp/out" \
  || fail "the two refusals are not reported: $(cat "$tmp/out")"
[ -z "$(copied external-secrets:v0.19.2)" ] || fail "external-secrets copied although every copy was refused"
echo "ok - a direct copy refused with DENIED: one retry after REQS_RETRY_PAUSE, other errors none"

# --- registry_qualified; the Docker Hub helpers skip a source with its registry --------------------
for ref in ghcr.io/external-secrets/external-secrets:v0.19.2 quay.io/jetstack/cert-manager-controller:v1.21.2 \
  registry.local:5000/team/app:1 localhost/app:1 public.ecr.aws/docker/library/alpine:3.21; do
  registry_qualified "$ref" || fail "registry_qualified: ${ref} names its registry"
done
for ref in alpine:3.21 grafana/k6:1.8.2 library/alpine:3.21 powerdns/pdns-auth-50:5.0.8 \
  rust:1.95.0-slim-bookworm@sha256:e1 localhost:5000; do
  registry_qualified "$ref" && fail "registry_qualified: ${ref} is a Docker Hub reference"
done
reset "" ""
dockerhub_path quay.io/jetstack/cert-manager-webhook:v1.21.2 > "$tmp/out" && fail "dockerhub_path took a quay.io reference for Docker Hub's"
[ ! -s "$tmp/out" ] || fail "dockerhub_path printed a Docker Hub path for a quay.io reference: $(cat "$tmp/out")"
dockerhub_digest ghcr.io/external-secrets/external-secrets:v0.19.2 > "$tmp/out" && fail "dockerhub_digest answered for a ghcr.io reference"
[ ! -s "$log" ] || fail "dockerhub_digest asked a registry for a ghcr.io reference: $(cat "$log")"
[ "$(dockerhub_path grafana/k6:1.8.2)" = "grafana/k6:1.8.2" ] || fail "dockerhub_path of grafana/k6:1.8.2"
[ "$(dockerhub_path alpine:3.21)" = "library/alpine:3.21" ] || fail "dockerhub_path of alpine:3.21"
echo "ok - registry_qualified; dockerhub_path and dockerhub_digest skip a source with its registry"

# --- the repository's list: every source a Docker Hub path or a reference with its registry ------
for entry in "${repository_images[@]}"; do
  source="${entry#*|}"
  if registry_qualified "$source"; then
    [[ "$source" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?$ ]] \
      || fail "REQS_IMAGES ${entry}: ${source} is no <registry>/<repository>:<tag>"
    continue
  fi
  path="$(dockerhub_path "$source")"
  [[ "$path" =~ ^[a-z0-9._-]+/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]{64})?$ ]] || fail "REQS_IMAGES ${entry}: ${path} is no Docker Hub path"
done
echo "ok - every REQS_IMAGES source is a Docker Hub repository path or a reference with its registry"
