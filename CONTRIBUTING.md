# Contributing to RunR runtimes

Thanks for your interest. Fixes and improvements to the runtime images are welcome. This repository
follows the [Code of Conduct of RunR](https://github.com/BRF-Tech/runr/blob/main/CODE_OF_CONDUCT.md).
Report security issues privately, as described in [SECURITY.md](SECURITY.md), never in a public
issue.

How the runtimes behave inside RunR (handlers, triggers, versions, the catalog) is documented in
[RunR's docs](https://github.com/BRF-Tech/runr/blob/main/docs/runtimes.md). Bugs and features of RunR
itself belong in [BRF-Tech/runr](https://github.com/BRF-Tech/runr/issues).

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused, and add or update tests for behaviour you change.
3. Run the checks below, then open a pull request against `main`. CI builds and smoke-tests every
   CPU image your change touches; nothing is pushed from a pull request. A maintainer runs the
   heavy-images workflow on your branch when a GPU image is affected.

```bash
for t in test/*_test.sh; do bash "$t"; done
bash ci/check-dockerfiles.sh
bash ci/check-reqs-mirror.sh
(cd wrapper && gofmt -l . && go vet ./... && go test -race ./...)
(cd hf-serve && pip install -r requirements-test.txt && python -m pytest tests)
./ci.sh build python               # the image you changed, built and smoke-tested locally
```

Some rules:

- **Base images** come from the reqs mirror (`ghcr.io/brf-tech/runr/reqs/…`), never from Docker
  Hub. Add a new one to `REQS_IMAGES` in `lib/mirror.sh`.
- **A catalog manifest** (`runtimes/<id>/runtime.yaml`) or a file it references is bundled by RunR's
  API. Mention such a change in the pull request: RunR picks it up with `php artisan runtimes:bundle`
  (see [README.md](README.md#the-catalog-manifests)).
- **A new version.** When installs should get the change as a new version, raise the version with
  it: the wrapper's `const version`, hf-serve's `__version__`, or a WebAssembly runtime's `version`.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example
`fix(python): …`, `feat(wrapper): …` or `ci: …`.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
