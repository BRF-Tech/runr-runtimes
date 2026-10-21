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

## Images (publish, patch and heavy-images workflows)

| Package | Image | Workflow |
|---------|-------|----------|
| `runr/exec-python` | `ghcr.io/brf-tech/runr/exec-python` | publish, patch (Admin role: see below) |
| `runr/exec-nodejs` | `ghcr.io/brf-tech/runr/exec-nodejs` | publish, patch (Admin role: see below) |
| `runr/exec-go` | `ghcr.io/brf-tech/runr/exec-go` | publish, patch (Admin role: see below) |
| `runr/exec-php` | `ghcr.io/brf-tech/runr/exec-php` | publish, patch (Admin role: see below) |
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

### Patch tags: the Admin role on the language runtimes

The language runtimes are published as patches: every build that changed gets an immutable tag
`<full version>-r<n>` (README.md, "Patches and the patch feed"). The feed jobs of the publish,
patch and platform-release workflows delete the patch tags beyond the newest five of each version,
through the GitHub Packages API with the workflow's `GITHUB_TOKEN`. A workflow token may delete
versions of a package only when the repository has the **Admin** role on it, so these four
packages need, once, instead of Write:

**Package settings → Manage Actions access → `BRF-Tech/runr-runtimes` → role Admin.**

| Package | Settings |
|---------|----------|
| `runr/exec-python` | <https://github.com/orgs/BRF-Tech/packages/container/runr%2Fexec-python/settings> |
| `runr/exec-nodejs` | <https://github.com/orgs/BRF-Tech/packages/container/runr%2Fexec-nodejs/settings> |
| `runr/exec-go` | <https://github.com/orgs/BRF-Tech/packages/container/runr%2Fexec-go/settings> |
| `runr/exec-php` | <https://github.com/orgs/BRF-Tech/packages/container/runr%2Fexec-php/settings> |

Without it the deletions fail (HTTP 403), the feed job fails after it published the feed, and the
old patch tags stay until the next feed update deletes them.

## The patch feed (publish, patch and platform-release workflows)

| Package | Tags | Workflow |
|---------|------|----------|
| `runr/runtime-patches` | `feed` (the signed feed RunR instances read), `feed-candidate` (the last pushed), `sha256-<digest>.sig` (cosign signatures) | the feed jobs of publish and patch; platform-release |

The first feed update creates the package; the `org.opencontainers.image.source` annotation of the
feed links it to this repository. It starts out private: **set its visibility to public** once,
after the first push, so every RunR instance can read the feed without credentials
(<https://github.com/orgs/BRF-Tech/packages/container/runr%2Fruntime-patches/settings>).

### The patch feed's signing key

The feed is signed with a cosign key pair (ECDSA P-256) that the owner generated once, on
2026-10-22:

| | |
|-|-|
| Public key | [`keys/patch-feed.pub`](keys/patch-feed.pub) |
| SHA-256 of the key (DER) | `24d79a49162ffec0b866ab7274a451a566f7e27fdb6804bffb6d9859d4b1c0df` (`openssl pkey -pubin -in keys/patch-feed.pub -outform DER \| sha256sum`) |
| Private key, password | the Actions secrets `RUNR_PATCH_FEED_COSIGN_KEY` and `RUNR_PATCH_FEED_COSIGN_PASSWORD`; a copy in the owner's password manager |

A `keys/patch-feed.pub` that is no public key makes every feed job fail (`… is not a public key`);
the images are still published, and the first feed update after the key exists lists their
patches.

How the pair was made, and how a new one is made:

1. On a trusted machine with [cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
   2.x, in an empty directory:

   ```bash
   cosign generate-key-pair
   ```

   It asks for a password twice (use a long random one) and writes `cosign.key` (the private key,
   encrypted with the password) and `cosign.pub` (the public key).
2. Replace `keys/patch-feed.pub` with the public key and commit it to `main` (through a pull
   request):

   ```bash
   cp cosign.pub /path/to/runr-runtimes/keys/patch-feed.pub
   ```

3. Store the private key and its password as Actions secrets of this repository (Settings →
   Secrets and variables → Actions), or with the GitHub CLI:

   ```bash
   gh secret set RUNR_PATCH_FEED_COSIGN_KEY -R BRF-Tech/runr-runtimes < cosign.key
   gh secret set RUNR_PATCH_FEED_COSIGN_PASSWORD -R BRF-Tech/runr-runtimes   # prompts for the password
   ```

4. Keep `cosign.key` and its password in the password manager, then delete the local copy.
5. Give RunR the public key (the instances verify the feed with it).

Every feed update checks the pair: it verifies the current feed's signature with
`keys/patch-feed.pub` before it builds on it, and the new feed's signature before it moves `feed`.
A secret that is not the pair of the committed key stops the update; `feed` keeps naming the
previous signed feed.

To rotate the key: generate a new pair, commit the new public key and replace both secrets
together, then run one feed update from a shell that names the old public key, so the current feed
(signed with the old key) is accepted once:

```bash
PATCH_FEED_PREVIOUS_KEY=old-patch-feed.pub PATCH_FEED_SIGNING_KEY=cosign.key \
  RUNR_PATCH_FEED_COSIGN_PASSWORD=… GHCR_TOKEN=… ./ci.sh feed update --push
```

## The reqs mirror (mirror workflow, and mirror-bases of the publish and patch workflows)

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
