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
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
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


DB_PATH = os.environ.get("ATLAS_MCP_DB") or _default_db_path()
IMPORTER_PATH = os.environ.get("ATLAS_MCP_IMPORTER") or _default_importer_path()
CACHE_PATH = os.environ.get("ATLAS_MCP_CACHE") or os.path.join(
    os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(),
    "atlas-mcp", "summary-cache.json")


class AtlasError(Exception):
    """Something the caller should be told about rather than a crash."""


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


def effective_type(row):
    """Mirrors AssetItem.effectiveType in lib/main.dart."""
    if row["model_kind"] == "animation":
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


# The search text Atlas builds per asset: name, path and tags, lowercased,
# with separators so a term cannot straddle two fields.
_SEARCH_SQL = (
    "(lower(name) || char(10) || lower(relative_path) || char(10) "
    "|| lower(tags_json))")

TYPE_FILTERS = {
    "all": None,
    "model": "type = 'model' AND (model_kind IS NULL OR model_kind != 'animation')",
    "mesh": "model_kind = 'mesh'",
    "animation": "model_kind = 'animation'",
    "character": "model_kind = 'mesh' AND rig_family IS NOT NULL AND rig_family != 'none'",
    "image": "type = 'image'",
    "audio": "type = 'audio'",
    "unreal": "type = 'unreal'",
    # Resolved in Python, because it depends on a regex over the path.
    "texture": "type = 'image'",
}


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

    query = (arguments.get("query") or "").strip().lower()
    for term in [t for t in query.split(" ") if t]:
        clauses.append("%s LIKE ?" % _SEARCH_SQL)
        params.append("%" + term + "%")

    for field, column in (("pack", "relative_path"), ("folder", "relative_path")):
        value = (arguments.get(field) or "").strip().lower()
        if value:
            clauses.append("lower(%s) LIKE ?" % column)
            params.append("%" + value.replace("\\", "/") + "%")

    ext = (arguments.get("ext") or "").strip().lower().lstrip(".")
    if ext:
        clauses.append("ext = ?")
        params.append(ext)

    return " AND ".join(clauses), params, kind


def rows_for(connection, arguments, limit, offset):
    where, params, kind = build_query(arguments)
    # The texture filter needs the path regex, so over-fetch and sieve.
    fetch = limit if kind != "texture" else max(limit * 4, 200)
    sql = ("SELECT * FROM catalog_assets WHERE %s ORDER BY name LIMIT ? OFFSET ?"
           % where)
    rows = connection.execute(sql, params + [fetch, offset]).fetchall()
    if kind == "texture":
        rows = [r for r in rows if effective_type(r) == "texture"][:limit]
    total = connection.execute(
        "SELECT count(*) FROM catalog_assets WHERE %s" % where, params).fetchone()[0]
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
    with open_catalog() as connection:
        rows, total, kind = rows_for(connection, arguments, limit, offset)

    if not rows:
        hint = ""
        if kind == "character" and total == 0:
            hint = ("\n\nNote: the character filter reads the catalog's "
                    "rig_family column, which is populated lazily as Atlas "
                    "browses and is mostly empty right now. Run "
                    "backfill_rigs.py with Atlas closed to fill it, or ask "
                    "for type=mesh and inspect candidates individually.")
        return text("No assets matched.%s" % hint)

    shown = "\n".join(
        describe_row(row, offset + i + 1) for i, row in enumerate(rows))
    more = ""
    if total > offset + len(rows):
        more = ("\n\n%d of %d shown. Ask again with offset=%d for more."
                % (offset + len(rows), total, offset + len(rows)))
    return text("%d matches.\n\n%s%s" % (total, shown, more))


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
    lines += ["",
              "FBX reader: %s" % (IMPORTER_PATH or "not found"),
              "read cache: %s" % CACHE_PATH]
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


TOOLS = [
    {
        "name": "search_assets",
        "description":
            "Search the Atlas catalog. Terms are ANDed and matched against the "
            "file name, its path and its tags, exactly as the Atlas search box "
            "does, so 'jump fem' finds A_Jump_Running_Femn.fbx.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "Space-separated terms; all must match."},
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
a file name suggests."""


# ------------------------------------------------------------------ server


def handle_initialize(params):
    asked = (params or {}).get("protocolVersion")
    version = asked if asked in KNOWN_PROTOCOLS else DEFAULT_PROTOCOL
    return {
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": False}},
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
            reply = {"jsonrpc": "2.0", "id": identifier,
                     "error": {"code": -32603, "message": str(error)}}
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
        return 0
    log("atlas-mcp serving %s" % DB_PATH)
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
