# GHCR packages

The workflows of this repository push to these packages of the BRF-Tech organization with their
own `GITHUB_TOKEN`. A package that already exists accepts a push from a workflow only when it grants
this repository write access. These packages were published before this repository existed, so
each one needs the following once, in its settings:

**Package settings → Manage Actions access → Add repository → `BRF-Tech/runr-runtimes`, role
Write.**

The settings page of a package is
`https://github.com/orgs/BRF-Tech/packages/container/<package, "/" written as %2F>/settings`, for
example <https://github.com/orgs/BRF-Tech/packages/container/runr%2Fexec-python/settings>.

A package that a workflow of this repository creates gets its access from the repository
(`org.opencontainers.image.source`). It starts out private: set its visibility to public in its
settings once, after the first push.

## Images (publish and heavy-images workflows)

| Package | Image | Workflow |
|---------|-------|----------|
| `runr/exec-python` | `ghcr.io/brf-tech/runr/exec-python` | publish |
| `runr/exec-nodejs` | `ghcr.io/brf-tech/runr/exec-nodejs` | publish |
| `runr/exec-go` | `ghcr.io/brf-tech/runr/exec-go` | publish |
| `runr/exec-php` | `ghcr.io/brf-tech/runr/exec-php` | publish |
| `runr/exec-pytorch` | `ghcr.io/brf-tech/runr/exec-pytorch` | publish (CPU), heavy (`-gpu`) |
| `runr/exec-tensorflow` | `ghcr.io/brf-tech/runr/exec-tensorflow` | publish (CPU), heavy (`-gpu`) |
| `runr/exec-wasm-rust` | `ghcr.io/brf-tech/runr/exec-wasm-rust` | publish |
| `runr/exec-wasm-go` | `ghcr.io/brf-tech/runr/exec-wasm-go` | publish |
| `runr/exec-wasm-js` | `ghcr.io/brf-tech/runr/exec-wasm-js` | publish |
| `runr/exec-wasm-python` | `ghcr.io/brf-tech/runr/exec-wasm-python` | publish |
| `runr/exec-wasm-exec` | `ghcr.io/brf-tech/runr/exec-wasm-exec` | publish |
| `runr/wrapper` | `ghcr.io/brf-tech/runr/wrapper` | publish |
| `runr/hf-serve` | `ghcr.io/brf-tech/runr/hf-serve` | publish (CPU), heavy (`-cuda`) |

`ci.sh eol --prune` deletes end-of-life `exec-*` versions through the GitHub Packages API. It needs
a token that may delete package versions (`GHCR_TOKEN`); it is not part of a workflow.

## The reqs mirror (mirror workflow, and mirror-bases of the publish workflow)

Every image of `REQS_IMAGES` in `lib/mirror.sh`, and the base images of the language runtimes
(`python`, `node`, `golang`, `php`):

| Package | Package | Package |
|---------|---------|---------|
| `runr/reqs/alpine` | `runr/reqs/external-secrets` | `runr/reqs/pdns-auth` |
| `runr/reqs/bash` | `runr/reqs/frankenphp` | `runr/reqs/php` |
| `runr/reqs/binfmt` | `runr/reqs/garage` | `runr/reqs/postgres` |
| `runr/reqs/busybox` | `runr/reqs/golang` | `runr/reqs/python` |
| `runr/reqs/caddy` | `runr/reqs/helm` | `runr/reqs/pytorch` |
| `runr/reqs/cert-manager-acmesolver` | `runr/reqs/k6` | `runr/reqs/rclone` |
| `runr/reqs/cert-manager-cainjector` | `runr/reqs/kindest-node` | `runr/reqs/redis` |
| `runr/reqs/cert-manager-controller` | `runr/reqs/mailpit` | `runr/reqs/rust` |
| `runr/reqs/cert-manager-webhook` | `runr/reqs/nginx` | `runr/reqs/tempo` |
| `runr/reqs/composer` | `runr/reqs/node` | `runr/reqs/tinygo` |
| `runr/reqs/curl` | `runr/reqs/openbao` | `runr/reqs/traefik` |
| `runr/reqs/docker` | `runr/reqs/opentelemetry-collector-contrib` | |

When you add an image to `REQS_IMAGES` whose package does not exist yet, the mirror workflow
creates the package. Set its visibility to public afterwards.

## Not published here

RunR's own images stay in BRF-Tech/runr and are versioned with the API: `runr/api`, `runr/ui`,
`runr/agent`, `runr/queue-consumer`, `runr/supply-chain`, `runr/image-upload`,
`runr/containerd-shim-spin` and `runr/nginx-test`. Do not give this repository access to them.
