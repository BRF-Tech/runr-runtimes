# The runtime catalog (schema/runtime-catalog.v1.json) as jq functions. lib/catalog.sh includes them
# (jq -L lib 'include "catalog"; …'); test/catalog_artifact_test.sh tests them. The patch tags of
# catalog patches follow the patch feed's rules (lib/feed.jq).
include "feed";

# RunR's catalog order (BuiltinCatalog::readSources, lib/catalog.py): these first, the rest by path
def catalog_order: ["python", "nodejs", "go", "php", "tensorflow", "pytorch"];

# the runtime id of an entry's path: "runtimes/go/runtime.yaml" → "go"
def path_id: split("/") | .[-2];

def order_key: path_id as $id | [(catalog_order | index($id)) // (catalog_order | length), .];

# does a manifest have a version that RunR builds from a Dockerfile of the runtime's files?
def dockerfile_versions: [.versions[]? | objects | select(has("dockerfile")) | .dockerfile];

# what the catalog carries: runtimes and patches, not when or from which commit it was built
def catalog_content: {runtimes: .runtimes, patches: (.patches // [])};

# the problems of a catalog that its JSON Schema cannot express (one message each); $keep: the
# patches per runtime version (the patch feed's PATCH_KEEP), $files_max: the bytes of a runtime's
# files (RunR's ConfigMap budget, 900 KB)
def catalog_problems($keep; $files_max):
  [ (.runtimes // [] | group_by(.manifest.id)[] | select(length > 1) | "duplicate runtime id \(.[0].manifest.id)"),
    (.runtimes // [] | group_by(.path)[] | select(length > 1) | "duplicate path \(.[0].path)"),
    (.runtimes[]? | select((.path | path_id) != .manifest.id)
      | "\(.path): the manifest's id is \(.manifest.id | tojson), not its directory's name"),
    (if [.runtimes[]?.path] != ([.runtimes[]?.path] | sort_by(order_key)) then
       "the runtimes are not in the catalog order (\(catalog_order | join(", ")), then by path): \([.runtimes[]?.manifest.id] | join(", "))"
     else empty end),
    (.runtimes[]? | . as $r | .manifest | dockerfile_versions[] as $d | select($r.files // {} | has($d) | not)
      | "\($r.path): the dockerfile \($d) is not among its files"),
    (.runtimes[]? | select(.files != null) | ([.files[] | utf8bytelength] | add // 0) as $bytes
      | select($bytes > $files_max) | "\(.path): its files are \($bytes) bytes (at most \($files_max))"),
    ([.runtimes[]?.manifest.id] as $ids | .patches[]? | select(.runtime as $r | $ids | index($r) | not)
      | "patch \(.id): the runtime \(.runtime) is not in the catalog"),
    (.patches // [] | group_by(.id)[] | select(length > 1) | "duplicate patch id \(.[0].id)"),
    (.patches[]? | select(.id != "\(.runtime)-\(.version)-\(.tag)") | "patch \(.id): the id is not <runtime>-<version>-<tag> (\(.runtime)-\(.version)-\(.tag))"),
    (.patches[]? | select((.tag | tag_version) != .version) | "patch \(.id): \(.tag) is not a patch tag of \(.version)"),
    (.patches[]? | select((.deadline_at // "") != "" and .deadline_at < .published_at) | "patch \(.id): deadline_at is before published_at"),
    (.patches // [] | group_by([.runtime, .version])[] | select(length > $keep) | "\(.[0].runtime) \(.[0].version): \(length) patches (at most \($keep))")
  ];

# a short account of the changes between two catalogs ($old: the current one; input: the next one)
def catalog_changes($old):
  ([$old.runtimes[]? | {key: .manifest.id, value: .}] | from_entries) as $before
  | ([.runtimes[] | {key: .manifest.id, value: .}] | from_entries) as $after
  | ([$old.patches[]? | {key: .id, value: .}] | from_entries) as $pbefore
  | ([.patches[]? | {key: .id, value: .}] | from_entries) as $pafter
  | [ (.runtimes[] | select($before[.manifest.id] == null) | "  + \(.manifest.id) (\(.path))"),
      (.runtimes[] | select($before[.manifest.id] != null and $before[.manifest.id] != .)
        | . as $r | $before[.manifest.id] as $b
        | [ (if $b.manifest != $r.manifest then "manifest" else empty end),
            (if ($b.files // {}) != ($r.files // {}) then "files" else empty end),
            (if $b.path != $r.path then "path" else empty end) ] as $what
        | "  ~ \(.manifest.id) (\($what | join(", ")))"),
      ($old.runtimes[]? | select($after[.manifest.id] == null) | "  - \(.manifest.id)"),
      (.patches[]? | select($pbefore[.id] == null) | "  + patch \(.id) \(.level)"),
      (.patches[]? | select($pbefore[.id] != null and $pbefore[.id] != .) | "  ~ patch \(.id)"),
      ($old.patches[]? | select($pafter[.id] == null) | "  - patch \(.id)") ];

# one line per runtime: its id, its versions (listed, or discovered from a registry), its files
def catalog_summary:
  .runtimes[]
  | [ .manifest.id,
      (if .manifest.versions then "\(.manifest.versions | length) version(s)" else "versions discovered from \(.manifest.versionDiscovery.repository // "?")" end),
      (if .files then "\(.files | length) file(s), dockerfile" else empty end) ]
  | join("  ");
