#!/usr/bin/env bash
# Tests the language runtimes of RUNTIME_DEFS (lib/common.sh) without a network: the versions
# runtime_versions finds in the tags of their upstream images (Docker Hub's API and a registry's
# tag list are fakes) with the filters of each runtime (endoflife.date is a fake too), the
# RunR version of a major tag (Temurin 21 → 21.0), and the base images mirror-bases copies for a
# version (runtime_base_images).
#
#   bash test/runtimes_test.sh
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$here/lib/registry.sh"

# Docker Hub's tag API and endoflife.date's cycles
curl() {
  local url="" arg
  for arg in "$@"; do
    case "$arg" in https://*) url="$arg" ;; esac
  done
  case "$url" in
    https://hub.docker.com/v2/repositories/library/eclipse-temurin/tags/*)
      [[ "$url" == *"&name=-jdk" ]] || return 22
      echo '{"next":null,"results":[{"name":"8-jdk"},{"name":"17-jdk"},{"name":"21-jdk"},{"name":"21-jdk-noble"},{"name":"21.0.9_10-jdk"},{"name":"25-jdk"},{"name":"26-jdk"},{"name":"27-jdk"}]}' ;;
    https://hub.docker.com/v2/repositories/oven/bun/tags/*)
      echo '{"next":null,"results":[{"name":"1.2-slim"},{"name":"1.3-slim"},{"name":"1.4-slim"},{"name":"1.4.4-slim"},{"name":"canary-slim"},{"name":"1.4"}]}' ;;
    https://hub.docker.com/v2/repositories/library/ruby/tags/*)
      echo '{"next":null,"results":[{"name":"3.2-slim"},{"name":"3.3-slim"},{"name":"3.4-slim"},{"name":"4.0-slim"},{"name":"4.0-slim-trixie"}]}' ;;
    https://endoflife.date/api/eclipse-temurin/21.json | https://endoflife.date/api/eclipse-temurin/25.json)
      echo '{"eol":"2031-09-30","lts":true}' ;;
    https://endoflife.date/api/eclipse-temurin/26.json | https://endoflife.date/api/eclipse-temurin/27.json)
      echo '{"eol":"2027-03-23","lts":false}' ;;
    https://endoflife.date/api/dotnet/10.json) echo '{"eol":"2028-11-14","lts":true}' ;;
    *) return 22 ;;
  esac
}
# mcr.microsoft.com's tag list
registry_tags() {
  [ "$1" = mcr.microsoft.com ] && [ "$2" = dotnet/sdk ] || return 0
  printf '%s\n' 10.0 10.0-alpine 10.0-noble 11.0 11.0-preview 9.0 latest
}

[ "$(runtime_ids)" = "python nodejs go php java dotnet ruby bun" ] || fail "ids: $(runtime_ids)"
[ "$(runtime_product java)" = eclipse-temurin ] && [ "$(runtime_product ruby)" = ruby ] || fail "products"
[ "$(base_mirror_name library/eclipse-temurin)" = eclipse-temurin ] && [ "$(base_mirror_name oven/bun)" = bun ] \
  && [ "$(base_mirror_name mcr.microsoft.com/dotnet/sdk)" = dotnet-sdk ] || fail "mirror names"
echo "ok - ids, endoflife.date products, names on the reqs mirror"

# Java: the LTS majors from 21 on, as <major>.0
[ "$(runtime_versions java | paste -sd' ' -)" = "21.0 25.0" ] || fail "java: $(runtime_versions java | paste -sd' ' -)"
# .NET: from 10.0 on, released ones only (11.0 is a release candidate: endoflife.date has no cycle)
[ "$(runtime_versions dotnet | paste -sd' ' -)" = "10.0" ] || fail "dotnet: $(runtime_versions dotnet | paste -sd' ' -)"
# Ruby: every major.minor from 3.3 on
[ "$(runtime_versions ruby | paste -sd' ' -)" = "3.3 3.4 4.0" ] || fail "ruby: $(runtime_versions ruby | paste -sd' ' -)"
# Bun: only the newest minor
[ "$(runtime_versions bun | paste -sd' ' -)" = "1.4" ] || fail "bun: $(runtime_versions bun | paste -sd' ' -)"
[ "$(filter_newest_minor "1.2 1.4 1.3 2.0 2.1" | paste -sd' ' -)" = "1.4 2.1" ] || fail "newest minor of each major"
echo "ok - versions: LTS majors (Java), released (.NET), from the lowest (Ruby), the newest minor (Bun)"

[ "$(runtime_base_images java 21.0)" = "eclipse-temurin:21.0-jdk|eclipse-temurin:21-jdk" ] || fail "java bases: $(runtime_base_images java 21.0)"
[ "$(runtime_base_images bun 1.4)" = "bun:1.4-slim|oven/bun:1.4-slim" ] || fail "bun bases"
[ "$(runtime_base_images ruby 3.4)" = "ruby:3.4-slim|ruby:3.4-slim" ] || fail "ruby bases"
[ "$(runtime_base_images python 3.12)" = "python:3.12-slim|python:3.12-slim" ] || fail "python bases"
[ "$(runtime_base_images dotnet 10.0 | paste -sd' ' -)" = "dotnet-sdk:10.0|mcr.microsoft.com/dotnet/sdk:10.0 dotnet-runtime-deps:10.0-chiseled-extra|mcr.microsoft.com/dotnet/runtime-deps:10.0-resolute-chiseled-extra" ] \
  || fail "dotnet bases: $(runtime_base_images dotnet 10.0 | paste -sd' ' -)"
echo "ok - base images: the Dockerfile's (a major tag mirrored as <major>.0), .NET's runtime-deps"

# The runtimes' files: every Dockerfile builds FROM the base image mirror-bases copies for the
# version of its default ARG, and every new runtime's scripts are executable
for runtime in java dotnet ruby bun; do
  dir="$here/runtimes/${runtime}"
  version=$(sed -n 's/^ARG VERSION=//p' "$dir/Dockerfile" | head -1)
  base=$(dockerfile_bases "$dir/Dockerfile" | tail -n 1)
  [ "$base" = "ghcr.io/brf-tech/runr/reqs/$(runtime_base_images "$runtime" "$version" | head -1 | cut -d'|' -f1)" ] \
    || fail "${runtime}: the Dockerfile builds on ${base}"
  for script in "$dir"/runr-*; do
    [ -x "$script" ] || fail "${script#"$here/"} is not executable"
  done
done
echo "ok - Dockerfiles on their mirrored base images, the scripts executable"
