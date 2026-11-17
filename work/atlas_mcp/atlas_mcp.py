"""Atlas over MCP: the asset catalog, answerable by a model.

Atlas is a Flutter desktop app over ~74,000 game assets. Its catalog is a
SQLite file; its FBX reader is a standalone executable. Neither needs the app
running, so this server talks to both directly and stays read-only against the
catalog -- Atlas owns that file, and a browsing tool has no business writing to
it. (The one thing worth writing, a rig_family backfill, lives in
backfill_rigs.py, which is run by hand with Atlas closed.)

Standard library only, deliberately. This is a personal tool on one machine,
and "pip install failed inside an MCP launch" is a worse failure than the
hundred lines of JSON-RPC it saves. MCP's stdio transport is newline-delimited
JSON-RPC 2.0, which is small enough to serve directly.

The search semantics mirror the app's on purpose: a question answered here and
a question answered in the Atlas window should not come back different.
See assetMatchesSearch and AssetItem.effectiveType in lib/main.dart.
"""

import base64
import io
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

SERVER_NAME = "atlas"
SERVER_VERSION = "1.0.0"

# Versions whose tool semantics this server implements identically. The reply
# echoes whichever the client asked for, since the differences between them do
# not reach a server this small.
KNOWN_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2024-11-05"

MAX_LIMIT = 200
DEFAULT_LIMIT = 40

# An image big enough to spend a large part of a context window on is better
# described than shown.
MAX_IMAGE_BYTES = 1_500_000

IMPORTER_TIMEOUT_SECONDS = 300


def log(message):
    """stdout belongs to the protocol; everything else goes to stderr."""
    print(message, file=sys.stderr, flush=True)


# --------------------------------------------------------------- locations


def _default_db_path():
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return None
    return os.path.join(
        appdata, "com.example", "asset_atlas_native", "asset_atlas_native.db")


def _default_importer_path():
    # Beside this file when the server is deployed on its own, else the
    # repository's release build.
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "asset_atlas_mesh_importer.exe"),
        os.path.join(
            here, os.pardir, "asset_atlas_native", "build", "windows", "x64",
            "runner", "Release", "asset_atlas_mesh_importer.exe"),
    ]
    for candidate in candidates:
        resolved = os.path.abspath(candidate)
        if os.path.exists(resolved):
            return resolved
    return None


def _default_bridge_path():
    """Where a running Atlas writes its port and token, beside the catalog."""
    if not DB_PATH:
        return None
    return os.path.join(os.path.dirname(DB_PATH), "atlas_bridge.json")


DB_PATH = os.environ.get("ATLAS_MCP_DB") or _default_db_path()
IMPORTER_PATH = os.environ.get("ATLAS_MCP_IMPORTER") or _default_importer_path()
CACHE_PATH = os.environ.get("ATLAS_MCP_CACHE") or os.path.join(
    os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(),
    "atlas-mcp", "summary-cache.json")
BRIDGE_PATH = os.environ.get("ATLAS_MCP_BRIDGE") or _default_bridge_path()

# Loading a 261,410-face mech takes twelve seconds, and the app may be busy.
BRIDGE_TIMEOUT_SECONDS = 300


class AtlasError(Exception):
    """Something the caller should be told about rather than a crash."""


# ------------------------------------------------------------------ bridge

ATLAS_NOT_RUNNING = (
    "Atlas is not running, so this tool cannot answer. It reads geometry "
    "through the app, which is where the texture resolution, the kit and "
    "sheet classification and the rig comparison actually live -- restating "
    "any of that here would be a second copy drifting out of step with the "
    "one Atlas uses. Open Atlas and try again. Every other tool here reads "
    "the catalog directly and works whether Atlas is open or not.")


def bridge_endpoint():
    """The port and token the running app wrote when it opened."""
    if not BRIDGE_PATH or not os.path.exists(BRIDGE_PATH):
        raise AtlasError(ATLAS_NOT_RUNNING)
    try:
        with io.open(BRIDGE_PATH, encoding="utf-8") as handle:
            info = json.load(handle)
        port = int(info["port"])
        token = str(info["token"])
    except (ValueError, KeyError, TypeError, OSError):
        raise AtlasError(ATLAS_NOT_RUNNING)
    return port, token


def bridge_call(route, payload=None, timeout=BRIDGE_TIMEOUT_SECONDS):
    """Asks the running app a question, as JSON over loopback."""
    port, token = bridge_endpoint()
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, route), data=body,
        headers={"X-Atlas-Token": token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        # The app turns a question it cannot answer into a sentence; pass it
        # through rather than reporting "HTTP 400".
        raw = error.read().decode("utf-8", "replace")
        try:
            message = (json.loads(raw) or {}).get("error") or raw
        except ValueError:
            message = raw
        raise AtlasError(message.strip() or "Atlas refused the request.")
    except urllib.error.URLError as error:
        # A descriptor left behind by a crash points at a dead port.
        raise AtlasError("%s\n(%s)" % (ATLAS_NOT_RUNNING, error.reason))
    except socket.timeout:
        raise AtlasError(
            "Atlas did not answer within %d seconds. A very large file can "
            "take that long to read; try again, or inspect a smaller one."
            % timeout)


def bridge_version():
    """The running app's version, or None when it is not running."""
    try:
        return bridge_call("/health", timeout=5).get("version")
    except AtlasError:
        return None


# ----------------------------------------------------------------- catalog


def open_catalog():
    if not DB_PATH or not os.path.exists(DB_PATH):
        raise AtlasError(
            "No Atlas catalog found at %s. Set ATLAS_MCP_DB to the "
            "asset_atlas_native.db you want to read." % (DB_PATH or "<unset>"))
    # Read-only, so a running Atlas is never at risk from this process.
    uri = "file:" + DB_PATH.replace(os.sep, "/").replace("?", "%3f") + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    return connection


_TEXTURE_FOLDER = re.compile(r"(^|[\\/])(textures?|materials?)([\\/]|$)", re.I)


def looks_like_texture_location(relative_path):
    """Mirrors looksLikeTextureLocation in lib/main.dart."""
    return bool(_TEXTURE_FOLDER.search((relative_path or "").replace("\\", "/")))


# A directory named for animation. Built from what is actually in the
# library rather than guessed: every FBX path containing "anim" was listed,
# and it comes to two real directories -- `Animations` (784 files) and
# `ANIMATION_Base_Locomotion_SourceFiles_v3.zip!` (721) -- against filenames
# like SM_Prop_Hunting_Animal_Head_01.fbx and Unity_SK_Animals_Dog_01.fbx.
#
# Hence both halves of the rule. Only directories are read, because every
# false positive in the library is a *filename*; and "animal" is excluded by
# requiring the whole word `anim`/`anims` or a prefix of `animation`, which
# an earlier version matching any segment starting "anim" got wrong on
# Props/Animal_Pen.fbx.
# `anim`/`anims` must be the whole segment; `animation` may be a prefix, so
# ANIMATION_Base_Locomotion_SourceFiles_v3.zip! counts. Without the $ on the
# first branch, "Animal" matches on its first four letters.
_ANIMATION_SEGMENT = re.compile(r"^(anims?$|animation)", re.I)

# Collision hulls ship beside the clips they belong to, and a hull is a mesh
# however it is filed. These were the only two misses in the sample.
_NOT_ANIMATION_SEGMENT = re.compile(r"^(collision|collider)", re.I)


def looks_like_animation(relative_path):
    """Whether a path says "clip", for a file nothing has probed yet.

    Mirrors looksLikeAnimation in lib/main.dart. A guess, and consulted only
    where there is no probed answer to prefer.
    """
    # [:-1] drops the filename: the directories are the evidence.
    folders = (relative_path or "").replace("\\", "/").split("/")[:-1]
    if any(_NOT_ANIMATION_SEGMENT.match(folder) for folder in folders):
        return False
    return any(_ANIMATION_SEGMENT.match(folder) for folder in folders)


def effective_type(row):
    """Mirrors AssetItem.effectiveType in lib/main.dart."""
    if row["model_kind"] == "animation":
        return "animation"
    # Only where the probe has not spoken: model_kind == 'mesh' is a real
    # answer and outranks any folder name.
    if (row["model_kind"] is None and row["type"] == "model"
            and looks_like_animation(row["relative_path"])):
        return "animation"
    if row["type"] == "image" and (
            row["referenced_by_model"] or
            looks_like_texture_location(row["relative_path"])):
        return "texture"
    return row["type"]


def container_of(row):
    """The pack a file belongs to: its zip, or its folder under a source root.

    Mirrors assetContainerKey, which is the one question in Atlas that is
    legitimately about location -- two files are in the same pack when they
    came out of the same archive.
    """
    path = row["path"] or ""
    if path.startswith("zip:") and "::" in path:
        container = path[4:].split("::", 1)[0]
        return os.path.basename(container)
    relative = (row["relative_path"] or "").replace("\\", "/")
    # relative_path is "<source name>/<rest>", so the pack folder is the next
    # segment -- unless there is nothing after it, in which case the file is
    # loose in the root and the root is all there is to name.
    parts = [p for p in relative.split("/") if p]
    if len(parts) > 2:
        return parts[1]
    return row["source_name"] or ""


# ------------------------------------------------------- packs and builds

# Synty ships one pack several times over: the source files, and a built
# project per engine version. The archive name is the only place that is
# recorded, so this is a deliberate exception to "nothing here reads a name" --
# the engine a build targets is not inside the files, and an AI assembling an
# Unreal project needs it before anything else.
_ARCHIVE_COPY = re.compile(r"\s*\(\d+\)$")
_ENGINE_VERSIONED = re.compile(
    r"[_ -](unreal|unity)[_ -]*(?:project[_ -]*)?(\d+)[._](\d+)", re.I)
_ENGINE_BARE = re.compile(r"[_ -](unreal|unity)(?=[_ -]|$)", re.I)
# A bare `4_22` with no engine word: every archive shaped like this in the
# reference library is an Unreal project export.
_BARE_ENGINE_VERSION = re.compile(r"[_ -](\d+)[._](\d+)(?=[_ -]|$)")
_SOURCE_BUILD = re.compile(r"[_ -]source[_ -]*(?:files?|sprites?)?", re.I)
_PACK_VERSION = re.compile(r"[_ -]v(\d+(?:[_.]\d+)*)\s*$", re.I)
# Synty's product lines. Stripped from the pack name so POLYGON_Town and
# PolygonTown are one pack.
PACK_FAMILIES = ("polygon", "interface", "animation", "simple", "sidekick")
_WORDS = re.compile(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+")

BUILD_KINDS = ("source", "unreal", "unity", "other")


def _split_words(text_value):
    """Words out of a name, splitting runCamelCase as well as separators."""
    words = []
    for chunk in re.split(r"[^A-Za-z0-9]+", text_value):
        if chunk:
            words.extend(_WORDS.findall(chunk) or [chunk])
    return words


def _singular(word):
    # Dungeon_Realms and Dungeons_Realms are the same pack; so are Dog and
    # Dogs. Only on words long enough that the trailing s is a plural.
    return word[:-1] if len(word) > 3 and word.lower().endswith("s") else word


def parse_archive_name(name):
    """Pack, product line, build kind and engine version out of an archive name.

    POLYGON_Shops_Unreal_5_4_v1_9_0.zip
        -> family polygon, pack "Shops", build unreal, engine 5.4, version 1_9_0

    `pack_key` is the grouping key: lowercased, camel-split and singularised,
    so POLYGON_Office_SourceFiles_v2 and PolygonOffice_SourceFiles land
    together. Near-miss names are left apart rather than fuzzily merged --
    "Explorer" and "Explorer Kit" stay two packs instead of a guess.
    """
    stem = name[:-4] if name.lower().endswith(".zip") else name
    stem = _ARCHIVE_COPY.sub("", stem)

    build, engine, cut = "other", None, len(stem)
    match = _ENGINE_VERSIONED.search(stem)
    if match:
        build, engine, cut = match.group(1).lower(), "%s.%s" % (
            match.group(2), match.group(3)), match.start()
    else:
        match = _SOURCE_BUILD.search(stem)
        if match:
            build, cut = "source", match.start()
        else:
            match = _ENGINE_BARE.search(stem)
            if match:
                build, cut = match.group(1).lower(), match.start()
            else:
                match = _BARE_ENGINE_VERSION.search(stem)
                if match:
                    build, engine, cut = "unreal", "%s.%s" % (
                        match.group(1), match.group(2)), match.start()

    version_match = _PACK_VERSION.search(stem)
    version = version_match.group(1) if version_match else None

    words = _split_words(stem[:cut])
    family = ""
    if words and words[0].lower() in PACK_FAMILIES:
        family = words[0].lower()
        words = words[1:]
    pack = " ".join(words)
    pack_key = " ".join(_singular(word) for word in words).lower()
    return {
        "family": family,
        "pack": pack,
        "pack_key": pack_key,
        "build": build,
        "engine": engine,
        "version": version,
        "archive": name,
    }


def archive_of(row):
    """The archive a row came out of, or '' for a loose file."""
    path = row["path"] or ""
    if path.startswith("zip:") and "::" in path:
        return os.path.basename(path[4:].split("::", 1)[0])
    return ""


def build_of(row):
    """parse_archive_name for the row's archive; None for a loose file."""
    archive = archive_of(row)
    return parse_archive_name(archive) if archive else None


def describe_build(info):
    """'unreal 5.4 (v1_9_0)' -- how one build of a pack reads in a listing."""
    if info is None:
        return "loose files"
    bits = [info["build"]]
    if info["engine"]:
        bits.append(info["engine"])
    label = " ".join(bits)
    if info["version"]:
        label += " (v%s)" % info["version"]
    return label


# tags_json is stored as a JSON array, so matching it raw lets a term hit the
# punctuation between tags -- '","' sits in every multi-tag row, and a search
# for it returned 40,000 files. Unwrapping it to space-separated words is also
# what makes this agree with the app, where the same text is tags.join(' ').
# Both spacings, because the separator an encoder picks is not something to
# depend on: Dart's jsonEncode writes '","' and Python's json.dumps writes
# '", "', and a search that silently changed meaning with the writer would be
# very hard to notice. json_each would cover every encoding exactly and cost
# 708 ms more per search on this library (1,241 ms against 533 ms for the same
# 609 hits), so the exact path is kept for the sieve -- see tags_words -- and
# TagsSqlTest holds the two to the same answer.
_TAGS_SQL = (
    "replace(replace(replace(replace(replace("
    "lower(coalesce(tags_json, '[]')), "
    "'\", \"', ' '), '\",\"', ' '), '[\"', ''), '\"]', ''), '[]', '')")

# The search text Atlas builds per asset: name, path and tags, lowercased,
# with separators so a term cannot straddle two fields.
_SEARCH_SQL = (
    "(lower(name) || char(10) || lower(relative_path) || char(10) || "
    + _TAGS_SQL + ")")


# --- The filter grammar, shared with the app -----------------------------
#
# `tag=grungy name=door` scopes each term to one field; a plain word still
# searches name, path and tags together. Spaces mean and, `or` groups the
# terms either side of it, and there are no parentheses -- so `a or b c` is
# (a or b) and c, which is how it reads aloud.
#
# fixtures/search_queries.json holds the cases this and assetMatchesQuery in
# lib/main.dart are both tested against, so neither can drift from the other.

# 'any' is the field a plain word gets. It is deliberately not spellable:
# any=dog is a typo, and saying so is more use than accepting it.
QUERY_FIELDS = ("any", "name", "path", "tag", "type", "ext", "rig")
QUERY_NAMED_FIELDS = tuple(f for f in QUERY_FIELDS if f != "any")

# Fields holding one value out of a fixed set, where a substring would
# mislead: type=mod must not quietly mean every model.
QUERY_EXACT_FIELDS = frozenset(["type", "ext", "rig"])

# Recognised only so the refusal can say what it is waiting for. A field that
# will exist deserves a different answer from one that never will.
QUERY_RESERVED_FIELDS = {
    "look": (
        "look= is reserved for visual search -- finding assets that look "
        "grungy or gray rather than ones named that. Ask find_similar "
        "instead: ranking by appearance needs a cutoff to become a filter, "
        "and a ranked list is the more useful answer. It reads the vectors "
        "the tagging pass writes (tag_assets.py)."),
}

# The effective-type vocabulary, which is what type= matches. 'image' and
# 'texture' turn on a regex over the path that SQL cannot express, so a query
# naming any type is sieved in Python afterwards by effective_type.
QUERY_TYPE_VALUES = ("model", "animation", "image", "texture", "audio",
                     "unreal", "other")

# SQL keeping every row whose effective type could be this, and pruning the
# rest. Permissive on purpose: the sieve is what decides.
_NOT_A_CLIP = "(model_kind IS NULL OR model_kind != 'animation')"

_TYPE_PREFILTER = {
    # Permissive for both: a guessed clip is a model row, so each has to
    # keep the other's rows and let the sieve separate them. Without that
    # the two filters overlap and their totals exceed the library.
    "model": "type = 'model'",
    "animation": "model_kind = 'animation' OR (model_kind IS NULL "
                 "AND type = 'model')",
    "image": "type = 'image' AND " + _NOT_A_CLIP,
    "texture": "type = 'image' AND " + _NOT_A_CLIP,
    "audio": "type = 'audio' AND " + _NOT_A_CLIP,
    "unreal": "type = 'unreal' AND " + _NOT_A_CLIP,
    "other": "type = 'other' AND " + _NOT_A_CLIP,
}

# The two whose prefilter is only a prefilter: whether an image is a texture
# turns on referenced_by_model or a regex over the path, and SQL has neither.
# Every other value above is exact, which is worth the distinction -- sieving
# the 108,080 rows of type=unreal cost 1,177 ms to confirm a number SQL had
# already counted correctly.
_TYPE_NEEDS_SIEVE = frozenset(["image", "texture", "animation", "model"])

_QUOTE_CHARS = "'" + '"'


class QueryError(AtlasError):
    """A search the person can fix, quoted back rather than guessed at."""


def _scan_query(text):
    """Split a query into tokens, keeping quoted runs whole.

    A token is a list of (chunk, came_from_quote). Remembering where every
    character came from is the whole point: `"name=dog"` and `name="dog"`
    produce the same letters and mean different things, and only the position
    of the quotes separates them.
    """
    tokens = []
    index = 0
    length = len(text)
    while index < length:
        if text[index].isspace():
            index += 1
            continue
        segments = []
        while index < length and not text[index].isspace():
            quote = text[index]
            if quote in _QUOTE_CHARS:
                index += 1
                start = index
                while index < length and text[index] != quote:
                    index += 1
                if index >= length:
                    raise QueryError(
                        "Unclosed quote in the search. Close it, or drop both "
                        "quotes.")
                segments.append((text[start:index], True))
                index += 1
            else:
                start = index
                while (index < length and not text[index].isspace()
                       and text[index] not in _QUOTE_CHARS):
                    index += 1
                segments.append((text[start:index], False))
        tokens.append(segments)
    return tokens


def _split_field(segments):
    """(field, value), or (None, whole) when no unquoted = splits the token."""
    before = []
    for position, (chunk, from_quote) in enumerate(segments):
        if not from_quote and "=" in chunk:
            head, _, tail = chunk.partition("=")
            rest = [tail] + [piece for piece, _ in segments[position + 1:]]
            return "".join(before) + head, "".join(rest)
        before.append(chunk)
    return None, "".join(before)


def _query_term(field, value):
    """One normalised (field, value), or a QueryError saying why not."""
    if field is None:
        field = "any"
    else:
        field = field.strip().lower()
        if not field:
            raise QueryError(
                "A search term cannot start with `=`. Write field=value, or a "
                "plain word to search everything.")
        if field in QUERY_RESERVED_FIELDS:
            raise QueryError(QUERY_RESERVED_FIELDS[field])
        if field not in QUERY_NAMED_FIELDS:
            raise QueryError(
                "Unknown search field %r. Use one of: %s -- or a plain word, "
                "which searches name, path and tags together."
                % (field, ", ".join(QUERY_NAMED_FIELDS)))

    value = value.strip().lower()
    if field == "ext":
        value = value.lstrip(".")
    elif field == "path":
        value = value.replace(chr(92), "/")
    if not value:
        raise QueryError(
            "%s= has no value, so it would match everything. Give it one, or "
            "remove it." % field)
    if field == "type" and value not in QUERY_TYPE_VALUES:
        raise QueryError(
            "Unknown type %r in type=. Use one of: %s."
            % (value, ", ".join(QUERY_TYPE_VALUES)))
    return (field, value)


def parse_asset_query(text):
    """The filter grammar: clauses ANDed, terms inside one clause ORed.

    Returns [[(field, value), ...], ...]. An empty query is no constraint,
    which is a reasonable thing to ask for and not an error.
    """
    clauses = []
    pending_or = False
    for segments in _scan_query(text or ""):
        field, value = _split_field(segments)
        quoted = any(from_quote for _, from_quote in segments)
        word = value.strip().lower()

        # `and` is a noise word, kept for people who type what they mean.
        # Quoting escapes both, so "or" is a searchable term.
        if field is None and not quoted and word in ("and", "or"):
            if pending_or or (word == "or" and not clauses):
                raise QueryError(
                    "`or` needs a search term either side of it.")
            pending_or = word == "or"
            continue

        term = _query_term(field, value)
        if pending_or:
            clauses[-1].append(term)
            pending_or = False
        else:
            clauses.append([term])

    if pending_or:
        raise QueryError("`or` needs a search term either side of it.")
    return clauses


_FIELD_SQL = {
    "any": _SEARCH_SQL + " LIKE ?",
    "name": "lower(name) LIKE ?",
    "path": "lower(relative_path) LIKE ?",
    "tag": _TAGS_SQL + " LIKE ?",
    "ext": "ext = ?",
    "rig": "lower(coalesce(rig_family, '')) = ?",
}


def query_sql(clauses):
    """(sql, params) for a parsed query: exact, unless type= appears.

    A type term contributes a prefilter that cannot exclude a real match, so
    the SQL is safe to use alone for any query without one.
    """
    sql = []
    params = []
    for clause in clauses:
        parts = []
        for field, value in clause:
            if field == "type":
                parts.append("(%s)" % _TYPE_PREFILTER[value])
            elif field in QUERY_EXACT_FIELDS:
                parts.append(_FIELD_SQL[field])
                params.append(value)
            else:
                parts.append(_FIELD_SQL[field])
                params.append("%" + value + "%")
        sql.append("(%s)" % " OR ".join(parts))
    return " AND ".join(sql), params


def query_needs_sieve(clauses):
    """Whether SQL settled it, or effective_type still has to be consulted."""
    return any(field == "type" and value in _TYPE_NEEDS_SIEVE
               for clause in clauses for field, value in clause)


def tags_words(blob):
    """A row's tags as one space-separated string, by parsing rather than
    pattern-matching. _TAGS_SQL is the fast approximation of this."""
    try:
        tags = json.loads(blob or "[]")
    except ValueError:
        return ""
    if not isinstance(tags, list):
        return ""
    return " ".join(str(tag) for tag in tags).lower()


def row_search_values(row):
    """The text a query sees for one row. Mirrors AssetItem's own getters.

    The 'any' separator is a newline here and a NUL in the app. Neither can
    occur in a name, a path or a tag, so the only property that matters --
    that a term cannot straddle two fields -- holds either way.
    """
    name = (row["name"] or "").lower()
    path = (row["relative_path"] or "").lower()
    joined = tags_words(row["tags_json"])
    return {
        "any": name + chr(10) + path + chr(10) + joined,
        "name": name,
        "path": path,
        "tag": joined,
        "type": effective_type(row) or "",
        "ext": (row["ext"] or "").lower(),
        "rig": (row["rig_family"] or "").lower(),
    }


def query_matches(clauses, values):
    """Mirrors assetMatchesQuery in lib/main.dart."""
    for clause in clauses:
        for field, value in clause:
            actual = values.get(field, "")
            hit = (actual == value if field in QUERY_EXACT_FIELDS
                   else value in actual)
            if hit:
                break
        else:
            return False
    return True


def sieve_fetch(limit, kind, sieve):
    """How many rows to ask SQL for, when some will be dropped afterwards."""
    if kind in SIEVED_KINDS or sieve:
        return max(limit * 4, 200)
    return limit

TYPE_FILTERS = {
    "all": None,
    "model": "type = 'model' AND (model_kind IS NULL OR model_kind != 'animation')",
    "mesh": "model_kind = 'mesh'",
    # A prefilter now, not an answer: an unprobed clip is a plain model row
    # and only its path gives it away. 'mesh' above stays strict on purpose,
    # because "probed, and found to hold geometry" is a different claim from
    # "not a clip".
    "animation": "model_kind = 'animation' OR (model_kind IS NULL "
                 "AND type = 'model')",
    "character": "model_kind = 'mesh' AND rig_family IS NOT NULL AND rig_family != 'none'",
    "image": "type = 'image'",
    "audio": "type = 'audio'",
    "unreal": "type = 'unreal'",
    # Resolved in Python, because it depends on a regex over the path.
    "texture": "type = 'image'",
}


SIEVED_KINDS = frozenset(["texture", "animation", "model"])


def build_query(arguments):
    """The WHERE clause and parameters shared by search and count."""
    clauses = ["ignored = 0"]
    params = []

    kind = (arguments.get("type") or "all").lower()
    if kind not in TYPE_FILTERS:
        raise AtlasError(
            "Unknown type %r. Use one of: %s."
            % (kind, ", ".join(sorted(TYPE_FILTERS))))
    if TYPE_FILTERS[kind]:
        clauses.append("(%s)" % TYPE_FILTERS[kind])

    parsed = parse_asset_query(arguments.get("query"))
    if parsed:
        query_where, query_params = query_sql(parsed)
        clauses.append(query_where)
        params.extend(query_params)

    for field, column in (("pack", "relative_path"), ("folder", "relative_path")):
        value = (arguments.get(field) or "").strip().lower()
        if value:
            clauses.append("lower(%s) LIKE ?" % column)
            params.append("%" + value.replace("\\", "/") + "%")

    ext = (arguments.get("ext") or "").strip().lower().lstrip(".")
    if ext:
        clauses.append("ext = ?")
        params.append(ext)

    # type= rides on effective_type, which needs a regex over the path, so
    # the SQL above only pruned and this is what decides. None means SQL
    # settled it, which is every query that does not name a type.
    sieve = parsed if query_needs_sieve(parsed) else None
    return " AND ".join(clauses), params, kind, sieve


# Everything a query can look at. Narrower than SELECT * because the count
# below reads one row per match and never needs the rest.
_SIEVE_COLUMNS = ("name, relative_path, tags_json, type, ext, rig_family, "
                  "model_kind, referenced_by_model")


def needs_exact_total(kind, sieve):
    """Whether count(*) over the WHERE clause is the real answer."""
    return kind in SIEVED_KINDS or sieve is not None


def sieve_total(connection, where, params, kind, sieve, grouped=False):
    """The true number of matches when SQL could only prune.

    count(*) over a prefiltered WHERE clause is not the answer: it said
    39,123 for type=texture where 4,205 match. Reached only for image and
    texture, and it costs one pass over the prefiltered rows -- 560 ms for
    type=texture on this library, against 39,123 rows.
    """
    sql = "SELECT %s FROM catalog_assets WHERE %s" % (_SIEVE_COLUMNS, where)
    if grouped:
        # One row per duplicate group, matching how the rows were selected.
        sql += " GROUP BY lower(name), size"
    total = 0
    for row in connection.execute(sql, params):
        if kind in SIEVED_KINDS and effective_type(row) != kind:
            continue
        if sieve and not query_matches(sieve, row_search_values(row)):
            continue
        total += 1
    return total


def sieve_rows(rows, kind, sieve):
    """Drop the rows SQL could not judge: a sieved kind, and any type=."""
    if kind in SIEVED_KINDS:
        rows = [row for row in rows if effective_type(row) == kind]
    if sieve:
        rows = [row for row in rows
                if query_matches(sieve, row_search_values(row))]
    return rows


MAX_EXPORT_FILES = 5000
DEFAULT_EXPORT_FILES = 500
# A pack's built Content folder is a few hundred megabytes; this is the point
# at which an export is more likely a mistake than a request.
MAX_EXPORT_BYTES = 2 * 1024 * 1024 * 1024


def catalog_archives(connection):
    """Every archive the catalog holds, as {full container path: parsed name}."""
    rows = connection.execute(
        "SELECT DISTINCT substr(path, 5, instr(path, '::') - 5) AS container "
        "FROM catalog_assets WHERE path LIKE 'zip:%' AND instr(path, '::') > 0"
    ).fetchall()
    found = {}
    for row in rows:
        container = row["container"]
        if container:
            found[container] = parse_archive_name(os.path.basename(container))
    return found


def archive_clause(connection, arguments):
    """A WHERE fragment restricting to archives whose build matches.

    The engine version lives in the archive name and nowhere else, so this
    resolves the filter to the archives it means and matches on those -- a LIKE
    over the path would have to guess at Unreal_5_4 against Unreal_Project_4_22
    against a bare 4_22, and would quietly miss builds.
    """
    engine = (arguments.get("engine") or "").strip().lower()
    build = (arguments.get("build") or "").strip().lower()
    if not engine and not build:
        return None, []
    if build and build not in BUILD_KINDS:
        raise AtlasError(
            "Unknown build %r. Use one of: %s." % (build, ", ".join(BUILD_KINDS)))

    wanted = []
    for container, info in catalog_archives(connection).items():
        if build and info["build"] != build:
            continue
        if engine and (info["engine"] or "") != engine:
            continue
        wanted.append(container)
    if not wanted:
        known = sorted({
            info["engine"] for info in catalog_archives(connection).values()
            if info["engine"]})
        raise AtlasError(
            "No archive in the catalog is a %s build%s. Engine versions "
            "present: %s." % (build or "matching", " for engine " + engine
                              if engine else "", ", ".join(known) or "none"))
    clause = "(%s)" % " OR ".join(["path LIKE ?"] * len(wanted))
    return clause, ["zip:" + container + "::%" for container in wanted]


def grouped_rows_for(connection, arguments, limit, offset):
    """Search results with identical copies collapsed to one row.

    Half this library is the same file several times over: packs are
    re-released and re-exported per engine version, so 13,719 of 27,652 FBX
    rows share a name and a byte size with another row. Left alone, a search
    for a door returns the same door six times and a limit of 40 is really a
    limit of 20. Grouping is on name and size -- two files that agree on both
    are the same file in practice -- and the surviving row says how many
    copies there are and where the others live.
    """
    where, params, kind, sieve = build_query(arguments)
    extra, extra_params = archive_clause(connection, arguments)
    if extra:
        where += " AND " + extra
        params = params + extra_params

    fetch = sieve_fetch(limit, kind, sieve)
    groups = connection.execute(
        "SELECT min(path) AS rep, count(*) AS copies FROM catalog_assets "
        "WHERE %s GROUP BY lower(name), size ORDER BY min(name) LIMIT ? OFFSET ?"
        % where, params + [fetch, offset]).fetchall()
    if needs_exact_total(kind, sieve):
        total = sieve_total(connection, where, params, kind, sieve,
                            grouped=True)
    else:
        total = connection.execute(
            "SELECT count(*) FROM (SELECT 1 FROM catalog_assets WHERE %s "
            "GROUP BY lower(name), size)" % where, params).fetchone()[0]

    copies = {row["rep"]: row["copies"] for row in groups}
    if not copies:
        return [], total, kind, {}
    placeholders = ", ".join(["?"] * len(copies))
    rows = connection.execute(
        "SELECT * FROM catalog_assets WHERE path IN (%s)" % placeholders,
        list(copies)).fetchall()
    rows = sieve_rows(rows, kind, sieve)
    rows = sorted(rows, key=lambda row: (row["name"] or "").lower())[:limit]

    # Where the other copies live, for the rows actually being shown.
    elsewhere = {}
    duplicated = [row for row in rows if copies.get(row["path"], 1) > 1]
    if duplicated:
        pairs = " OR ".join(["(lower(name) = ? AND size = ?)"] * len(duplicated))
        args = []
        for row in duplicated:
            args.extend([(row["name"] or "").lower(), row["size"]])
        for other in connection.execute(
                "SELECT name, size, path, relative_path, source_name "
                "FROM catalog_assets WHERE %s" % pairs, args).fetchall():
            key = ((other["name"] or "").lower(), other["size"])
            elsewhere.setdefault(key, set()).add(container_of(other))
    return rows, total, kind, {"copies": copies, "elsewhere": elsewhere}


def rows_for(connection, arguments, limit, offset):
    where, params, kind, sieve = build_query(arguments)
    # The texture filter and type= need the path regex, so over-fetch.
    fetch = sieve_fetch(limit, kind, sieve)
    sql = ("SELECT * FROM catalog_assets WHERE %s ORDER BY name LIMIT ? OFFSET ?"
           % where)
    rows = connection.execute(sql, params + [fetch, offset]).fetchall()
    rows = sieve_rows(rows, kind, sieve)[:limit]
    total = (sieve_total(connection, where, params, kind, sieve)
             if needs_exact_total(kind, sieve) else connection.execute(
                 "SELECT count(*) FROM catalog_assets WHERE %s" % where,
                 params).fetchone()[0])
    return rows, total, kind


# ------------------------------------------------------------------ files


def parse_zip_path(path):
    """`zip:<archive>::<entry>` as a pair, or None for a file on disk."""
    if not path.startswith("zip:") or "::" not in path:
        return None
    container, entry = path[4:].split("::", 1)
    return container, entry


def read_asset_bytes(path):
    parsed = parse_zip_path(path)
    if parsed is None:
        if not os.path.exists(path):
            raise AtlasError("File not found on disk: %s" % path)
        with open(path, "rb") as handle:
            return handle.read()
    container, entry = parsed
    if not os.path.exists(container):
        raise AtlasError("Archive not found: %s" % container)
    try:
        with zipfile.ZipFile(container) as archive:
            return archive.read(entry)
    except KeyError:
        raise AtlasError("No entry %s inside %s" % (entry, container))


def asset_fingerprint(path):
    """Enough to know a cached answer is still about this file."""
    parsed = parse_zip_path(path)
    try:
        if parsed is None:
            stat = os.stat(path)
            return "%d:%d" % (stat.st_size, int(stat.st_mtime))
        container, entry = parsed
        with zipfile.ZipFile(container) as archive:
            info = archive.getinfo(entry)
            return "%d:%s" % (info.file_size, info.date_time)
    except (OSError, KeyError, zipfile.BadZipFile):
        return None


# ---------------------------------------------------------------- probing


_cache = None


def load_cache():
    global _cache
    if _cache is not None:
        return _cache
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as handle:
            _cache = json.load(handle)
    except (OSError, ValueError):
        _cache = {}
    return _cache


def save_cache():
    if _cache is None:
        return
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        temporary = CACHE_PATH + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(_cache, handle)
        os.replace(temporary, CACHE_PATH)
    except OSError as error:
        log("could not write cache: %s" % error)


def summarise(path, mode="summary"):
    """What the FBX reader says about a file, cached by size and timestamp.

    Reading a large FBX is not cheap -- the 261,410-face Polygon mech takes
    twelve seconds -- and the answer only changes when the file does.
    """
    if not IMPORTER_PATH or not os.path.exists(IMPORTER_PATH):
        raise AtlasError(
            "The Atlas FBX reader was not found. Build it, or set "
            "ATLAS_MCP_IMPORTER to asset_atlas_mesh_importer.exe.")

    fingerprint = asset_fingerprint(path)
    cache = load_cache()
    key = "%s|%s|%s" % (mode, path, fingerprint)
    if fingerprint and key in cache:
        return cache[key]

    flag = "--summary" if mode == "summary" else "--probe"
    data = read_asset_bytes(path)
    try:
        completed = subprocess.run(
            [IMPORTER_PATH, "--stdin", flag, os.path.basename(path)],
            input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=IMPORTER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise AtlasError("The FBX reader timed out on %s." % path)
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise AtlasError("The FBX reader could not read %s: %s" % (path, detail))
    try:
        result = json.loads(completed.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise AtlasError("The FBX reader returned something unreadable for %s." % path)

    if fingerprint:
        cache[key] = result
        save_cache()
    return result


# The rig families Atlas recognises, by the marker bones the reader reports.
# Mirrors rigFamilyFromMarkers in lib/main.dart: the bones are unambiguous
# where the file names are not.
def rig_family_from_markers(markers):
    markers = set(markers or ())
    if markers & {"hipAttachFront", "hipAttach_l", "ik_hand_gun", "ik_hand_root"}:
        return "sidekick"
    if markers & {"Hips", "UpperLeg_R", "Clavicle_L", "Spine_01"}:
        return "polygon"
    if markers & {"pelvis", "thigh_l", "clavicle_l", "spine_01"}:
        return "unreal"
    return "none"


# ------------------------------------------------------------ attachments

# Mirrors the attachPoints table in lib/main.dart, which is the source of
# truth. test_atlas_mcp.py reads that table back out of the Dart and fails if
# the two drift apart.
ATTACH_POINTS = [
    ("Face", ["beard", "moustache", "mustache", "goatee", "sideburn",
              "faceplate", "gasmask", "facemask", "glasses", "eyepatch",
              "monocle", "mask", "jaw", "teeth", "tusk"]),
    ("Head", ["helmet", "helm", "hat", "hood", "crown", "tiara", "circlet",
              "headband", "bandana", "hair", "wig", "horn", "antler", "ear",
              "head"]),
    ("Back", ["cape", "cloak", "backpack", "rucksack", "quiver", "scabbard",
              "sheath", "banner", "wing", "jetpack", "gasbag", "back"]),
    ("Shoulder", ["shoulder", "pauldron", "epaulette", "epaulet", "spaulder"]),
    ("Elbow", ["elbow", "bracer", "vambrace"]),
    ("Knee", ["knee", "greave", "kneepad"]),
    ("Hip", ["belt", "holster", "pouch", "skirt", "tail", "hip", "waist"]),
    ("Hand", ["sword", "axe", "shield", "staff", "wand", "bow", "gun", "rifle",
              "pistol", "torch", "lantern", "hammer", "spear", "weapon"]),
]


def attach_point_for(name):
    """Which body part a name claims, by whole token.

    Whole tokens because substrings lie: `cape` contains `cap`, and matching
    loosely once put every cloak in the library on a character's head.
    """
    tokens = set(t for t in re.split(r"[^a-z0-9]+", name.lower()) if t)
    for point, keywords in ATTACH_POINTS:
        if tokens & set(keywords):
            return point
    return None


# ------------------------------------------------------------- formatting


def format_bytes(size):
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            decimals = 0 if unit == "B" or value >= 100 else 1
            return "%.*f %s" % (decimals, value, unit)
        value /= 1024
    return "%d B" % size


def format_bounds(bounds):
    """The reader's [minX, minY, minZ, maxX, maxY, maxZ] as two readable lines.

    Printed in the order it arrives, the pairs interleave and every range
    reads backwards -- which is exactly how it was first written.
    """
    low_x, low_y, low_z, high_x, high_y, high_z = bounds
    return [
        "bounds        x %.3g..%.3g  y %.3g..%.3g  z %.3g..%.3g"
        % (low_x, high_x, low_y, high_y, low_z, high_z),
        "size          %.3g x %.3g x %.3g units"
        % (high_x - low_x, high_y - low_y, high_z - low_z),
    ]


def describe_row(row, index=None):
    bits = [row["name"], container_of(row), effective_type(row)]
    if row["model_kind"] and row["model_kind"] != effective_type(row):
        bits.append(row["model_kind"])
    if row["rig_family"] and row["rig_family"] != "none":
        bits.append("rig:" + row["rig_family"])
    bits.append(format_bytes(row["size"]))
    prefix = "" if index is None else "%3d. " % index
    return "%s%s\n     %s" % (prefix, "  ".join(bits), row["path"])


def text(body):
    return {"content": [{"type": "text", "text": body}]}


# ----------------------------------------------------------------- tools


def tool_search_assets(arguments):
    limit = min(int(arguments.get("limit") or DEFAULT_LIMIT), MAX_LIMIT)
    offset = max(int(arguments.get("offset") or 0), 0)
    distinct = arguments.get("distinct")
    distinct = True if distinct is None else bool(distinct)

    with open_catalog() as connection:
        if distinct:
            rows, total, kind, dupes = grouped_rows_for(
                connection, arguments, limit, offset)
        else:
            where, params, kind, sieve = build_query(arguments)
            extra, extra_params = archive_clause(connection, arguments)
            if extra:
                where += " AND " + extra
                params = params + extra_params
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE %s ORDER BY name "
                "LIMIT ? OFFSET ?" % where,
                params + [limit, offset]).fetchall()
            rows = sieve_rows(rows, kind, sieve)
            total = (sieve_total(connection, where, params, kind, sieve)
                     if needs_exact_total(kind, sieve)
                     else connection.execute(
                         "SELECT count(*) FROM catalog_assets WHERE %s"
                         % where, params).fetchone()[0])
            dupes = {}

    if not rows:
        hint = ""
        if kind == "character" and total == 0:
            hint = ("\n\nNote: the character filter reads the catalog's "
                    "rig_family column, which is populated lazily as Atlas "
                    "browses and is mostly empty right now. Run "
                    "backfill_rigs.py with Atlas closed to fill it, or ask "
                    "for type=mesh and inspect candidates individually.")
        return text("No assets matched.%s" % hint)

    copies = dupes.get("copies") or {}
    elsewhere = dupes.get("elsewhere") or {}
    blocks = []
    for index, row in enumerate(rows):
        block = describe_row(row, offset + index + 1)
        count = copies.get(row["path"], 1)
        if count > 1:
            block = block.replace("\n", "   x%d copies\n" % count, 1)
            others = sorted(
                elsewhere.get(((row["name"] or "").lower(), row["size"]), set())
                - {container_of(row)})
            if others:
                shown_others = ", ".join(others[:4])
                if len(others) > 4:
                    shown_others += ", +%d more" % (len(others) - 4)
                block += "\n     also in: " + shown_others
        blocks.append(block)

    header = "%d matches." % total
    if distinct:
        header = ("%d distinct files (identical copies collapsed; pass "
                  "distinct=false for every row)." % total)
    more = ""
    if total > offset + len(rows):
        more = ("\n\n%d of %d shown. Ask again with offset=%d for more."
                % (offset + len(rows), total, offset + len(rows)))
    return text("%s\n\n%s%s" % (header, "\n".join(blocks), more))


def _find_row(connection, needle):
    """One asset, by exact path, by id, or by an unambiguous name."""
    needle = (needle or "").strip()
    if not needle:
        raise AtlasError("Give a path, an id, or a file name.")
    for sql, value in (
            ("SELECT * FROM catalog_assets WHERE path = ?", needle),
            ("SELECT * FROM catalog_assets WHERE id = ?", needle.lower()),
            ("SELECT * FROM catalog_assets WHERE lower(name) = ?", needle.lower())):
        rows = connection.execute(sql, (value,)).fetchall()
        if len(rows) == 1:
            return rows[0]
        if len(rows) > 1:
            listed = "\n".join(describe_row(r, i + 1) for i, r in enumerate(rows[:12]))
            raise AtlasError(
                "%d assets are called that. Ask again with one of these "
                "paths:\n\n%s" % (len(rows), listed))
    raise AtlasError("Nothing in the catalog matches %r." % needle)


def tool_get_asset(arguments):
    inspect = (arguments.get("inspect") or "summary").lower()
    with open_catalog() as connection:
        row = _find_row(connection, arguments.get("path"))
        neighbours = connection.execute(
            "SELECT name, path, size FROM catalog_assets "
            "WHERE type = 'image' AND relative_path LIKE ? ORDER BY name LIMIT 12",
            ("%" + os.path.dirname(
                (row["relative_path"] or "").replace("\\", "/")).lower() + "%",)
        ).fetchall()

    lines = [
        "%s" % row["name"],
        "path      %s" % row["path"],
        "pack      %s" % container_of(row),
        "source    %s  (%s)" % (row["source_name"], row["source_root"]),
        "type      %s" % effective_type(row),
        "size      %s" % format_bytes(row["size"]),
        "tags      %s" % ", ".join(json.loads(row["tags_json"] or "[]")),
    ]
    if row["model_kind"]:
        lines.append("kind      %s  (from the FBX reader)" % row["model_kind"])
    if row["rig_family"]:
        lines.append("rig       %s" % row["rig_family"])

    if inspect != "none" and row["ext"] in ("fbx",):
        try:
            data = summarise(row["path"], "summary")
        except AtlasError as error:
            lines.append("")
            lines.append("Could not read the file: %s" % error)
        else:
            lines.append("")
            lines.append("-- read from the file itself --")
            lines.append("kind          %s" % data.get("kind"))
            if data.get("faces"):
                lines.append("geometry      %s faces, %s vertices, %s nodes, %s materials"
                             % (data.get("faces"), data.get("vertices"),
                                data.get("objects"), data.get("materials")))
            bounds = data.get("bounds")
            if bounds:
                lines.extend(format_bounds(bounds))
            unit = data.get("unitMeters")
            if unit:
                lines.append("file units    %g m per unit" % unit)
            markers = data.get("rigMarkers") or []
            family = rig_family_from_markers(markers)
            if data.get("bones"):
                lines.append("rig           %s, %d bones" % (family, data["bones"]))
            if data.get("animationStacks"):
                lines.append("animation     %d stack(s), %.3g s: %s"
                             % (data["animationStacks"],
                                data.get("durationSeconds") or 0,
                                ", ".join(data.get("animationNames") or [])))
            names = data.get("materialNames") or []
            if names:
                lines.append("materials     %s" % ", ".join(names[:12]))
            textures = data.get("textureFiles") or []
            if textures:
                lines.append("asks for      %s" % "\n              ".join(textures[:6]))
            if inspect == "full":
                objects = data.get("objectNames") or []
                if objects:
                    lines.append("nodes         %s" % ", ".join(objects[:120]))
                    if len(objects) > 120:
                        lines.append("              ... and %d more" % (len(objects) - 120))
                bones = data.get("boneNames") or []
                if bones:
                    lines.append("bones         %s" % ", ".join(bones[:120]))

    if neighbours:
        lines.append("")
        lines.append("-- images beside it (what it would be textured with) --")
        for image in neighbours:
            lines.append("  %-44s %10s  %s"
                         % (image["name"], format_bytes(image["size"]), image["path"]))

    return text("\n".join(lines))


def tool_list_packs(arguments):
    query = (arguments.get("query") or "").strip().lower()
    with open_catalog() as connection:
        rows = connection.execute(
            "SELECT path, relative_path, source_name, type, model_kind, "
            "referenced_by_model FROM catalog_assets WHERE ignored = 0").fetchall()

    packs = {}
    for row in rows:
        name = container_of(row)
        if query and query not in name.lower():
            continue
        bucket = packs.setdefault(
            name, {"files": 0, "mesh": 0, "animation": 0, "texture": 0,
                   "unreal": 0, "source": row["source_name"]})
        bucket["files"] += 1
        if row["model_kind"] == "mesh":
            bucket["mesh"] += 1
        elif row["model_kind"] == "animation":
            bucket["animation"] += 1
        if row["type"] == "unreal":
            bucket["unreal"] += 1
        if effective_type(row) == "texture":
            bucket["texture"] += 1

    if not packs:
        return text("No packs matched.")
    ordered = sorted(packs.items(), key=lambda item: -item[1]["files"])
    lines = ["%d packs.  files / meshes / clips / textures / unreal" % len(ordered), ""]
    for name, counts in ordered:
        lines.append("%-56s %6d %6d %6d %6d %6d"
                     % (name[:56], counts["files"], counts["mesh"],
                        counts["animation"], counts["texture"], counts["unreal"]))
    return text("\n".join(lines))


def tool_browse(arguments):
    prefix = (arguments.get("folder") or "").strip().replace("\\", "/").strip("/")
    with open_catalog() as connection:
        if prefix:
            rows = connection.execute(
                "SELECT relative_path, name, type, model_kind, path, size, "
                "referenced_by_model FROM catalog_assets "
                "WHERE ignored = 0 AND lower(relative_path) LIKE ?",
                (prefix.lower() + "/%",)).fetchall()
        else:
            rows = connection.execute(
                "SELECT relative_path, name, type, model_kind, path, size, "
                "referenced_by_model FROM catalog_assets WHERE ignored = 0").fetchall()

    if not rows:
        return text("Nothing under %r. Try list_packs, or browse with no folder."
                    % (prefix or "/"))

    depth = len(prefix.split("/")) if prefix else 0
    folders = {}
    files = []
    for row in rows:
        parts = [p for p in (row["relative_path"] or "").replace("\\", "/").split("/") if p]
        if len(parts) > depth + 1:
            folders[parts[depth]] = folders.get(parts[depth], 0) + 1
        elif len(parts) == depth + 1:
            files.append(row)

    lines = ["%s  --  %d files below" % (prefix or "(catalog root)", len(rows)), ""]
    if folders:
        lines.append("folders:")
        for name, count in sorted(folders.items(), key=lambda item: -item[1]):
            child = "%s/%s" % (prefix, name) if prefix else name
            lines.append("  %-58s %6d   %s" % (name[:58], count, child))
    if files:
        lines.append("")
        lines.append("files here:")
        for row in sorted(files, key=lambda r: r["name"])[:60]:
            lines.append("  %-50s %-10s %s"
                         % (row["name"][:50], effective_type(row), row["path"]))
        if len(files) > 60:
            lines.append("  ... and %d more" % (len(files) - 60))
    return text("\n".join(lines))


def tool_catalog_stats(arguments):
    with open_catalog() as connection:
        total = connection.execute("SELECT count(*) FROM catalog_assets").fetchone()[0]
        by_type = connection.execute(
            "SELECT type, count(*) FROM catalog_assets GROUP BY type "
            "ORDER BY 2 DESC").fetchall()
        by_kind = connection.execute(
            "SELECT model_kind, count(*) FROM catalog_assets GROUP BY model_kind "
            "ORDER BY 2 DESC").fetchall()
        by_ext = connection.execute(
            "SELECT ext, count(*) FROM catalog_assets GROUP BY ext "
            "ORDER BY 2 DESC LIMIT 12").fetchall()
        roots = connection.execute("SELECT root_path FROM catalog_sources").fetchall()
        rigged = connection.execute(
            "SELECT count(*) FROM catalog_assets WHERE rig_family IS NOT NULL"
        ).fetchone()[0]
        fbx = connection.execute(
            "SELECT count(*) FROM catalog_assets WHERE ext = 'fbx'").fetchone()[0]

    lines = ["Atlas catalog: %s" % DB_PATH,
             "%d assets" % total,
             "",
             "scanned roots:"]
    lines += ["  %s" % row[0] for row in roots]
    lines += ["", "by type:"]
    lines += ["  %-10s %7d" % (row[0], row[1]) for row in by_type]
    lines += ["", "by FBX reading (null = never read):"]
    lines += ["  %-10s %7d" % (row[0] or "unread", row[1]) for row in by_kind]
    lines += ["", "by extension:"]
    lines += ["  %-10s %7d" % (row[0], row[1]) for row in by_ext]
    lines += ["", "rig_family known for %d of %d FBX files." % (rigged, fbx)]
    if rigged < fbx // 2:
        lines.append(
            "  Atlas fills this in lazily, as filters ask for it, so it is "
            "mostly empty. The type=character filter and find_animations "
            "depend on it; backfill_rigs.py fills it in one pass with Atlas "
            "closed. Until then, inspect individual files instead -- "
            "get_asset reads the rig straight out of the FBX.")
    running = bridge_version()
    lines += ["",
              "FBX reader: %s" % (IMPORTER_PATH or "not found"),
              "read cache: %s" % CACHE_PATH,
              "Atlas itself: %s" % (
                  "running, version %s -- inspect_model, rig_compatibility "
                  "and render_asset are available" % running if running else
                  "not running, so inspect_model, rig_compatibility and "
                  "render_asset cannot answer")]
    return text("\n".join(lines))


def tool_find_animations(arguments):
    limit = min(int(arguments.get("limit") or DEFAULT_LIMIT), MAX_LIMIT)
    wanted = (arguments.get("rig") or "").strip().lower()
    character = (arguments.get("character") or "").strip()

    with open_catalog() as connection:
        if character:
            row = _find_row(connection, character)
            data = summarise(row["path"], "probe")
            wanted = rig_family_from_markers(data.get("rigMarkers"))
            if wanted == "none":
                return text("%s is not on a rig this can match against."
                            % row["name"])
        search = dict(arguments)
        search["type"] = "animation"
        # Over-fetch when a rig was asked for, since matching means reading.
        rows, total, _ = rows_for(
            connection, search, limit if not wanted else limit * 3, 0)

    if not rows:
        return text("No animation clips matched.")

    if not wanted:
        shown = "\n".join(describe_row(r, i + 1) for i, r in enumerate(rows[:limit]))
        return text("%d clips.\n\n%s" % (total, shown))

    kept = []
    unreadable = 0
    for row in rows:
        if len(kept) >= limit:
            break
        try:
            data = summarise(row["path"], "probe")
        except AtlasError:
            unreadable += 1
            continue
        if rig_family_from_markers(data.get("rigMarkers")) == wanted:
            kept.append(row)

    if not kept:
        return text("None of the %d clips looked at are on the %s rig."
                    % (len(rows), wanted))
    shown = "\n".join(describe_row(r, i + 1) for i, r in enumerate(kept))
    note = ""
    if unreadable:
        note = "\n\n%d clips could not be read." % unreadable
    return text("%d clips on the %s rig, out of %d looked at (%d in the "
                "catalog overall).\n\n%s%s"
                % (len(kept), wanted, len(rows), total, shown, note))


def tool_find_attachments(arguments):
    with open_catalog() as connection:
        character = _find_row(connection, arguments.get("character"))
        pack = container_of(character)
        rows = connection.execute(
            "SELECT * FROM catalog_assets WHERE ignored = 0 AND type = 'model' "
            "AND ext = 'fbx' AND (model_kind IS NULL OR model_kind = 'mesh')"
        ).fetchall()

    grouped = {}
    for row in rows:
        if container_of(row) != pack:
            continue
        if row["path"] == character["path"]:
            continue
        if row["rig_family"] and row["rig_family"] != "none":
            continue
        relative = (row["relative_path"] or "").replace("\\", "/").lower()
        point = attach_point_for(row["name"])
        says_attach = "attach" in relative
        if not point and not says_attach:
            continue
        grouped.setdefault(point or "unplaced", []).append(row)

    if not grouped:
        return text("Nothing in %s looks like kit for %s." % (pack, character["name"]))

    order = [name for name, _ in ATTACH_POINTS] + ["unplaced"]
    lines = ["Kit in %s that could go on %s." % (pack, character["name"]),
             "Placed by name -- the files say nothing about where they go.", ""]
    for point in order:
        found = grouped.get(point)
        if not found:
            continue
        lines.append("%s (%d)" % (point, len(found)))
        for row in sorted(found, key=lambda r: r["name"])[:30]:
            lines.append("  %-52s %s" % (row["name"][:52], row["path"]))
        if len(found) > 30:
            lines.append("  ... and %d more" % (len(found) - 30))
        lines.append("")
    return text("\n".join(lines).rstrip())


def tool_get_texture(arguments):
    with open_catalog() as connection:
        row = _find_row(connection, arguments.get("path"))
    if row["type"] != "image":
        raise AtlasError("%s is not an image." % row["name"])
    data = read_asset_bytes(row["path"])
    if len(data) > MAX_IMAGE_BYTES:
        return text(
            "%s is %s, too large to hand over whole. It lives at %s."
            % (row["name"], format_bytes(len(data)), row["path"]))
    mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(
        row["ext"], "application/octet-stream")
    if not mime.startswith("image/"):
        raise AtlasError("%s is a %s, which cannot be shown." % (row["name"], row["ext"]))
    return {"content": [
        {"type": "text", "text": "%s  (%s)" % (row["name"], format_bytes(len(data)))},
        {"type": "image",
         "data": base64.b64encode(data).decode("ascii"),
         "mimeType": mime},
    ]}


def tool_find_packs(arguments):
    """Packs rather than archives, with the builds each one ships."""
    query = (arguments.get("query") or "").strip().lower()
    engine = (arguments.get("engine") or "").strip().lower()
    build = (arguments.get("build") or "").strip().lower()
    if build and build not in BUILD_KINDS:
        raise AtlasError(
            "Unknown build %r. Use one of: %s." % (build, ", ".join(BUILD_KINDS)))

    with open_catalog() as connection:
        rows = connection.execute(
            "SELECT path, relative_path, source_name, type, model_kind, size, "
            "referenced_by_model FROM catalog_assets WHERE ignored = 0").fetchall()

    packs = {}
    for row in rows:
        info = build_of(row)
        key = info["pack_key"] if info else (row["source_name"] or "loose")
        label = info["pack"] if info else (row["source_name"] or "loose files")
        bucket = packs.setdefault(key, {
            "label": label, "family": info["family"] if info else "",
            "files": 0, "mesh": 0, "animation": 0, "texture": 0, "unreal": 0,
            "bytes": 0, "builds": {}})
        if info:
            bucket["builds"].setdefault(describe_build(info), 0)
            bucket["builds"][describe_build(info)] += 1
        bucket["files"] += 1
        bucket["bytes"] += row["size"] or 0
        if row["model_kind"] == "mesh":
            bucket["mesh"] += 1
        elif row["model_kind"] == "animation":
            bucket["animation"] += 1
        if row["type"] == "unreal":
            bucket["unreal"] += 1
        if effective_type(row) == "texture":
            bucket["texture"] += 1

    def keeps(key, bucket):
        if query and query not in key and query not in bucket["label"].lower():
            return False
        if not engine and not build:
            return True
        for label in bucket["builds"]:
            words = label.split()
            if build and words[0] != build:
                continue
            if engine and engine not in words:
                continue
            return True
        return False

    chosen = [(k, v) for k, v in packs.items() if keeps(k, v)]
    if not chosen:
        return text(
            "No packs matched. Ask with no filters to see everything, or "
            "catalog_stats for which engine versions exist.")

    chosen.sort(key=lambda item: -item[1]["files"])
    lines = ["%d packs.  files / meshes / clips / textures / unreal" % len(chosen), ""]
    for key, bucket in chosen:
        lines.append("%-26s %6d %6d %6d %6d %7d   %s"
                     % (bucket["label"][:26], bucket["files"], bucket["mesh"],
                        bucket["animation"], bucket["texture"], bucket["unreal"],
                        ", ".join(sorted(bucket["builds"]))))
    lines.append("")
    lines.append("A source build ships FBX and OBJ. An unreal build ships .uasset "
                 "and .umap only -- no geometry readable outside the engine, but "
                 "it is what drops into a project. export_assets writes either "
                 "out of its archive.")
    return text("\n".join(lines))


def tool_find_duplicates(arguments):
    """Files the catalog holds more than one copy of."""
    limit = min(int(arguments.get("limit") or 30), MAX_LIMIT)
    ext = (arguments.get("ext") or "").strip().lower().lstrip(".")
    clauses = ["ignored = 0"]
    params = []
    if ext:
        clauses.append("ext = ?")
        params.append(ext)
    where = " AND ".join(clauses)

    with open_catalog() as connection:
        groups = connection.execute(
            "SELECT name, size, count(*) AS copies FROM catalog_assets "
            "WHERE %s GROUP BY lower(name), size HAVING copies > 1 "
            "ORDER BY (copies - 1) * size DESC LIMIT ?" % where,
            params + [limit]).fetchall()
        totals = connection.execute(
            "SELECT count(*) AS rows_total, "
            "count(DISTINCT lower(name) || ':' || size) AS distinct_total, "
            "sum(size) AS bytes_total FROM catalog_assets WHERE %s" % where,
            params).fetchone()
        wasted = connection.execute(
            "SELECT sum(extra) FROM (SELECT (count(*) - 1) * size AS extra "
            "FROM catalog_assets WHERE %s GROUP BY lower(name), size)" % where,
            params).fetchone()[0] or 0

    if not groups:
        return text("No duplicates.")
    redundant = totals["rows_total"] - totals["distinct_total"]
    lines = [
        "%d of %d %srows are redundant copies (%d distinct files), %s of disk."
        % (redundant, totals["rows_total"], (ext + " ") if ext else "",
           totals["distinct_total"], format_bytes(wasted)),
        "",
        "Copies come from packs re-released per engine version and per pack "
        "revision, so the copies are usually interchangeable -- but an unreal "
        "build's copy is only useful to that engine version. search_assets "
        "collapses them by default.",
        "",
    ]
    for row in groups:
        lines.append("%-52s %2d copies  %s each  %s wasted"
                     % (row["name"][:52], row["copies"],
                        format_bytes(row["size"]),
                        format_bytes((row["copies"] - 1) * row["size"])))
    return text("\n".join(lines))


def _safe_relative(entry_path):
    """Where an archive entry may be written, or None if it may not be.

    An archive is untrusted input: an entry named ../../x or C:/x would have an
    export write outside the folder it was given.
    """
    cleaned = (entry_path or "").replace("\\", "/")
    if not cleaned or cleaned.startswith("/") or ":" in cleaned.split("/")[0]:
        return None
    parts = []
    for part in cleaned.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            return None
        parts.append(part)
    return os.path.join(*parts) if parts else None


def tool_export_assets(arguments):
    """Write assets out of their archives into a folder."""
    dest = (arguments.get("dest") or "").strip()
    if not dest:
        raise AtlasError("Give dest: the folder to write into.")
    dest = os.path.abspath(dest)
    paths = arguments.get("paths") or []
    if isinstance(paths, str):
        paths = [paths]
    overwrite = bool(arguments.get("overwrite"))
    limit = min(int(arguments.get("limit") or DEFAULT_EXPORT_FILES),
                MAX_EXPORT_FILES)

    with open_catalog() as connection:
        if paths:
            rows = []
            for path in paths:
                rows.append(_find_row(connection, path))
        else:
            if not any(arguments.get(key) for key in
                       ("query", "pack", "folder", "ext", "engine", "build")):
                raise AtlasError(
                    "Give paths, or a selection (query / pack / folder / ext / "
                    "engine / build). Exporting the whole catalog is never "
                    "what anyone means.")
            where, params, kind, sieve = build_query(arguments)
            extra, extra_params = archive_clause(connection, arguments)
            if extra:
                where += " AND " + extra
                params = params + extra_params
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE %s ORDER BY relative_path "
                "LIMIT ?" % where, params + [limit + 1]).fetchall()
            rows = sieve_rows(rows, kind, sieve)

    if not rows:
        return text("Nothing matched, so nothing was written.")
    truncated = len(rows) > limit
    rows = rows[:limit]
    planned = sum(row["size"] or 0 for row in rows)
    if planned > MAX_EXPORT_BYTES:
        raise AtlasError(
            "That selection is %s across %d files, past the %s export ceiling. "
            "Narrow it, or raise it deliberately."
            % (format_bytes(planned), len(rows), format_bytes(MAX_EXPORT_BYTES)))

    written, skipped, failed, written_bytes = [], [], [], 0
    for row in rows:
        parsed = parse_zip_path(row["path"])
        relative = _safe_relative(parsed[1] if parsed else row["name"])
        if relative is None:
            failed.append("%s (unsafe entry name)" % row["path"])
            continue
        target = os.path.join(dest, relative)
        if os.path.exists(target) and not overwrite:
            skipped.append(relative)
            continue
        try:
            data = read_asset_bytes(row["path"])
            folder = os.path.dirname(target)
            if folder:
                os.makedirs(folder, exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(data)
        except (AtlasError, OSError) as error:
            failed.append("%s (%s)" % (relative, error))
            continue
        written.append(relative)
        written_bytes += len(data)

    lines = ["Wrote %d files (%s) into %s."
             % (len(written), format_bytes(written_bytes), dest)]
    if skipped:
        lines.append("Left %d already-present files alone; pass overwrite=true "
                     "to replace them." % len(skipped))
    if failed:
        lines.append("%d failed:" % len(failed))
        lines.extend("  " + item for item in failed[:10])
    if truncated:
        lines.append("Stopped at the limit of %d files -- there were more. "
                     "Raise limit or narrow the selection." % limit)
    if written:
        lines.append("")
        lines.append("A few of them:")
        lines.extend("  " + item for item in written[:12])
        if len(written) > 12:
            lines.append("  ... and %d more" % (len(written) - 12))
    return text("\n".join(lines))


def _count(value):
    return "{:,}".format(int(value or 0))


def _dimension_line(report):
    size = report.get("authoredSize")
    if not size or any(v is None for v in size):
        return None
    return ("  %-13s %.3g x %.3g x %.3g units, as the artist built it"
            % ("real size", size[0], size[1], size[2]))


SHAPE_WORDS = {
    "model": "one model",
    "sheet": "a sheet of several whole models",
    "kit": "a kit of interchangeable parts",
    "animation": "an animation, no geometry",
}


def tool_inspect_model(arguments):
    report = bridge_call("/inspect", {"path": arguments.get("path")})

    shape = report.get("shape") or "model"
    # The archive is the pack here; "pack" is only the scanned root's name,
    # which for this library is the unhelpful word "Synty" on 50,000 files.
    where = report.get("archive") or report.get("pack")
    head = [bit for bit in (report.get("name"), where,
                            SHAPE_WORDS.get(shape, shape)) if bit]
    lines = ["  ".join(head), "  %-13s %s" % ("path", report.get("path"))]

    lines.append("  %-13s %s faces, %s vertices, %s objects"
                 % ("geometry", _count(report.get("faces")),
                    _count(report.get("vertices")),
                    _count(report.get("objects"))))
    dimensions = _dimension_line(report)
    if dimensions:
        lines.append(dimensions)

    materials = report.get("materials") or []
    resolved = report.get("texturesResolved") or 0
    lines.append("  %-13s %d of %d materials textured"
                 % ("textures", resolved, len(materials)))
    for material in materials[:12]:
        lines.append("                  %-24s %s"
                     % (material.get("name") or "(unnamed)",
                        material.get("summary")))
    if len(materials) > 12:
        lines.append("                  ... and %d more"
                     % (len(materials) - 12))

    rig = report.get("rig") or {}
    if rig.get("family") and rig["family"] != "none":
        detail = "%s, %s bones" % (rig.get("label"), _count(rig.get("bones")))
        if rig.get("skinned"):
            detail += ", skinned"
        if rig.get("durationSeconds"):
            detail += ", %.2fs of motion" % rig["durationSeconds"]
        lines.append("  %-13s %s" % ("rig", detail))
        for clip in (rig.get("clips") or [])[:8]:
            lines.append("                  %s" % clip)

    slots = report.get("slots") or []
    if slots:
        named = ", ".join("%s x%d" % (slot.get("label") or slot.get("key"),
                                      slot.get("variants") or 0)
                          for slot in slots[:8])
        more = "" if len(slots) <= 8 else ", ... and %d more" % (len(slots) - 8)
        lines.append("  %-13s %d: %s%s" % ("slots", len(slots), named, more))

    attachments = report.get("attachments") or []
    if attachments:
        lines.append("  %-13s %d in this archive" % ("attachments",
                                                     len(attachments)))
        for piece in attachments[:10]:
            point = piece.get("point")
            if point:
                lines.append("                  %-38s -> %s"
                             % (piece.get("name"), point))
            else:
                lines.append("                  %s" % piece.get("name"))
        if len(attachments) > 10:
            lines.append("                  ... and %d more; find_attachments "
                         "lists them all" % (len(attachments) - 10))

    variants = report.get("textureVariants") or []
    if variants:
        one = len(variants) == 1
        lines.append("  %-13s %d other texture%s in this archive fit%s it"
                     % ("recolours", len(variants), "" if one else "s",
                        "s" if one else ""))

    for warning in report.get("warnings") or []:
        lines.append("  !             %s" % warning)

    return text("\n".join(lines))


def tool_rig_compatibility(arguments):
    report = bridge_call("/rig_compat", {
        "character": arguments.get("character"),
        "clip": arguments.get("clip"),
    })
    character = report.get("character") or {}
    clip = report.get("clip") or {}
    difference = report.get("restPoseDifferenceDegrees")
    lines = [
        report.get("verdict") or "",
        "",
        "  %-13s %s  (%s, %s bones)"
        % ("character", character.get("name"), character.get("label"),
           _count(character.get("bones"))),
        "  %-13s %s  (%s, %s bones, %s frames)"
        % ("clip", clip.get("name"), clip.get("label"),
           _count(clip.get("bones")), _count(clip.get("frames"))),
        "  %-13s %s" % ("shared bones", _count(report.get("sharedBones"))),
        "  %-13s %s" % ("rest poses",
                        "not comparable" if difference is None
                        else "%.1f degrees apart" % difference),
    ]
    return text("\n".join(lines))


# ------------------------------------------------------- visual search

EMBED_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "atlas_embed.py")
EMBED_TIMEOUT_SECONDS = 180

# Beside the catalog, written by tag_assets.py. Derived data: deleting these
# costs a re-run, never a loss.
VECTORS_NAME = "embeddings.f32"
EMBED_INDEX_NAME = "embeddings_index.sqlite"

NO_VECTORS = (
    "There are no visual embeddings yet, so nothing can be ranked by how it "
    "looks. Someone has to run the tagging pass first:\n"
    "    python -P work/atlas_mcp/tag_assets.py --pack POLYGON_Town\n"
    "It renders each model in Atlas and embeds the picture. The whole "
    "library is about 8.7 hours of background work; a single pack is "
    "minutes, and it is resumable, so a slice is a reasonable place to start.")


def embedding_store_paths():
    folder = os.path.dirname(DB_PATH)
    return (os.path.join(folder, VECTORS_NAME),
            os.path.join(folder, EMBED_INDEX_NAME))


def embeddings_present():
    """Whether a store exists at all. Cheap: one stat, no model load."""
    vectors_path, _index_path = embedding_store_paths()
    return bool(vectors_path) and os.path.exists(vectors_path)


def run_visual_search(phrase=None, like_asset_id=None, top=20):
    """Ask atlas_embed.py to rank the store. Returns its parsed reply."""
    vectors_path, index_path = embedding_store_paths()
    if not os.path.exists(vectors_path):
        raise AtlasError(NO_VECTORS)

    command = [sys.executable, "-P", EMBED_SCRIPT,
               "--vectors", vectors_path, "--index", index_path,
               "--top", str(int(top))]
    if like_asset_id:
        command += ["--search-like", like_asset_id]
    else:
        command += ["--search", phrase or ""]

    try:
        finished = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=EMBED_TIMEOUT_SECONDS,
            cwd=os.path.dirname(EMBED_SCRIPT))
    except subprocess.TimeoutExpired:
        raise AtlasError(
            "The embedder did not answer within %d seconds. Loading the text "
            "model takes about 1.6 s normally; this long usually means the "
            "machine is under heavy load."
            % EMBED_TIMEOUT_SECONDS)
    except OSError as error:
        raise AtlasError("Could not start the embedder: %s" % error)

    output = finished.stdout.decode("utf-8", "replace").strip()
    errors = finished.stderr.decode("utf-8", "replace").strip()
    if not output:
        raise AtlasError(
            "The embedder said nothing. Its error output was:\n%s"
            % (errors or "(none)"))
    try:
        reply = json.loads(output.splitlines()[-1])
    except ValueError:
        raise AtlasError(
            "The embedder's reply was not JSON:\n%s" % output[:500])
    if not reply.get("ok"):
        raise AtlasError(reply.get("error") or "the embedder refused")
    return reply


def tool_find_similar(arguments):
    """Rank assets by how they look, not by what they are called.

    This is the only tool in the set that can answer a question about
    appearance. Everything else matches text, and the style words people
    reach for -- grungy, gray, ornate -- appear in none of the 221,183 names.
    """
    phrase = (arguments.get("text") or "").strip()
    like = (arguments.get("like_path") or "").strip()
    top = max(1, min(int(arguments.get("limit") or 20), 100))
    if not phrase and not like:
        raise AtlasError(
            "Give text to look for, or like_path to find more of the same.")
    if phrase and like:
        raise AtlasError(
            "Give text or like_path, not both: they are two different "
            "questions and the answers would not be comparable.")

    like_asset_id = None
    like_name = None
    if like:
        with open_catalog() as connection:
            row = _find_row(connection, like)
            like_asset_id = row["id"]
            # Its own re-exports have to go too, not just the row asked
            # about. A model re-exported for another rig is a different file
            # with the same picture, so left in it takes the top place and
            # answers "more like this" with "this".
            like_name = (row["name"] or "").lower()

    reply = run_visual_search(phrase=phrase, like_asset_id=like_asset_id,
                              top=top)
    results = reply.get("results") or []
    if not results:
        return text("Nothing to rank: the store holds %d vectors."
                    % reply.get("searched", 0))

    wanted = [item["asset_id"] for item in results]
    with open_catalog() as connection:
        placeholders = ", ".join(["?"] * len(wanted))
        rows = {row["id"]: row for row in connection.execute(
            "SELECT * FROM catalog_assets WHERE id IN (%s)" % placeholders,
            wanted).fetchall()}

    # One picture is one answer. The pass embeds per file and is right to:
    # Characters/X.fbx and Characters/Unreal_Characters/X.fbx are different
    # files, re-exported for a different rig. They draw the same silhouette,
    # so showing both spends a place in the ranking to say nothing.
    collapsed = []
    seen = {}
    for item in results:
        row = rows.get(item["asset_id"])
        key = (row["name"] or "").lower() if row is not None else None
        if like_name is not None and key == like_name:
            continue
        if key is not None and key in seen:
            seen[key]["repeats"] += 1
            continue
        entry = {"item": item, "row": row, "repeats": 0}
        if key is not None:
            seen[key] = entry
        collapsed.append(entry)

    lines = [
        "%d of %d embedded assets, ranked by how they look%s"
        % (len(collapsed), reply.get("searched", 0),
           " like that one" if like else ""),
        # Said every time, because the instinct on seeing 0.12 is to call it
        # a bad match. It is not a probability; the order is the answer.
        # The two ranges differ by an order of magnitude and quoting the
        # wrong one is worse than quoting neither: text and image embeddings
        # sit in separate regions of the space -- SigLIP's modality gap -- so
        # a text query's best match scores near 0.15 where an image query's
        # scores near 0.95, and both mean "the closest thing there is".
        ("Scores are cosines against another picture: a close match runs "
         "around 0.9. Read the order, not the magnitude."
         if like else
         "Scores are cosines from a sigmoid-trained model, and text and "
         "image vectors sit in different regions of it: real matches sit "
         "around 0.05 to 0.18. Read the order, not the magnitude."),
        "",
    ]
    for position, entry in enumerate(collapsed, start=1):
        item, row = entry["item"], entry["row"]
        if row is None:
            # The catalog was rescanned since the vector was computed.
            lines.append("%2d. %.4f  (no longer in the catalog)"
                         % (position, item["score"]))
            continue
        repeats = ""
        if entry["repeats"]:
            repeats = "  (+%d copy%s elsewhere)" % (
                entry["repeats"], "" if entry["repeats"] == 1 else "ies")
        lines.append("%2d. %.4f  %s%s"
                     % (position, item["score"], row["name"], repeats))
        lines.append("          %s  %s"
                     % (container_of(row), row["relative_path"]))

    lines.append("")
    # No denominator: the only honest one is a count of what could be
    # embedded, and that needs a GROUP BY over the whole catalog on every
    # query. The number that matters is how much was searched.
    lines.append("Ranked over the %d assets that have been rendered and "
                 "embedded so far -- nothing else can appear here, however "
                 "well it would have matched. Run tag_assets.py for more."
                 % reply.get("searched", 0))
    return text("\n".join(lines))


def tool_render_asset(arguments):
    size = int(arguments.get("size") or 512)
    report = bridge_call("/render", {
        "path": arguments.get("path"),
        "size": size,
        "yaw": arguments.get("yaw"),
        "pitch": arguments.get("pitch"),
    })
    data = base64.b64decode(report["png"])
    caption = "%s  %dx%d  %s of %s faces drawn" % (
        report.get("name"), report.get("width"), report.get("height"),
        _count(report.get("drawnFaces")), _count(report.get("totalFaces")))
    if report.get("capped"):
        caption += " (face limit reached; the rest is not drawn)"
    if report.get("shape") == "kit":
        caption += "\nA kit: drawn with one variant per slot, as Atlas draws it."
    if len(data) > MAX_IMAGE_BYTES:
        return text("%s\nThe picture came to %s, too large to hand over."
                    % (caption, format_bytes(len(data))))
    return {"content": [
        {"type": "text", "text": caption},
        {"type": "image",
         "data": base64.b64encode(data).decode("ascii"),
         "mimeType": "image/png"},
    ]}


TOOLS = [
    {
        "name": "search_assets",
        "description":
            "Search the Atlas catalog. Terms are ANDed and matched against the "
            "file name, its path and its tags, exactly as the Atlas search box "
            "does, so 'jump fem' finds A_Jump_Running_Femn.fbx. Scope a term to "
            "one field with name=, path=, tag=, type=, ext= or rig=.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description":
                              "Space-separated terms, all of which must match, over the "
                              "file name, path and tags together -- so "
                              "'jump fem' finds A_Jump_Running_Femn.fbx. "
                              "A term can name one field instead: "
                              "name=, path=, tag=, type=, ext=, rig=, as "
                              "in 'tag=grungy name=door'. name/path/tag "
                              "match a substring; type/ext/rig are exact. "
                              "`or` groups the terms either side of it and "
                              "binds tighter than a space, so 'name=dog "
                              "or name=cat type=model' is (dog or cat) and "
                              "model. There are no parentheses. Quote a "
                              "value to keep spaces or an = in it. The box "
                              "in Atlas reads the same grammar."},
                "type": {"type": "string",
                         "enum": sorted(TYPE_FILTERS),
                         "description":
                             "all, model, mesh, animation, character, image, "
                             "texture, audio, unreal. 'character' needs "
                             "rig_family, which may be unpopulated; see "
                             "catalog_stats."},
                "pack": {"type": "string",
                         "description": "Restrict to packs whose path contains this."},
                "folder": {"type": "string",
                           "description": "Restrict to paths containing this folder."},
                "ext": {"type": "string", "description": "File extension, e.g. fbx."},
                "build": {"type": "string", "enum": list(BUILD_KINDS),
                          "description":
                              "Only assets from this kind of build: 'source' "
                              "(FBX/OBJ) or 'unreal'/'unity' (engine assets)."},
                "engine": {"type": "string",
                           "description":
                               "Only assets from a build for this engine "
                               "version, e.g. '5.4'. See find_packs."},
                "distinct": {"type": "boolean",
                             "description":
                                 "Collapse identical copies (same name and "
                                 "size). Default true; half this library is "
                                 "duplicates."},
                "limit": {"type": "integer", "description": "Default 40, max 200."},
                "offset": {"type": "integer"},
            },
        },
        "handler": tool_search_assets,
    },
    {
        "name": "get_asset",
        "description":
            "Everything Atlas knows about one asset: its catalog entry, what "
            "the FBX reader says about the file itself (geometry, bounds, "
            "units, rig, bones, materials, the textures it asks for), and the "
            "images sitting beside it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string",
                         "description": "Full path from a search, an asset id, "
                                        "or an unambiguous file name."},
                "inspect": {"type": "string", "enum": ["none", "summary", "full"],
                            "description":
                                "'summary' reads the file (default). 'full' also "
                                "lists every node and bone. 'none' stays in the "
                                "catalog."},
            },
            "required": ["path"],
        },
        "handler": tool_get_asset,
    },
    {
        "name": "list_packs",
        "description":
            "The asset packs in the catalog -- one per archive or top-level "
            "folder -- with how many files, meshes, animation clips, textures "
            "and Unreal assets each holds.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Filter pack names."},
            },
        },
        "handler": tool_list_packs,
    },
    {
        "name": "browse",
        "description":
            "Walk the catalog's folder tree one level at a time, the way the "
            "Atlas folder pane does. Call with no folder for the roots.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "folder": {"type": "string",
                           "description": "A folder path as shown by a previous "
                                          "browse, e.g. 'Synty/POLYGON_X.zip!/SourceFiles'."},
            },
        },
        "handler": tool_browse,
    },
    {
        "name": "catalog_stats",
        "description":
            "Size and shape of the catalog: totals by type, extension and what "
            "the FBX reader has classified, the scanned roots, and where the "
            "data is thin.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": tool_catalog_stats,
    },
    {
        "name": "find_animations",
        "description":
            "Animation clips, optionally only those on a given rig. Pass a "
            "character's path and the rig is read off that character. Matching "
            "a rig means reading each clip, so this is slower than a search.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "rig": {"type": "string", "enum": ["polygon", "sidekick", "unreal"]},
                "character": {"type": "string",
                              "description": "Path of a character whose rig to match."},
                "pack": {"type": "string"},
                "limit": {"type": "integer"},
            },
        },
        "handler": tool_find_animations,
    },
    {
        "name": "find_attachments",
        "description":
            "Kit in a character's own pack that could be worn on it -- helmets, "
            "hair, capes, weapons -- grouped by the body part the name claims. "
            "Placement is read from names because nothing in the files records it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "character": {"type": "string",
                              "description": "Path of the character to dress."},
            },
            "required": ["character"],
        },
        "handler": tool_find_attachments,
    },
    {
        "name": "find_similar",
        "description":
            "Rank assets by how they LOOK, from a rendered picture of each: "
            "the only tool here that can answer a question about appearance. "
            "Give text ('a grungy metal barrel', 'something gray and "
            "industrial') or like_path to find more of the same shape. Every "
            "other search matches names, and style words appear in none of "
            "them. Needs the tagging pass to have been run; it says so when "
            "it has not, and only embedded assets can be returned.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string",
                         "description":
                             "What it should look like. A description of "
                             "appearance, not a filename."},
                "like_path": {"type": "string",
                              "description":
                                  "An asset path; returns others that look "
                                  "like it. Use instead of text."},
                "limit": {"type": "integer",
                          "description": "How many to rank (default 20, "
                                         "max 100)."},
            },
        },
        "handler": tool_find_similar,
    },
    {
        "name": "get_texture",
        "description":
            "Hand back an image from the catalog -- a palette atlas, a pack "
            "icon -- so it can be looked at rather than described.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path of an image asset."},
            },
            "required": ["path"],
        },
        "handler": tool_get_texture,
    },
    {
        "name": "find_packs",
        "description":
            "The asset packs in the library, one row per pack rather than per "
            "archive, with the builds each one ships -- source files, and an "
            "Unreal or Unity build per engine version. Start here when the "
            "question is 'what do I have for X' or 'is there a 5.4 build'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "Filter pack names, e.g. 'dungeon'."},
                "build": {"type": "string", "enum": list(BUILD_KINDS),
                          "description": "Only packs that ship this build kind."},
                "engine": {"type": "string",
                           "description":
                               "Only packs with a build for this engine "
                               "version, e.g. '5.4' or '4.25'."},
            },
        },
        "handler": tool_find_packs,
    },
    {
        "name": "find_duplicates",
        "description":
            "Files the library holds more than one copy of, biggest waste "
            "first. Copies come from pack re-releases and per-engine builds.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ext": {"type": "string",
                        "description": "Restrict to one extension, e.g. fbx."},
                "limit": {"type": "integer", "description": "Default 30."},
            },
        },
        "handler": tool_find_duplicates,
    },
    {
        "name": "export_assets",
        "description":
            "Write assets out of their archives into a folder -- the step that "
            "turns a search into files on disk. Entries keep their "
            "archive-relative path, so exporting an Unreal build's Content "
            "folder lands it ready to drop into a project. Existing files are "
            "left alone unless overwrite is set; nothing is ever deleted.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "dest": {"type": "string",
                         "description": "Folder to write into. Created if needed."},
                "paths": {"type": "array", "items": {"type": "string"},
                          "description":
                              "Exact asset paths to write. Otherwise give a "
                              "selection below."},
                "query": {"type": "string",
                          "description":
                              "Search terms, same grammar as search_assets: "
                              "plain words, or name=/path=/tag=/type=/ext=/"
                              "rig= to scope one."},
                "pack": {"type": "string", "description": "Restrict to a pack."},
                "folder": {"type": "string",
                           "description": "Restrict to paths containing this folder."},
                "ext": {"type": "string", "description": "File extension."},
                "type": {"type": "string", "enum": sorted(TYPE_FILTERS)},
                "build": {"type": "string", "enum": list(BUILD_KINDS)},
                "engine": {"type": "string",
                           "description": "Engine version, e.g. '5.4'."},
                "overwrite": {"type": "boolean",
                              "description": "Replace files already there. Default false."},
                "limit": {"type": "integer",
                          "description": "Max files to write. Default 500, max 5000."},
            },
            "required": ["dest"],
        },
        "handler": tool_export_assets,
    },
    {
        "name": "inspect_model",
        "description":
            "Whether a model is actually usable, answered by the running "
            "Atlas: which of its textures resolve and which are missing, "
            "whether the file is one model or a sheet of several or a kit of "
            "interchangeable parts, its real authored size in units, its rig, "
            "the kit pieces in the same archive that fit it and the recolours "
            "available. Needs Atlas open; the catalog tools do not.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string",
                         "description":
                             "Full asset path, or a file name if only one "
                             "asset has it."},
            },
            "required": ["path"],
        },
        "handler": tool_inspect_model,
    },
    {
        "name": "rig_compatibility",
        "description":
            "Whether an animation clip will drive a particular character, "
            "answered by the running Atlas: the rig family of each, how many "
            "bones they share and how far apart their rest poses sit. The "
            "Synty families share no bone names at all, so a clip from the "
            "wrong one does nothing. Needs Atlas open.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "character": {"type": "string",
                              "description": "Path of the skinned character."},
                "clip": {"type": "string",
                         "description": "Path of the animation FBX."},
            },
            "required": ["character", "clip"],
        },
        "handler": tool_rig_compatibility,
    },
    {
        "name": "render_asset",
        "description":
            "Draws a model and hands back the picture, using Atlas's own "
            "renderer, so it looks as it does in the app. A kit is drawn with "
            "one variant per slot rather than every part at once. Use it to "
            "check what something actually looks like before committing to "
            "it. Needs Atlas open.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Full asset path."},
                "size": {"type": "integer",
                         "description": "Pixels square, 64 to 2048. Default 512."},
                "yaw": {"type": "number",
                        "description": "Turn, in radians. Default 0.6."},
                "pitch": {"type": "number",
                          "description": "Tilt, in radians. Default 0.35."},
            },
            "required": ["path"],
        },
        "handler": tool_render_asset,
    },
]

HANDLERS = {tool["name"]: tool["handler"] for tool in TOOLS}
TOOL_SCHEMAS = [
    {k: v for k, v in tool.items() if k != "handler"} for tool in TOOLS
]

INSTRUCTIONS = """Atlas indexes a large local library of game assets -- Synty
packs and others -- as FBX and OBJ models, animation clips, texture atlases and
Unreal assets, most of them inside zip archives that are read in place.

Start with search_assets or list_packs, then get_asset on anything specific:
it reads the actual file, so it can tell you a model's rig, bone count, node
names, bounds and which textures it asks for. Paths look like
'zip:<archive>::<entry>' for files inside an archive; pass them back verbatim.

Names in this library are not reliable -- 'SK_' is Unreal's skeletal-mesh
prefix that the packs put on differently-rigged characters, and 'SM_' sits on
fully skinned ones -- so prefer what get_asset reads out of the file over what
a file name suggests.

Building in Unreal: a pack ships several times over, as source files and as a
built project per engine version, so ask find_packs first -- it lists packs
with the builds each one has, and takes engine='5.4'. A source build holds FBX
and OBJ, which is what you want for inspecting geometry or importing yourself.
An unreal build holds .uasset and .umap only: no geometry anything outside the
engine can read, and tied to its engine version, but it is what drops straight
into a project. export_assets writes either one out of its archive, keeping
archive-relative paths.

Half the library is duplicate files -- packs re-released and re-exported -- so
search_assets collapses identical copies by default and says how many there
were. Copies of a source asset are interchangeable; a copy from an unreal
build is only useful to that engine version.

rig_family drives type='character' and find_animations' rig matching, and the
catalog fills it in lazily, so it may be nearly empty; catalog_stats says how
many files have it.

Three tools ask the running Atlas rather than the catalog, because what they
answer is not in the database and is not safe to restate: inspect_model (do
this model's textures resolve, is it one model or a sheet of twelve or a kit
of parts, how big is it really), rig_compatibility (will this clip drive that
character) and render_asset (what does it look like). They need Atlas open and
say so if it is not; everything else works either way. Before importing
anything into a project, inspect_model is the tool that says whether it will
arrive whole -- a name and a file size do not.

Six prompts hold the sequences this library gets asked for repeatedly --
survey_the_library, set_up_a_level, import_a_model, animate_a_character,
dress_a_character, choose_a_build. They are the order to call things in, with
the traps named; read the relevant one before improvising a sequence."""


# ----------------------------------------------------------------- prompts

# A prompt here is a procedure, not a greeting. Each one is a sequence that
# gets repeated against this library -- dress a level, check a model before
# importing it, drive a character with a clip -- written down with the traps
# named in the order they are met. The tool descriptions say what each tool
# does; these say which order to call them in, which is the part a model
# reliably gets wrong on a library whose names lie.


class JsonRpcError(Exception):
    """A protocol-level error, carrying the code to hand the client."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


def _arg(arguments, name, fallback):
    value = (arguments or {}).get(name)
    if isinstance(value, str):
        value = value.strip()
    return value or fallback


def prompt_survey_the_library(arguments):
    return """Find out what is here before asking for anything specific.

1. catalog_stats -- totals by type, the pack count, whether Atlas is running
   (the three model tools need it) and how many files have a rig family. Read
   that last number: if it is near zero, type='character' and
   find_animations' rig matching come back empty, and that is a gap in the
   catalog rather than in the library.
2. find_packs with no query -- every pack with the builds it ships. This is
   the map. The file list is the territory and it is 74,000 rows.
3. list_packs or browse to walk one pack.
4. find_duplicates if the question is about disk space rather than content.

Two things to carry into every later question. Names here are literal and the
prefixes are unreliable: the nouns are good ('Barrel', 'Helmet',
'RubbishBin'), while 'SK_' and 'SM_' sit on whatever the exporter felt like.
And half the rows are duplicate files, so a match count is not a count of
distinct assets unless the tool says it collapsed them."""


def prompt_set_up_a_level(arguments):
    theme = _arg(arguments, "theme",
                 "(not given -- ask, or see the themes find_packs lists)")
    engine = _arg(arguments, "engine",
                  "(not given -- ask; it decides step 2)")
    return """Gather the assets for a themed level and get them into an
Unreal project.

Theme:  %s
Engine: %s

1. find_packs with the theme as the query. Do this before searching for
   files: a pack ships several times over -- source files, and a built
   project per engine version -- and which copy you take decides everything
   after it.
2. Pick the build. An unreal build matching the engine exactly drops in with
   its materials and blueprints intact and no import step, but carries no
   geometry anything outside the engine can read. A source build is FBX and
   OBJ: it imports anywhere, you choose the settings, and you redo the
   materials. Take one, not both.
3. search_assets with build= and engine= set, and type='model' for geometry.
   Search the nouns. Style words do not appear in these names -- there is no
   'grungy' or 'weathered' in the library's own vocabulary, only
   'SM_Prop_RubbishBin_02'.
4. inspect_model on the two or three you actually mean to place, before
   exporting any of them. It is the only thing that says whether a model's
   textures resolve and how big it really is. A prop that lands a hundred
   times too large is the commonest way this goes wrong and the file name
   does not say.
5. export_assets with dest= and the paths you chose. An unreal build's
   Content tree lands archive-relative, ready to drop into the project.""" % (
        theme, engine)


def prompt_import_a_model(arguments):
    asset = _arg(arguments, "asset",
                 "(not given -- ask, or shortlist with search_assets)")
    return """Decide whether a model will arrive whole, before spending an
import on it.

Model: %s

1. inspect_model on it. Needs Atlas open. Four things in the report matter:
   - textures. "2 of 5 materials textured" means three draw flat. A material
     that named textures and resolved none looks identical on screen to one
     that was always flat colour and means the opposite thing.
   - shape: model, sheet or kit. A sheet is a dozen bodies standing in one
     place; a kit is one model whose every part ships in the same file, eight
     heads and twenty shoulder plates. Import either whole and you get an
     interpenetrating pile, not a mistake you will diagnose quickly.
   - size, in the units the artist authored. This is the import scale. The
     viewer fits a rivet and a cathedral into the same box, so nothing you
     can see tells you this.
   - rig: none for a prop, a family name for a character.
2. render_asset if you want to look at it. For a kit it draws one variant per
   slot rather than every part at once.
3. get_asset for the node and material names you will meet in Unreal, and the
   textures the file asks for by name.
4. export_assets once you are satisfied. Prefer a source build's FBX unless
   the project is on the exact engine an unreal build targets.""" % (asset,)


def prompt_animate_a_character(arguments):
    character = _arg(arguments, "character",
                     "(not chosen -- step 1 finds one)")
    motion = _arg(arguments, "motion",
                  "(not given -- ask, or see what find_animations has)")
    return """Drive a character with animation clips from this library.

Character: %s
Motion:    %s

1. If the character is not chosen: search_assets type='character'. That
   filter reads the rig_family column, which the catalog fills in lazily and
   which may be nearly empty -- catalog_stats says how many files have it. If
   it comes back empty, search type='model' and inspect candidates rather
   than trusting a name: 'SK_' is Unreal's skeletal-mesh prefix and these
   packs put it on three unrelated rigs.
2. find_animations for the motion.
3. rig_compatibility on one clip per pack before committing to that pack. It
   answers two separate questions and both decide the outcome. Shared bone
   count: zero means the clip cannot drive this character at all, and that is
   the normal case across rig families -- Polygon and Sidekick share no bone
   names whatsoever. Rest-pose difference in degrees: all bones shared but
   around 90 degrees apart means the clip will play and the limbs will sit
   wrong until something retargets it.
4. Export the character and its clips together. A clip is only useful beside
   a character on a rig it matches.""" % (character, motion)


def prompt_dress_a_character(arguments):
    character = _arg(arguments, "character",
                     "(not given -- ask, or shortlist with search_assets)")
    return """Find the kit -- helmets, hair, capes -- that fits a character.

Character: %s

1. find_attachments on it -- helmets, beards, hair, capes and pauldrons from
   the character's own archive, each with the attach point it is guessed to
   use.
2. Treat that point as a suggestion. It is the one thing in this library
   inferred from a file name, and deliberately so: an attachment FBX is a
   bare mesh at the origin with no socket and no metadata, so nothing in the
   file says where it goes.
3. inspect_model on the pieces you want. The texture question applies to a
   helmet exactly as it does to a building, and a piece whose textures do not
   resolve arrives flat.
4. Take the FBX, not the OBJ twin. Every piece ships both, and the OBJ is in
   centimetres with nothing in the file to say so.""" % (character,)


def prompt_choose_a_build(arguments):
    pack = _arg(arguments, "pack",
                "(not given -- find_packs lists them all)")
    engine = _arg(arguments, "engine", "(not given -- ask)")
    return """Decide which copy of a pack to take: source files, or a built
Unreal project, and which engine version.

Pack:   %s
Engine: %s

1. find_packs on the pack name and read its builds. Which engine a build
   targets is recorded only in the archive name -- a .uasset does not say --
   so this is the one place the fact exists.
2. An unreal build on the exact version: no import step, materials and
   blueprints intact, and nothing outside the engine can read the geometry.
3. An unreal build on a different version: usually still opens, with a
   conversion. Weigh it against the source build rather than assuming either
   way.
4. A source build: FBX and OBJ. Imports anywhere and you redo the materials.
   It is also the only build inspect_model, rig_compatibility and
   render_asset can say anything about, because the unreal builds carry no
   geometry to read.
5. Take one. Two copies of one pack in one project is the commonest
   duplication here, which is why search_assets collapses identical copies in
   its listings by default.""" % (pack, engine)


PROMPTS = [
    {
        "name": "survey_the_library",
        "description": "Orient yourself in the library before asking for "
                       "anything specific: what is here, what the catalog "
                       "knows, and the two things that mislead.",
        "arguments": [],
        "builder": prompt_survey_the_library,
    },
    {
        "name": "set_up_a_level",
        "description": "Assets for a themed level, from packs to exported "
                       "files: pick the pack, pick the build, check before "
                       "exporting.",
        "arguments": [
            {"name": "theme", "required": False,
             "description": "What the level is -- dungeon, city street, "
                            "sci-fi interior."},
            {"name": "engine", "required": False,
             "description": "The project's Unreal version, e.g. 5.4."},
        ],
        "builder": prompt_set_up_a_level,
    },
    {
        "name": "import_a_model",
        "description": "The check to run before importing a model: do its "
                       "textures resolve, is it one model or a sheet or a "
                       "kit, and how big is it really. Needs Atlas open.",
        "arguments": [
            {"name": "asset", "required": False,
             "description": "The model's path or name."},
        ],
        "builder": prompt_import_a_model,
    },
    {
        "name": "animate_a_character",
        "description": "Match animation clips to a character: the rig "
                       "question, which is two questions, and both of them "
                       "decide whether it plays.",
        "arguments": [
            {"name": "character", "required": False,
             "description": "The character's path or name."},
            {"name": "motion", "required": False,
             "description": "What it should do -- idle, walk, attack."},
        ],
        "builder": prompt_animate_a_character,
    },
    {
        "name": "dress_a_character",
        "description": "Find the helmets, hair, capes and other kit that fit "
                       "a character, and what the attach point is and is not.",
        "arguments": [
            {"name": "character", "required": False,
             "description": "The character's path or name."},
        ],
        "builder": prompt_dress_a_character,
    },
    {
        "name": "choose_a_build",
        "description": "Source files or a built Unreal project, and which "
                       "engine version -- the question no file answers.",
        "arguments": [
            {"name": "pack", "required": False,
             "description": "The pack's name."},
            {"name": "engine", "required": False,
             "description": "The project's Unreal version, e.g. 5.4."},
        ],
        "builder": prompt_choose_a_build,
    },
]

PROMPT_BUILDERS = {prompt["name"]: prompt["builder"] for prompt in PROMPTS}
PROMPT_SCHEMAS = [
    {k: v for k, v in prompt.items() if k != "builder"} for prompt in PROMPTS
]


def handle_prompts_get(params):
    name = (params or {}).get("name")
    builder = PROMPT_BUILDERS.get(name)
    if builder is None:
        # Not a tool call, so there is no isError result to put this in: an
        # unknown prompt is a bad request and has to come back as one.
        raise JsonRpcError(-32602, "No such prompt: %s" % name)
    arguments = (params or {}).get("arguments") or {}
    schema = next(p for p in PROMPT_SCHEMAS if p["name"] == name)
    return {
        "description": schema["description"],
        "messages": [{"role": "user",
                      "content": {"type": "text",
                                  "text": builder(arguments)}}],
    }


# ------------------------------------------------------------------ server


def handle_initialize(params):
    asked = (params or {}).get("protocolVersion")
    version = asked if asked in KNOWN_PROTOCOLS else DEFAULT_PROTOCOL
    return {
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": False},
                         "prompts": {"listChanged": False}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "instructions": INSTRUCTIONS,
    }


def handle_tools_call(params):
    name = (params or {}).get("name")
    arguments = (params or {}).get("arguments") or {}
    handler = HANDLERS.get(name)
    if handler is None:
        return {"content": [{"type": "text", "text": "No such tool: %s" % name}],
                "isError": True}
    try:
        return handler(arguments)
    except AtlasError as error:
        return {"content": [{"type": "text", "text": str(error)}], "isError": True}
    except Exception as error:  # noqa: BLE001 - a tool fault is a tool result
        log("tool %s failed: %r" % (name, error))
        return {"content": [{"type": "text",
                             "text": "%s failed: %s" % (name, error)}],
                "isError": True}


def dispatch(method, params):
    if method == "initialize":
        return handle_initialize(params)
    if method == "tools/list":
        return {"tools": TOOL_SCHEMAS}
    if method == "tools/call":
        return handle_tools_call(params)
    if method == "prompts/list":
        return {"prompts": PROMPT_SCHEMAS}
    if method == "prompts/get":
        return handle_prompts_get(params)
    if method == "ping":
        return {}
    raise KeyError(method)


def serve(stdin=None, stdout=None):
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log("ignoring unparseable line")
            continue

        identifier = message.get("id")
        method = message.get("method")
        if method is None:
            continue  # A response to something we never asked.
        try:
            result = dispatch(method, message.get("params"))
        except KeyError:
            if identifier is None:
                continue  # An unknown notification is not an error.
            reply = {"jsonrpc": "2.0", "id": identifier,
                     "error": {"code": -32601, "message": "Unknown method: %s" % method}}
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()
            continue
        except Exception as error:  # noqa: BLE001
            log("dispatch failed: %r" % error)
            if identifier is None:
                continue
            code = getattr(error, "code", -32603)
            reply = {"jsonrpc": "2.0", "id": identifier,
                     "error": {"code": code, "message": str(error)}}
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()
            continue

        if identifier is None:
            continue  # A notification wants no answer.
        stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier,
                                 "result": result}) + "\n")
        stdout.flush()


def main():
    if "--selftest" in sys.argv:
        with open_catalog() as connection:
            total = connection.execute(
                "SELECT count(*) FROM catalog_assets").fetchone()[0]
        print("catalog %s: %d assets" % (DB_PATH, total))
        print("importer: %s" % (IMPORTER_PATH or "NOT FOUND"))
        print("tools: %s" % ", ".join(sorted(HANDLERS)))
        print("prompts: %s" % ", ".join(sorted(PROMPT_BUILDERS)))
        return 0
    log("atlas-mcp serving %s" % DB_PATH)
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
