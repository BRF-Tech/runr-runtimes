# Build image of version 4.2 of the wasm-go runtime (ghcr.io/brf-tech/runr/exec-wasm-go:4.2): Go with
# the async support componentize-go needs for WASIp3 (the Go build componentize-go's releases name
# until golang/go#76775 lands: dicej/go go<GO_VERSION>-wasi-on-idle), componentize-go, the Spin CLI
# of the Spin runtime the shim embeds, and the Spin Go SDK v4 in the module cache with Go's build
# cache warm. It runs as the build Job of a function version (WasmBuildService); it is never
# deployed as a function. Version 4.1 (TinyGo, Spin Go SDK v2) is built from runtimes/wasm-go/.
#
#   docker build -t ghcr.io/brf-tech/runr/exec-wasm-go:4.2 runtimes/wasm-go/4.2     (or: ci.sh wasm)
FROM ghcr.io/brf-tech/runr/reqs/debian:bookworm-slim

# The RUN steps only, not the image: a docker-container BuildKit builder gives them
# OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=unix:///dev/otel-grpc.sock, which Spin's telemetry rejects
# ("invalid URI") before the command runs (ci/check-dockerfiles.sh)
ARG OTEL_SDK_DISABLED=true

ARG SPIN_VERSION=4.3.0
ARG SPIN_SHA256_AMD64=25de087b1f8443e979c8de1339e412c882dcb19eb5990c7888f9d206d0fbfa44
ARG SPIN_SHA256_ARM64=bd2205a74f70bada243839e7bdf06f55b572b19e6f799d5369d6c4071802bc94
# Go: the release of componentize-go's patched Go (go<GO_VERSION>-wasi-on-idle of dicej/go, the one
# componentize-go downloads itself when the Go it finds has no async support)
ARG GO_VERSION=1.27.1
ARG GO_SHA256_AMD64=4b4fcbbab5b5b0a45433112aa51c64a54007b24f1efd05b67018ca2cf8633e2c
ARG GO_SHA256_ARM64=c5967b4100558ca416d7d83d59ebd23095796d234286eb698d1e122b7c76c70d
# componentize-go: the binary the Go module of the same version (go.mod's tool) runs
ARG COMPONENTIZE_GO_VERSION=0.5.3
ARG COMPONENTIZE_GO_SHA256_AMD64=00e6f3435ad8260aa458cc3ac4368d3f9448a64a72d95e33970ed9d53799a1e9
ARG COMPONENTIZE_GO_SHA256_ARM64=7a64b733ab9600d83164389859a20f27810165633ed1de0d045cfdc895df2051
ARG TARGETARCH

# Caches outside $HOME (the build Job sets HOME=/tmp/home): module cache, Go's build cache and
# componentize-go's binary ($XDG_CACHE_HOME/componentize-go). GOTOOLCHAIN=local: a go.mod that asks
# for a newer Go fails plainly instead of downloading a Go without the async support.
ENV PATH=/usr/local/go/bin:$PATH \
    GOPATH=/opt/runr/go/path \
    GOCACHE=/opt/runr/go/cache/go-build \
    XDG_CACHE_HOME=/opt/runr/go/cache \
    GOFLAGS=-mod=mod \
    GOTOOLCHAIN=local

# download OUT URL: curl retries every error 5 times, 10 s apart; a GitHub release asset that still
# fails comes through the GitHub API's asset endpoint, which answers when releases/download gives
# 504 (test/fetch_test.sh runs this function)
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends bzip2 ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=amd64; spin_arch=amd64; spin_sum="$SPIN_SHA256_AMD64"; go_sum="$GO_SHA256_AMD64"; cgo_sum="$COMPONENTIZE_GO_SHA256_AMD64" ;; \
      arm64) arch=arm64; spin_arch=aarch64; spin_sum="$SPIN_SHA256_ARM64"; go_sum="$GO_SHA256_ARM64"; cgo_sum="$COMPONENTIZE_GO_SHA256_ARM64" ;; \
      *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    download() { \
      code="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30 -w '%{http_code}' -o "$1" "$2" 2>/dev/null)" && return 0; \
      case "$2" in https://github.com/*/releases/download/*) \
        p="${2#https://github.com/}"; t="${p#*/releases/download/}"; \
        echo "${2}: no answer after its retries, the release asset through the GitHub API instead" >&2; \
        a="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30 "https://api.github.com/repos/${p%%/releases/download/*}/releases/tags/${t%/*}" 2>/dev/null | tr -d ' \n\r' | grep -oE "\"url\":\"[^\"]+/releases/assets/[0-9]+\",\"id\":[0-9]+,\"node_id\":\"[^\"]+\",\"name\":\"${t##*/}\"" | cut -d'"' -f4)"; \
        [ -n "$a" ] && curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30 -H 'Accept: application/octet-stream' -o "$1" "$a" 2>/dev/null && return 0 ;; \
      esac; \
      echo "download failed: ${2} (HTTP ${code:-000})" >&2; return 1; \
    }; \
    download /tmp/spin.tar.gz "https://github.com/spinframework/spin/releases/download/v${SPIN_VERSION}/spin-v${SPIN_VERSION}-static-linux-${spin_arch}.tar.gz"; \
    echo "${spin_sum}  /tmp/spin.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/spin; \
    tar -xzf /tmp/spin.tar.gz -C /tmp/spin; \
    install -m 0755 "$(find /tmp/spin -type f -name spin | head -n 1)" /usr/local/bin/spin; \
    rm -rf /tmp/spin /tmp/spin.tar.gz; \
    download /tmp/go.tbz "https://github.com/dicej/go/releases/download/go${GO_VERSION}-wasi-on-idle/go-linux-${arch}-bootstrap.tbz"; \
    echo "${go_sum}  /tmp/go.tbz" | sha256sum -c -; \
    mkdir -p /usr/local/go; \
    tar -xjf /tmp/go.tbz -C /usr/local/go --strip-components=1; \
    rm -f /tmp/go.tbz; \
    grep -q wasiOnIdle /usr/local/go/src/runtime/lock_wasip1.go; \
    download /tmp/componentize-go.tar.gz "https://github.com/bytecodealliance/componentize-go/releases/download/v${COMPONENTIZE_GO_VERSION}/componentize-go-linux-${arch}.tar.gz"; \
    echo "${cgo_sum}  /tmp/componentize-go.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/cgo "${XDG_CACHE_HOME}/componentize-go/bin"; \
    tar -xzf /tmp/componentize-go.tar.gz -C /tmp/cgo; \
    install -m 0755 "$(find /tmp/cgo -type f -name componentize-go | head -n 1)" "${XDG_CACHE_HOME}/componentize-go/bin/componentize-go"; \
    printf 'v%s' "${COMPONENTIZE_GO_VERSION}" > "${XDG_CACHE_HOME}/componentize-go/version.txt"; \
    rm -rf /tmp/cgo /tmp/componentize-go.tar.gz; \
    spin --version; \
    go version

# The default module of a function, compiled once: its go.sum is what builds start from
WORKDIR /opt/runr/go
COPY go.mod spin.toml ./
COPY prewarm.go main.go
RUN set -eu; \
    sed -i 's/\r$//' go.mod spin.toml main.go; \
    go mod tidy; \
    go tool componentize-go build; \
    rm -f main.wasm; \
    chmod -R a+rwX /opt/runr

WORKDIR /workspace/code
