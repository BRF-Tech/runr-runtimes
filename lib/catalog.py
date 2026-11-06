#!/usr/bin/env python3
"""Builds the payload of RunR's runtime catalog (schema/runtime-catalog.v1.json) from the
manifests runtimes/<id>/runtime.yaml. lib/catalog.sh runs it (ci.sh catalog build / publish).

  python3 lib/catalog.py --runtimes DIR --repository URL --revision SHA --generated-at TIME
                         [--prefix runtimes] [--patches FILE]

The payload goes to stdout; a problem that stops the build to stderr, exit 1.

The rules are the ones RunR's API applies when it bundles the same manifests
(BuiltinCatalog::readSources), so a runtime reads the same from the catalog as from the bundle:

  - one entry per <DIR>/<id>/runtime.yaml; the manifest's id is its directory's name
  - the order: python, nodejs, go, php, tensorflow, pytorch, then the rest by path
  - YAML as the YAML 1.2 core schema reads it: only true/false are booleans, only ~/null/empty
    are null, numbers are decimal (0o / 0x prefixes for octal / hex), dates and everything else
    stay strings; a duplicate key or a key that is not a string is an error
  - a "@file" value of build.files (a string, or each variant of an object such as
    {http: "@a.go", schedule: "@b.go"}) is replaced by the content of that file, relative to
    the manifest's directory (and inside it), CRLF turned into LF
  - "files": only for a runtime with a version that names a dockerfile; every regular file of
    its directory but runtime.yaml (not recursive), CRLF turned into LF; RunR builds the image in
    each region from them

Needs PyYAML (pip install pyyaml). The limits (file names, at most 50 files and 900 KB, at most
8 MiB in all) are checked by `ci.sh catalog validate` on the result, not here.
"""

import argparse
import json
import os
import re
import stat
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - reported to the caller
    sys.stderr.write("the runtime catalog needs PyYAML: pip install pyyaml\n")
    sys.exit(1)

# RunR's catalog order (BuiltinCatalog::readSources): these first, the rest by path
ORDER = ["python", "nodejs", "go", "php", "tensorflow", "pytorch"]


class BuildError(Exception):
    pass


class CoreLoader(yaml.SafeLoader):
    """yaml.safe_load with the YAML 1.2 core schema instead of YAML 1.1's implicit types."""


CoreLoader.yaml_implicit_resolvers = {}
for _tag, _pattern, _first in [
    ("tag:yaml.org,2002:bool", r"^(?:true|True|TRUE|false|False|FALSE)$", "tTfF"),
    ("tag:yaml.org,2002:null", r"^(?:~|null|Null|NULL|)$", ["~", "n", "N", ""]),
    ("tag:yaml.org,2002:int", r"^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$", "-+0123456789"),
    ("tag:yaml.org,2002:float",
     r"^(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$",
     "-+0123456789."),
    ("tag:yaml.org,2002:merge", r"^(?:<<)$", "<"),
]:
    CoreLoader.add_implicit_resolver(_tag, re.compile(_pattern), list(_first))


def _construct_bool(loader, node):
    return loader.construct_scalar(node).lower() == "true"


def _construct_int(loader, node):
    value = loader.construct_scalar(node)
    if value.startswith("0o"):
        return int(value[2:], 8)
    if value.startswith("0x"):
        return int(value[2:], 16)
    return int(value, 10)


def _construct_float(loader, node):
    value = loader.construct_scalar(node).lower()
    if value.endswith(".inf"):
        return float("-inf") if value.startswith("-") else float("inf")
    if value == ".nan":
        return float("nan")
    return float(value)


def _mapping_key(loader, key_node):
    key = loader.construct_object(key_node, deep=True)
    if not isinstance(key, str):
        raise yaml.constructor.ConstructorError(
            None, None, "a key that is not a string: %r" % (key,), key_node.start_mark)
    return key


def _construct_mapping(loader, node):
    # a key written twice is an error; a key of a "<<" merge is overridden by the mapping's own
    seen = set()
    for key_node, _ in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            continue
        key = _mapping_key(loader, key_node)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, "duplicate key %r" % key, key_node.start_mark)
        seen.add(key)
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        mapping[_mapping_key(loader, key_node)] = loader.construct_object(value_node, deep=True)
    return mapping


CoreLoader.add_constructor("tag:yaml.org,2002:bool", _construct_bool)
CoreLoader.add_constructor("tag:yaml.org,2002:int", _construct_int)
CoreLoader.add_constructor("tag:yaml.org,2002:float", _construct_float)
CoreLoader.add_constructor("tag:yaml.org,2002:map", _construct_mapping)


def normalize_newlines(text):
    return text.replace("\r\n", "\n")


def read_text(path, what):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise BuildError("%s: cannot read it (%s)" % (what, error.strerror))
    try:
        return normalize_newlines(data.decode("utf-8"))
    except UnicodeDecodeError:
        raise BuildError("%s: not UTF-8 text" % what)


def inline(value, directory, where):
    """A "@file" reference replaced by the file's content (BuiltinCatalog::inline)."""
    if not isinstance(value, str) or not value.startswith("@"):
        return value
    name = value[1:]
    root = os.path.realpath(directory)
    path = os.path.realpath(os.path.join(root, name))
    if os.path.commonpath([root, path]) != root or path == root:
        raise BuildError("%s: references %s, which is outside the manifest's directory" % (where, value))
    if not os.path.isfile(path):
        raise BuildError("%s: references %s, which does not exist next to the manifest" % (where, value))
    return read_text(path, "%s (%s)" % (where, value))


def has_dockerfile(manifest):
    versions = manifest.get("versions")
    return isinstance(versions, list) and any(isinstance(v, dict) and "dockerfile" in v for v in versions)


def directory_files(directory, where):
    """Every regular file of the runtime's directory but runtime.yaml, by name."""
    files = {}
    for entry in sorted(os.scandir(directory), key=lambda e: e.name):
        if entry.name == "runtime.yaml":
            continue
        mode = entry.stat(follow_symlinks=False).st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise BuildError("%s: %s is not a regular file (a link?): a dockerfile runtime's directory "
                             "holds only the files of its build context" % (where, entry.name))
        files[entry.name] = read_text(entry.path, "%s/%s" % (where, entry.name))
    return files


def runtime_entry(manifest_path, prefix):
    directory = os.path.dirname(manifest_path)
    runtime_id = os.path.basename(directory)
    path = "%s/%s/runtime.yaml" % (prefix, runtime_id) if prefix else "%s/runtime.yaml" % runtime_id
    text = read_text(manifest_path, path)
    try:
        manifest = yaml.load(text, Loader=CoreLoader)  # noqa: S506 - CoreLoader is a SafeLoader
    except yaml.YAMLError as error:
        raise BuildError("%s: not valid YAML: %s" % (path, str(error).replace("\n", " ")))
    if not isinstance(manifest, dict):
        raise BuildError("%s: not a mapping" % path)
    if manifest.get("id") != runtime_id:
        raise BuildError("%s: the id is %s, not the directory's name %s"
                         % (path, json.dumps(manifest.get("id")), runtime_id))

    build = manifest.get("build")
    if isinstance(build, dict) and isinstance(build.get("files"), dict):
        for name, content in build["files"].items():
            where = "%s build.files.%s" % (path, name)
            if isinstance(content, dict):
                build["files"][name] = {k: inline(v, directory, where) for k, v in content.items()}
            else:
                build["files"][name] = inline(content, directory, where)

    entry = {"path": path, "manifest": manifest}
    if has_dockerfile(manifest):
        entry["files"] = directory_files(directory, "%s/%s" % (prefix, runtime_id) if prefix else runtime_id)
    return entry


def order_key(path):
    runtime_id = path.split("/")[-2]
    return (ORDER.index(runtime_id) if runtime_id in ORDER else len(ORDER), path)


def read_patches(path):
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        raise BuildError("%s: not a JSON file (%s)" % (path, error))
    if isinstance(document, dict) and "patches" in document:
        document = document["patches"]
    if not isinstance(document, list):
        raise BuildError("%s: neither a list of patches nor a document with patches[]" % path)
    return document


def build(args):
    manifests = []
    for name in os.listdir(args.runtimes):
        candidate = os.path.join(args.runtimes, name, "runtime.yaml")
        if os.path.isfile(candidate):
            manifests.append(candidate)
    if not manifests:
        raise BuildError("%s: no <id>/runtime.yaml" % args.runtimes)

    runtimes = [runtime_entry(path, args.prefix) for path in manifests]
    runtimes.sort(key=lambda entry: order_key(entry["path"]))

    return {
        "schema": 1,
        "generated_at": args.generated_at,
        "source": {"repository": args.repository, "revision": args.revision},
        "runtimes": runtimes,
        "patches": read_patches(args.patches) if args.patches else [],
    }


def main():
    parser = argparse.ArgumentParser(description="Build the runtime catalog payload (schema 1).")
    parser.add_argument("--runtimes", required=True, help="the directory of <id>/runtime.yaml")
    parser.add_argument("--prefix", default="runtimes", help="the directory's path in the repository")
    parser.add_argument("--repository", required=True, help="source.repository")
    parser.add_argument("--revision", required=True, help="source.revision: the commit built from")
    parser.add_argument("--generated-at", required=True, help="generated_at: YYYY-MM-DDTHH:MM:SSZ")
    parser.add_argument("--patches", help="patches[]: a JSON list of patch-feed v1 entries, or a document with patches[]")
    args = parser.parse_args()

    try:
        payload = build(args)
        text = json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False)
    except BuildError as error:
        sys.stderr.write("%s\n" % error)
        return 1
    except (TypeError, ValueError) as error:
        # a YAML value JSON cannot carry: an explicit !!timestamp or !!binary, .inf, .nan
        sys.stderr.write("a manifest has a value that is not JSON: %s\n" % error)
        return 1
    sys.stdout.buffer.write((text + "\n").encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
