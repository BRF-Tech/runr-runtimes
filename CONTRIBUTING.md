# Contributing to RunR runtimes

Thanks for your interest. Fixes and improvements to the runtime images are welcome. This repository
follows the [Code of Conduct of RunR](https://github.com/BRF-Tech/runr/blob/main/CODE_OF_CONDUCT.md).
Report security issues privately, as described in [SECURITY.md](SECURITY.md), never in a public
issue.

How the runtimes behave inside RunR (handlers, triggers, versions, the catalog) is documented in
[RunR's docs](https://github.com/BRF-Tech/runr/blob/main/docs/runtimes.md). Bugs and features of RunR
itself belong in [BRF-Tech/runr](https://github.com/BRF-Tech/runr/issues).

To bring a language to RunR from a repository of your own (public or private) instead of this
one, start from [BRF-Tech/runr-sample-custom-executor](https://github.com/BRF-Tech/runr-sample-custom-executor)
and read RunR's [executor development guide](https://github.com/BRF-Tech/runr/blob/main/docs/executor-development.md).

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused, and add or update tests for behaviour you change.
3. Run the checks below, then open a pull request against `main`. CI builds and smoke-tests every
   CPU image your change touches; nothing is pushed from a pull request. A maintainer runs the
   heavy-images workflow on your branch when a GPU image is affected.

```bash
for t in test/*_test.sh; do bash "$t"; done   # jq, python3 with PyYAML, check-jsonschema
./ci.sh catalog build              # the runtime catalog of runtimes/, checked
bash ci/check-dockerfiles.sh
bash ci/check-reqs-mirror.sh
(cd wrapper && gofmt -l . && go vet ./... && go test -race ./...)
(cd hf-serve && pip install -r requirements-test.txt && python -m pytest tests)
./ci.sh build python               # the image you changed, built and smoke-tested locally
```

Some rules:

- **Base images** come from the reqs mirror (`ghcr.io/brf-tech/runr/reqs/…`), never from Docker
  Hub. Add a new one to `REQS_IMAGES` in `lib/mirror.sh`.
- **A catalog manifest** (`runtimes/<id>/runtime.yaml`) or a file it references goes into the
  signed runtime catalog once the change is merged: RunR installations pick it up at their next
  catalog sync, without a RunR release (see [README.md](README.md#the-runtime-catalog)). Mention
  such a change in the pull request; the copy a RunR release ships is updated with
  `php artisan runtimes:bundle` (see [README.md](README.md#the-catalog-manifests)).
- **A new runtime** is a directory `runtimes/<id>/` with its manifest (`id` = the directory's
  name), Dockerfile and handler server, an image key in `ci/images.sh`, and the runtime counts of
  `test/catalog_test.sh` and `test/catalog_artifact_test.sh` raised. A language runtime also gets
  its line in `RUNTIME_DEFS` (`lib/common.sh`: the build, `ci.sh watch` and the language bot read
  it) and its `runtimes/<id>/tested-versions`. See
  [README.md](README.md#a-new-runtime-without-a-runr-release).
- **A new version.** When installs should get the change as a new version, raise the version with
  it: the wrapper's `const version`, hf-serve's `__version__`, or a WebAssembly runtime's `version`.
- **A new upstream release** of a language (a patch release, a new version) is published only after
  the language bot tested it: it lists it in `runtimes/<runtime>/tested-versions`. Leave that file to
  the bot ([README.md](README.md#the-language-bot)); a person's urgent patch goes through the patch
  workflow, which the gate never holds.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example
`fix(python): …`, `feat(wrapper): …` or `ci: …`.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
