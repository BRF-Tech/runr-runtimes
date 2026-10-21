# The patch feed (schema/patch-feed.v1.json) and the patch tags, as jq functions. lib/feed.sh and
# lib/patch.sh include them (jq -L lib 'include "feed"; …'); test/feed_test.sh tests them.
#
# A patch tag is <full version>-r<n> of a floating tag <version>: 8.3.36-r2 of exec-php:8.3,
# 22.11.0-r1 of exec-nodejs:22.11, 3.15.0rc1-r1 of exec-python:3.15. A variant suffix of the
# floating tag follows the full version (2.14.1-gpu-r1 of 2.14-gpu), a version without a patch
# number is its own full version (4.1-r3 of 4.1).

# the levels, lowest first
def level_rank: {"routine": 0, "security": 1, "critical": 2, "zero-day": 3}[.] // -1;

def is_patch_tag: test("^[0-9]+\\.[0-9]+[0-9A-Za-z._-]*-r[1-9][0-9]*$");

# the floating tag of a patch tag: "8.3.36-r2" → "8.3", "2.14.1-gpu-r1" → "2.14-gpu"
def tag_version:
  sub("-r[0-9]+$"; "")
  | (capture("^(?<maj>[0-9]+)\\.(?<min>[0-9]+)[0-9A-Za-z.]*(?<var>-.+)?$") | "\(.maj).\(.min)\(.var // "")") // .;

# a sort key of a patch tag, oldest first: the release numbers, a pre-release before its release
# (a < b < rc < the release), then the rebuild number
def tag_key:
  ((capture("^(?<v>.+)-r(?<r>[0-9]+)$")) // {v: ., r: "0"}) as $t
  | (($t.v | capture("^(?<num>[0-9]+(?:\\.[0-9]+)*)(?<pre>[a-z]+)?(?<pren>[0-9]*)(?<rest>.*)$"))
      // {num: "0", pre: null, pren: "", rest: $t.v}) as $p
  | [ ($p.num | split(".") | map(tonumber)),
      (if $p.pre == null then 9 else ({"a": 1, "alpha": 1, "b": 2, "beta": 2, "rc": 3}[$p.pre] // 0) end),
      (if $p.pren == "" then 0 else ($p.pren | tonumber) end),
      $p.rest,
      ($t.r | tonumber) ];

# the newest $keep patch tags of every floating tag among $tags (registry tags), newest first
def newest_patch_tags($tags; $keep):
  [$tags[] | select(is_patch_tag)]
  | group_by(tag_version)
  | map(sort_by(tag_key) | reverse | .[:$keep])
  | add // [];

# the patch tags of $runtime to delete, input the feed: beyond the newest $keep of their floating
# tag and not listed in the feed. Never a floating tag (it is not a patch tag).
def retention($tags; $runtime; $keep):
  ([.patches[]? | select(.runtime == $runtime) | .tag]) as $listed
  | [$tags[] | select(is_patch_tag)]
  | group_by(tag_version)
  | map(sort_by(tag_key) | reverse | .[$keep:])
  | add // []
  | map(select(. as $t | $listed | any(. == $t) | not))
  | sort_by(tag_key);

# the newest $keep patch tags of every floating tag among $tags that the feed does not list for
# $runtime: the patches the feed lacks (a publish whose feed update did not run)
def unlisted_patch_tags($tags; $runtime; $keep):
  ([.patches[]? | select(.runtime == $runtime) | .tag]) as $listed
  | newest_patch_tags($tags; $keep)
  | map(select(. as $t | $listed | any(. == $t) | not));

# a patch entry in the feed's key order, without empty optional fields
def normalize_entry:
  {id, runtime, version, tag, image, digest, level, reason, cves: (.cves // [])}
  + (if (.url // "") != "" then {url} else {} end)
  + {upstream, published_at}
  + (if (.deadline_at // "") != "" then {deadline_at} else {} end);

def normalize_platform:
  {version, level, reason}
  + (if (.url // "") != "" then {url} else {} end)
  + {published_at};

# the feed entry of a patch from the sh.runr.patch.* annotations of its image index (input: the
# index); nothing for an index without them
def entry_from_annotations($image; $digest):
  (.annotations // {}) as $a
  | select(($a["sh.runr.patch.id"] // "") != "" and ($a["sh.runr.patch.tag"] // "") != "")
  | {
      id: $a["sh.runr.patch.id"],
      runtime: $a["sh.runr.patch.runtime"],
      version: $a["sh.runr.patch.version"],
      tag: $a["sh.runr.patch.tag"],
      image: $image,
      digest: $digest,
      level: $a["sh.runr.patch.level"],
      reason: {en: $a["sh.runr.patch.reason.en"], tr: $a["sh.runr.patch.reason.tr"]},
      cves: (($a["sh.runr.patch.cves"] // "") | split(",") | map(select(length > 0))),
      url: $a["sh.runr.patch.url"],
      upstream: $a["sh.runr.patch.upstream"],
      published_at: $a["sh.runr.patch.published_at"],
      deadline_at: $a["sh.runr.patch.deadline_at"]
    }
  | normalize_entry;

# the sh.runr.patch.* annotations of a patch entry (input) and of the build ($build: the digest of
# the image index without them, $base: the base image with its digest), as buildx --annotation
# arguments for the image index
def patch_annotations($build; $base):
  {
    id, runtime, version, tag, level,
    "reason.en": .reason.en, "reason.tr": .reason.tr,
    cves: ((.cves // []) | join(",")),
    url, upstream, published_at, deadline_at,
    build: $build, base: $base
  }
  | to_entries[]
  | select(.value != null and .value != "")
  | "index:sh.runr.patch.\(.key)=\(.value)";

# an entry (input) after a patch request $q for its image found it unchanged: the request's level
# when it is not lower (with its reason and advisory), every CVE of both, the earlier deadline
def promote($q):
  (if ($q.level | level_rank) >= (.level | level_rank) then
     .level = $q.level
     | (if $q.reason != null then .reason = $q.reason else . end)
     | (if ($q.url // "") != "" then .url = $q.url else . end)
   else . end)
  | .cves = (((.cves // []) + ($q.cves // [])) | unique)
  | ([.deadline_at, $q.deadline_at] | map(select(. != null and . != ""))) as $d
  | if ($d | length) > 0 then .deadline_at = ($d | min) else . end;

# the next feed (input: the current one, {} for none):
#   $results   the patch results of the builds ({result: new|unchanged|planned, entry, request,
#              promote}): new and planned entries are added; an unchanged image's entry is added
#              when the feed lacks it and promoted (promote) when its request is above routine and
#              says so (promote: true, the operator's word that the image carries the fix)
#   $found     entries read from the registry's patch tags (the feed's entry of an id wins)
#   $platform  platform releases to add (one of the same version is replaced)
# then the newest $keep patches of every floating tag, newest first overall, and the newest $pkeep
# platform releases
def feed_merge($results; $found; $platform; $now; $keep; $pkeep):
  (.patches // []) as $old
  | ([$results[] | select(.result == "new" or .result == "planned" or .result == "unchanged") | .entry] + $found) as $add
  | (reduce $add[] as $e ($old; if any(.[]; .id == $e.id) then . else . + [$e] end)) as $merged
  | (reduce ($results[] | select(.result == "unchanged" and .promote == true and ((.request.level // "routine") | level_rank) > 0)) as $u
      ($merged; map(if .id == $u.entry.id then promote($u.request) else . end))) as $promoted
  | ($promoted
      | group_by([.runtime, .version])
      | map(sort_by(.tag | tag_key) | reverse | .[:$keep])
      | add // []
      | map(normalize_entry)
      | sort_by(.published_at, .id)
      | reverse) as $patches
  | ((.platform // []) as $p0
      | reduce $platform[] as $n ($p0; map(select(.version != $n.version)) + [$n])
      | sort_by(.published_at, .version)
      | reverse
      | .[:$pkeep]
      | map(normalize_platform)) as $releases
  | {schema: 1, generated_at: $now, patches: $patches, platform: $releases};

# what the schema cannot check (input: a feed), one message per problem
def feed_problems($keep; $pkeep):
  [ (.patches // [] | group_by(.id)[] | select(length > 1) | "duplicate patch id \(.[0].id)"),
    (.patches[]? | select(.id != "\(.runtime)-\(.version)-\(.tag)") | "patch \(.id): the id is not <runtime>-<version>-<tag> (\(.runtime)-\(.version)-\(.tag))"),
    (.patches[]? | select((.tag | tag_version) != .version) | "patch \(.id): \(.tag) is not a patch tag of \(.version)"),
    (.patches[]? | select(.runtime as $r | .image | endswith("/exec-" + $r) | not) | "patch \(.id): the image \(.image) is not exec-\(.runtime)"),
    (.patches[]? | select((.deadline_at // "") != "" and .deadline_at < .published_at) | "patch \(.id): deadline_at is before published_at"),
    (.patches // [] | group_by([.runtime, .version])[] | select(length > $keep) | "\(.[0].runtime) \(.[0].version): \(length) patches (at most \($keep))"),
    (.platform // [] | group_by(.version)[] | select(length > 1) | "duplicate platform release \(.[0].version)"),
    (if (.platform // [] | length) > $pkeep then "\(.platform | length) platform releases (at most \($pkeep))" else empty end)
  ];

# a short account of the changes between two feeds ($old: the current one; input: the next one)
def feed_changes($old):
  ([$old.patches[]? | {key: .id, value: .}] | from_entries) as $before
  | ([.patches[] | {key: .id, value: .}] | from_entries) as $after
  | [ (.patches[] | select($before[.id] == null) | "  + \(.id) \(.level) \(.digest)"),
      (.patches[] | select($before[.id] != null and ($before[.id] | del(.digest)) != (. | del(.digest))) | "  ~ \(.id) \($before[.id].level) → \(.level)"),
      ($old.patches[]? | select($after[.id] == null) | "  - \(.id) (beyond the newest of \(.runtime) \(.version))"),
      (.platform[] | select(. as $p | [$old.platform[]? | select(. == $p)] | length == 0) | "  + platform \(.version) \(.level)") ];
