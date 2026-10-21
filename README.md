# RunR runtimes

The language runtime images of [RunR](https://github.com/BRF-Tech/runr), the scripts that build,
smoke-test and publish them, and the mirror of the third-party images RunR uses. GitHub Actions
builds every image here and publishes it to `ghcr.io/brf-tech/runr/`, under the same names and tags
as before the images moved out of the RunR repository. Existing installs and the API's runtime
discovery need no change.

RunR itself (the API, console, Helm chart, region agent, queue consumer, supply-chain and
image-upload images, the Spin shim and the end-to-end harness) stays in
[BRF-Tech/runr](https://github.com/BRF-Tech/runr). Its Kind tests pull the images published here,
at the tags pinned in its `runtime/lib/runtime-images.sh`.

## Images

| Image | Tags | Platforms | Source |
|-------|------|-----------|--------|
| `exec-python` | `<major.minor>` of every Python release that is not end-of-life, from 3.10 (today 3.10–3.15) | amd64, arm64 | `runtimes/python/` |
| `exec-nodejs` | `<major.minor>`: the latest minor of every even (LTS) Node.js major from 20 | amd64, arm64 | `runtimes/nodejs/` |
| `exec-go` | `<major.minor>` from 1.22, without end-of-life releases | amd64, arm64 | `runtimes/go/` |
| `exec-php` | `<major.minor>` from 8.2, without end-of-life releases | amd64, arm64 | `runtimes/php/` |
| `exec-pytorch` | `<X.Y>` (CPU) and `<X.Y>-gpu` (CUDA 12.6); X.Y is the torch pin's major.minor (`requirements-torch.txt`) | amd64 | `runtimes/pytorch/` |
| `exec-tensorflow` | `<X.Y>` (CPU) and `<X.Y>-gpu` (CUDA); X.Y is the tensorflow-cpu pin's major.minor (`requirements-cpu.txt`) | amd64 | `runtimes/tensorflow/` |
| `exec-wasm-rust`, `exec-wasm-go`, `exec-wasm-js`, `exec-wasm-python`, `exec-wasm-exec` | the `version` of the runtime's `runtime.yaml` (today `4.1`) | amd64, arm64 | `runtimes/wasm-*/` |
| `wrapper` | the version of the binary (`const version` in `wrapper/main.go`, today `1.1.0`) | amd64, arm64 | `wrapper/` |
| `hf-serve` | `<version>` (CPU) and `<version>-cuda`; the version is `__version__` of `runr_hf_serve` (today `1.1.1`) | CPU: amd64, arm64; CUDA: amd64 | `hf-serve/` |
| `reqs/*` | mirrored third-party images (`lib/mirror.sh`) | as upstream | `lib/mirror.sh` |

All names are under `ghcr.io/brf-tech/runr/`, for example `ghcr.io/brf-tech/runr/exec-python:3.12`.
The language runtimes also carry an immutable patch tag for every build they published
(`exec-php:8.3.36-r1`, the newest five per version): see
[Patches and the patch feed](#patches-and-the-patch-feed).
Every image built here carries the label
`org.opencontainers.image.source=https://github.com/BRF-Tech/runr-runtimes`.

What the images are:

- **Language runtimes** (`exec-python`, `exec-nodejs`, `exec-go`, `exec-php`): the image of a
  function. Each serves RunR's HTTP contract itself (the language's handler server in
  `runtimes/<runtime>/`) and runs a scheduled invocation once with `RUNR_MODE=schedule`. User code is
  mounted at `/app/code`.
- **ML runtimes** (`exec-pytorch`, `exec-tensorflow`): Python 3.12 with the framework and the ML
  essentials preinstalled, on the Python runtime's handler server. The `-gpu` images carry the
  CUDA builds of the frameworks.
- **WebAssembly build images** (`exec-wasm-*`): the toolchains RunR's build Jobs compile functions
  with (Rust, TinyGo, JavaScript, Python, and wasi-sdk / Zig / TinyGo for `wasm-exec`), with the Spin
  CLI of the Spin runtime RunR's shim embeds. They are never deployed as functions.
- **wrapper** (`runr-wrapper`): the universal wrapper, a static binary that is PID 1 of `exec` and
  `persistent` runtimes. Init containers copy it into a pod or a build context.
- **hf-serve**: RunR's serving engine for model services on the `transformers` and `diffusers`
  engines. The CPU image serves transformers pipelines; the CUDA image adds CUDA PyTorch and
  diffusers (text-to-image).

### The catalog manifests

Each `runtimes/<id>/runtime.yaml` is the manifest of a built-in runtime of RunR's catalog. It
defines the handler, the starter code, the build and the versions (for the language and ML
runtimes, the tags of the image above). The RunR API ships the catalog as
`api/resources/runtimes/builtin.json`. After you change a manifest or a file it references with
`@file`, regenerate that bundle in a checkout of BRF-Tech/runr:

```bash
cd runr/api
RUNR_RUNTIME_CATALOG=../../runr-runtimes/runtimes php artisan runtimes:bundle
```

The CI workflow validates the manifests against RunR's runtime schema, and `test/catalog_test.sh`
checks that the files and image tags they reference are here.

## Layout

| Path | Contents |
|------|----------|
| `runtimes/<id>/` | The 11 built-in runtimes: `runtime.yaml`, Dockerfile, handler server or toolchain files. They stay together in one directory because the API's `runtimes:bundle` reads `*/runtime.yaml` of one directory. |
| `wrapper/` | `runr-wrapper` (Go) and its tests |
| `hf-serve/` | hf-serve (Python), its CPU and CUDA Dockerfiles and its tests |
| `ci.sh`, `lib/` | Build, smoke-test, push, patch, patch feed, mirror and EOL commands |
| `test/` | Shell tests of `ci.sh`, run without Docker or a registry |
| `ci/` | `check-dockerfiles.sh`, `check-reqs-mirror.sh` and `images.sh` (the image selection of the workflows) |
| `schema/` | The patch feed's JSON Schema (`patch-feed.v1.json`) and an example feed |
| `keys/` | `patch-feed.pub`, the public key of the patch feed's signatures |
| `.github/workflows/` | CI, publish, patch, platform release, heavy GPU images, reqs mirror |
| `.github/actions/` | `patch-feed-tools`: oras, cosign and check-jsonschema for the feed jobs |
| `PACKAGES.md` | The GHCR packages this repository writes to, and the access each one needs |

## Building locally

You need bash, Docker with buildx, and curl. `mirror-*` also needs
[crane](https://github.com/google/go-containerregistry).

```bash
./ci.sh build python               # exec-python, every current version, built and smoke-tested
./ci.sh build                      # all four language runtimes
./ci.sh wrapper                    # wrapper:<version>
./ci.sh wasm rust js               # two WebAssembly build images (all five without a name)
./ci.sh ml-runtimes pytorch cpu    # exec-pytorch:<X.Y> (pytorch|tensorflow, cpu|gpu)
./ci.sh ml-runtimes --list         # the ML image references, nothing built
./ci.sh hf-serve cpu               # hf-serve:<version> (cpu|cuda)
./ci.sh mirror-reqs --dry-run      # what the mirror would copy
./ci.sh eol                        # EOL report of the published exec-* tags
./ci.sh patch php --level zero-day --reason-en "…" --reason-tr "…"   # dry run of a patch
./ci.sh feed show                  # the current patch feed
./ci.sh feed update                # what the next feed update would publish and delete
./ci.sh help
```

`patch` and `feed` also need [jq](https://jqlang.org); publishing the feed (`--push`) needs
[oras](https://oras.land), [cosign](https://docs.sigstore.dev) and
[check-jsonschema](https://github.com/python-jsonschema/check-jsonschema).

How every build behaves:

- **Pulls its base images** (`--pull`). Base images come from the reqs mirror
  (`ghcr.io/brf-tech/runr/reqs/…`), never from Docker Hub (`ci/check-dockerfiles.sh`).
- **Is smoke-tested** after it is built (`lib/smoke.sh`; the ML runtimes: `lib/build-ml.sh`).
  `--no-smoke` skips this for local builds.
  - A language runtime answers a handler over HTTP, called from a curl container in its network
    namespace, and runs it once with `RUNR_MODE=schedule`. The language version must match the tag.
  - The ML runtimes run tensor operations through the same two paths.
  - The wrapper must print its tag's version.
  - The WebAssembly images must carry the Spin CLI their Dockerfile pins.
  - hf-serve must print its version and import its server with torch and transformers. The CUDA
    image must also have a CUDA build of torch and diffusers.
  - A `-gpu` or `-cuda` image runs on the GPU when `docker run --gpus all` gives it one. Otherwise
    only its CUDA build is checked, and the output says the GPU check was skipped (`ML_SMOKE_GPU`).
- **`--push` pushes only after every image of the command passed its smoke test.** The language
  runtimes are pushed as patches: see [Patches and the patch feed](#patches-and-the-patch-feed).
  - Multi-arch images are built again for `PLATFORMS` (default `linux/amd64,linux/arm64`) in
    `ci.sh`'s own docker-container buildx builder (`BUILDER_NAME`, default `runr-multiarch`). That
    builder never becomes the host's current builder and is removed after the push.
  - The amd64-only images (ML runtimes, hf-serve CUDA) are pushed exactly as tested: `docker push`
    of the same image ID.
  - `--push --no-smoke` is refused.

A local build tags the image with its published name. To test an unpublished change in RunR's Kind
harness, build it here, then run the harness with `RUNTIME_IMAGES_LOCAL=1`. It then uses the local
image instead of pulling the published one (see `runtime/lib/runtime-images.sh` in BRF-Tech/runr).

## How CI publishes

Every workflow pushes with its own `GITHUB_TOKEN` (`permissions: packages: write`); there is no
personal token or bot account. Each existing package must grant this repository write access
first: see [PACKAGES.md](PACKAGES.md). The patch feed is signed with a key of the repository's
Actions secrets (PACKAGES.md).

| Workflow | When | What |
|----------|------|------|
| `ci.yml` (CI) | pull requests, pushes to other branches | shellcheck, actionlint, the shell tests, `check-dockerfiles.sh`, `check-reqs-mirror.sh`, the wrapper's Go tests, hf-serve's pytest, the manifests against RunR's runtime schema, the patch feed's schema and example, and on pull requests a local build + smoke test (no push) of every CPU image the change touches |
| `publish.yml` (Publish images) | push to `main`; by hand; weekly (Monday 03:17 UTC) | Build, smoke-test and push the CPU images. On a push: the images whose sources changed. By hand: the keys named (`cpu` for all of them, `languages`). Weekly: the language runtimes, which follow upstream patch releases and new versions. Before the language runtimes, the base images are mirrored (`mirror-bases`), so a newly discovered version builds. The language runtimes are published as routine patches; then the feed job updates the patch feed and deletes old patch tags. |
| `patch.yml` (Patch runtime images) | by hand | A patch on request (a zero-day): the runtimes and versions named rebuilt on freshly mirrored bases, smoke-tested, published as patches of the level given, the patch feed updated. See [A zero-day patch](#a-zero-day-patch). |
| `platform-release.yml` (Platform release in the patch feed) | by hand | A RunR platform release that carries a level, added to the patch feed |
| `heavy.yml` (Heavy images, GPU) | by hand, on any branch; weekly (Monday 04:17 UTC: `exec-pytorch` and `exec-tensorflow` `-gpu`) | `exec-pytorch`/`exec-tensorflow` `-gpu` and `hf-serve` `-cuda`, one image per job on a runner with its preinstalled toolchains removed. Without a GPU on the runner, the smoke test checks the CUDA build. `push: false` builds and smoke-tests only. |
| `mirror.yml` (Mirror reqs images) | by hand; weekly (Monday 02:17 UTC) | `ci.sh mirror-reqs` and `ci.sh mirror-bases` |

Which images a change touches (`ci/images.sh`, tested by `test/images_test.sh`):

- The image's directory: `runtimes/<id>/`, `wrapper/` or `hf-serve/`.
- For the ML runtimes, also the Python runtime's handler server (`server.py`, `runner.py`,
  `entrypoint.sh`).
- Not image changes: Markdown, the wrapper's and hf-serve's tests, and the `runtime.yaml` of a
  runtime whose tag does not come from it.
- A change to the build tooling (`ci.sh`, `lib/`) publishes nothing by itself. Run the publish
  workflow by hand for the images it should rebuild.
- The first push to `main` of a new repository publishes nothing.
- A push that touches a GPU image adds a notice to run the heavy-images workflow.

A tag is published again when its sources change; the version only changes when the source of the
version changes (see the table above). When a change should reach installs as a new version, raise
the version with it (the wrapper's `const version`, hf-serve's `__version__`, a WebAssembly
runtime's `version`). Then update the pins in BRF-Tech/runr: `runtime/lib/runtime-images.sh`, the
API and Helm defaults, and `api/resources/runtimes/builtin.json` (`runtimes:bundle`).

## Patches and the patch feed

Every published build of a language runtime (`exec-python`, `exec-nodejs`, `exec-go`, `exec-php`)
is a **patch**. RunR instances learn about patches from one signed document, the **patch feed**.

### Patch tags

A build of `exec-<runtime>:<major.minor>` that differs from the published image is pushed with two
tags: the floating `<major.minor>` (`exec-php:8.3`), which always names the newest patch, and the
immutable `<full upstream version>-r<n>` (`exec-php:8.3.36-r1`). The full version is the one the
image runs, as its smoke test reads it from the language (`PHP_VERSION`, `process.versions.node`,
`platform.python_version()`, `runtime.Version()`). `n` counts the builds of the same upstream
version that published a different image: a new base image or OS packages, our sources, the
packages the Dockerfile installs. A patch tag is never overwritten.

A build that is the image already published publishes nothing. The builds are reproducible: every
patch build runs with `SOURCE_DATE_EPOCH` (the time of the last commit of the runtime's directory)
and `rewrite-timestamp=true`, so the same sources on the same base give the same image digests.
`ci.sh` builds the multi-arch image without pushing and compares the digest of its image index with
the `sh.runr.patch.build` annotation of the floating tag's patch; only a different build is pushed
(the same build, from the builder's cache, with the patch annotations).

The patch tags of a version are kept for its newest five patches. Older patch tags are deleted by
the feed update after a publish (through the GitHub Packages API, as `ci.sh eol --prune`), never a
floating tag and never a patch the feed lists. RunR's runtime discovery reads only `<major.minor>`
tags; patch tags do not appear as versions.

### Levels and metadata

| Level | Meaning | Deadline |
|-------|---------|----------|
| `routine` | weekly rebuilds, upstream patch releases, our changes | none |
| `security` | a security fix | optional (`deadline_hours`) |
| `critical` | a critical security fix | required, default 168 hours |
| `zero-day` | a vulnerability exploited before a fix existed | required, default 72 hours |

Every patch carries: `level`, `reason` (short, `en` and `tr`), `cves` (CVE or GHSA ids), `url` (the
advisory), `upstream` (`PHP 8.3.36`), `published_at`, `deadline_at`, and the digest of its image
index. A routine patch without a reason gets one from what changed: `Upstream PHP 8.3.36`,
`Base image refresh` or `Runtime update`. The image index carries them as annotations
(`sh.runr.patch.id`, `.runtime`, `.version`, `.tag`, `.level`, `.reason.en`, `.reason.tr`, `.cves`,
`.url`, `.upstream`, `.published_at`, `.deadline_at`, and `.build` and `.base`, the build digest
and the base image with its digest); the platform manifests stay as built.

### The feed

`ghcr.io/brf-tech/runr/runtime-patches:feed` is an OCI artifact with one layer of
`application/vnd.runr.patch-feed.v1+json`: the JSON document of
[`schema/patch-feed.v1.json`](schema/patch-feed.v1.json) (an example:
[`schema/patch-feed.example.json`](schema/patch-feed.example.json)). `patches` holds the newest five
patches of every runtime version, `platform` the newest ten RunR platform releases that carry a
level; both newest first.

Every update builds the next feed from the current one: it pulls the feed and verifies its
signature (none yet: an empty feed), adds the patches the registry has and the feed lacks (read
from their annotations, so a publish whose feed update failed is listed by the next one), adds the
results of the run's builds (new patches, and the promotions of `promote_unchanged`), and checks
the result against the schema and the rules it cannot express (unique ids, at most five patches
per version). It pushes the feed as `feed-candidate`, signs it with cosign by digest, verifies the
signature with [`keys/patch-feed.pub`](keys/patch-feed.pub) and only then tags it `feed`: `feed`
always names a signed feed. One feed writer runs at a time (the workflows' `patch-feed`
concurrency group). An unchanged feed is not published again.

The signature is cosign's classic one (the tag `sha256-<digest>.sig` next to the feed, ECDSA P-256),
without a transparency log entry. To read and check the feed:

```bash
./ci.sh feed show --verify
# or with the tools themselves
cosign verify --key keys/patch-feed.pub --insecure-ignore-tlog=true ghcr.io/brf-tech/runr/runtime-patches:feed
oras pull ghcr.io/brf-tech/runr/runtime-patches:feed
```

### A zero-day patch

The owner decides that a vulnerability needs a patch and tells the operator. The operator runs
**Actions → Patch runtime images → Run workflow** with:

| Input | Example |
|-------|---------|
| `runtimes` | `php` (`php,python`, or `all`) |
| `versions` | `all`, `8.2,8.3,8.4,8.5` (one runtime), or `php:8.3,python:3.12` (several) |
| `level` | `zero-day` |
| `reason_en`, `reason_tr` | one line each |
| `cves` | `CVE-2026-109618` |
| `url` | the advisory |
| `deadline_hours` | empty: 72 for zero-day, 168 for critical |
| `promote_unchanged` | off (see below) |

or from a shell with the GitHub CLI:

```bash
gh workflow run patch.yml -R BRF-Tech/runr-runtimes \
  -f runtimes=php -f versions=all -f level=zero-day -f cves=CVE-2026-109618 \
  -f reason_en="Heap overflow in the multipart parser" -f reason_tr="Multipart ayrıştırıcısında heap taşması" \
  -f url=https://www.php.net/ChangeLog-8.php
```

The workflow checks the request, mirrors the base images again (the builds take upstream's fixed
bases), builds and smoke-tests every version named, publishes each changed one as a zero-day patch
and updates the feed.

A version whose build did not change gets no new patch, and the run warns about it. That has two
causes only a person can tell apart: upstream has no fixed release or base image yet (run the
workflow again once it has), or an earlier build already picked the fix up (a weekly build after
upstream's release). In the second case run it again with `promote_unchanged` on: the version's
current patch then takes the request's level, reason, CVEs and deadline in the feed. The image
annotations keep the metadata it was published with; the feed is what instances follow.

The same from a shell with push rights (`ci.sh patch` without `--push` is a dry run that builds and
shows what it would publish):

```bash
./ci.sh mirror-bases
./ci.sh patch php --versions all --level zero-day --cves CVE-2026-109618 \
  --reason-en "…" --reason-tr "…" --url https://… --push
```

A RunR platform release that carries a level (a security fix in RunR itself) goes into the feed
with **Actions → Platform release in the patch feed** (`version`, `level`, `reason_en`, `reason_tr`,
`url`), or `ci.sh feed platform --version 0.5.11 --level security --reason-en … --reason-tr … --push`.

### Other images

The ML runtimes, the WebAssembly build images, the wrapper and hf-serve have no patches yet. An
image adopts them in its `--push` path:

1. Read its full upstream version in its smoke test (torch or TensorFlow `__version__`, the Spin
   CLI of a WebAssembly image) and name its patch tag after it: `2.14.1-gpu-r1` of `2.14-gpu`
   (the variant suffix after the version), `4.1-r1` of `4.1` (a version without a patch number).
   `lib/feed.jq` already orders and groups such tags (`tag_key`, `tag_version`).
2. Publish with `patch_publish_image PUSH RUNTIME VERSION FULL CONTEXT [BUILD FLAG...]` (the
   image is `exec-<RUNTIME>`, VERSION its floating tag) instead of `push_built`; extend
   `patch_full_version_valid` and `patch_upstream` for its versions and name (today they know
   `<major.minor>.<patch>` releases of the four languages). A multi-arch image (WebAssembly, the
   wrapper, hf-serve CPU) needs nothing else. The images pushed exactly as tested (`docker push`
   of the ML runtimes and hf-serve CUDA) first need a reproducible single-platform build
   (`docker buildx build --load` with `SOURCE_DATE_EPOCH` and `rewrite-timestamp=true`) and the
   same digest comparison on their image manifest.
3. Add the runtime to `PATCH_LANGUAGE_RUNTIMES` (the runtimes the feed update reads and prunes),
   to `patch.yml`'s inputs and outputs, and check its Dockerfile builds reproducibly (two builds
   without cache, the same digest).

## The reqs mirror

`ghcr.io/brf-tech/runr/reqs/` holds every third-party image RunR uses, copied multi-arch from
Docker Hub: Docker Hub's anonymous pull limit would otherwise stop nodes, build hosts and CI
runners. `lib/mirror.sh` lists them (`REQS_IMAGES`). The base images of the language runtimes are
discovered like the runtime versions (`mirror-bases`).

- When Docker Hub refuses a copy, the image comes from a pull-through mirror of it
  (`REQS_UPSTREAMS`), and only by Docker Hub's digest.
- An image Docker Hub does not carry is listed with its registry
  (`quay.io/jetstack/cert-manager-controller:v1.21.2`) and copied from that registry alone, so
  RunR pulls it from one place.
- BRF-Tech/runr checks that every reqs image it references resolves anonymously. An image it
  starts to use is added to `REQS_IMAGES` here and mirrored first (`mirror.yml` by hand, with the
  image's name).

## Tests

```bash
for t in test/*_test.sh; do bash "$t"; done   # without Docker or a registry (jq; check-jsonschema for the feed's schema)
bash ci/check-dockerfiles.sh
bash ci/check-reqs-mirror.sh
(cd wrapper && go test -race ./...)
(cd hf-serve && pip install -r requirements-test.txt && python -m pytest tests)
```

## Contributing, security, license

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md). MIT licensed, see [LICENSE](LICENSE).
