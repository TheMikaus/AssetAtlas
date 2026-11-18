"""What to render next, and where the vectors go. One copy, two drivers.

There are two things that drive the tagging pass -- tag_assets.py from a
terminal, and Atlas's own background queue -- and they must agree completely
about which assets need work and what counts as done. They are also in
different languages, so the only way they can agree is for one of them not to
decide: everything in this file is reached from Dart by asking
`atlas_embed.py --serve`, not by reimplementing it.

That also settles who writes the store. The crash-safety of embeddings.f32
rests on an ordering that spans the vector file and its index (see
embedding_store.py), and a second writer in another language is how that
ordering gets broken. So the worker owns the store, and a driver only ever
renders pictures and hands them over.

What "needs work" means here, and why each part of it is load-bearing:

  * One row per distinct file, grouped by name and size. 34,801 FBX rows are
    18,948 distinct files; the rest are re-exports per engine version that
    draw the same picture.
  * min(id) for the group, so the representative is the same on every run.
    A bare column let SQLite pick any row in the group and it varied, which
    cost 212 duplicate renders before it was pinned.
  * Done if *any* sibling has a vector, not just the representative. They are
    the same picture, so one answers for all of them, and the rule then
    survives the representative changing.
  * Ordered by path, so consecutive renders hit the same archive. Worth about
    600 ms an asset against a random walk.
  * No animation clips. They hold curves and no geometry, and the renderer
    refuses them -- left in, all 801 would fail every run for ever.

There are two kinds of thing to embed, and the rules above hold for both.
Models are rendered first and the picture is embedded; an image needs no
render because the file is already the picture. They share one store, so a
search can rank a texture and a model against the same words -- and they are
told apart by the `source` column, so a search can also ask for one kind
only.
"""

import os

import atlas_mcp
import embedding_store

# Imported here rather than passed in: these are facts about the model, and
# atlas_embed imports this module lazily so there is no cycle.
from atlas_embed import DIMS, MODEL_ID

# Beside the catalog, like atlas_bridge.json: derived from it, and a catalog
# rebuilt from scratch should leave them obviously stale rather than
# scattered somewhere unrelated.
VECTORS_NAME = "embeddings.f32"
INDEX_NAME = "embeddings_index.sqlite"

# What is worth looking at. Audio has nothing to see; .uasset is unreadable
# outside Unreal, so there is no geometry to draw.
RENDERABLE_EXTS = ("fbx", "obj")

# Images are the other half of the library an eye is useful on: the atlases a
# model is textured with, and the icon sprites. Nothing is drawn for these --
# the file *is* the picture -- so they need no renderer and no Atlas, which is
# why a second driver can embed them while the app is closed.
#
# Every extension here is one PIL opens, which is what atlas_embed decodes
# with. PSD is included because PIL reads the flattened composite layer; a
# PSD with no composite raises there and is recorded as a failure like any
# other unreadable file.
IMAGE_EXTS = ("png", "jpg", "jpeg", "gif", "bmp", "psd")

# A texture is decoded to w*h*4 bytes to be resized to 224, so the file size
# is only a hint at the cost -- but it is the hint available before reading.
# The largest image in this library is a 177 MB PSD; the 99th percentile is
# 2.5 MB. The cap exists so one absurd file cannot take the pass down with a
# MemoryError, and it is recorded as a skip rather than hidden.
MAX_IMAGE_BYTES = 96 * 1024 * 1024

# Paths that are in the catalog because a scan walked a whole Unity project,
# and are not assets by any reading: a package manager's download cache and
# the screenshots in those packages' own documentation. 2,898 distinct images
# sit under these, and they are not harmless -- the first texture query run
# against the store answered with three render-pipeline documentation figures
# and two film-grain overlays, because a photograph of a scuffed floor beats
# a tiling texture of one at looking like a scuffed floor.
#
# Matched on the relative path, lowercased. Deliberately narrow: these two
# names mean exactly one thing, where a rule about "Library" or "Editor"
# would start dropping real assets from packs that happen to use the word.
NON_ASSET_PATH_MARKERS = ("packagecache", "documentation~")

# What a vector was made from, stored beside it. The store has carried this
# column from the start; until now everything in it said "render".
SOURCE_BY_KIND = {"model": "render", "image": "image"}
KINDS = tuple(SOURCE_BY_KIND)

# 224 is the model's input size. Rendering larger is thrown away by the
# resize; smaller loses detail the model could have used.
RENDER_SIZE = 224

# Renders are small -- 3.8 KB mean at 224 px -- so a batch costs nothing to
# hold. Eight matched the embedder's fastest measured rate.
DEFAULT_BATCH = 8

# Attempts before an asset is left alone. The usual failure is transient, so
# a count rather than a flag.
DEFAULT_MAX_ATTEMPTS = 3


def store_paths(db_path=None):
    """Where the vectors and their index live, beside the catalog."""
    catalog_dir = os.path.dirname(db_path or atlas_mcp.DB_PATH)
    return (os.path.join(catalog_dir, VECTORS_NAME),
            os.path.join(catalog_dir, INDEX_NAME))


def open_or_create_store(vectors_path=None, index_path=None):
    """The store, made on first use.

    Opening with expect_model_id is what stops a vector from one model being
    ranked against another's: the header carries the model and open() refuses
    a mismatch instead of returning numbers that mean nothing.
    """
    if vectors_path is None or index_path is None:
        vectors_path, index_path = store_paths()
    if os.path.exists(vectors_path):
        return embedding_store.EmbeddingStore.open(
            vectors_path, index_path, expect_model_id=MODEL_ID)
    return embedding_store.EmbeddingStore.create(
        vectors_path, index_path, dims=DIMS, model_id=MODEL_ID)


def open_catalog_readonly():
    """The catalog, read-only, so Atlas keeps ownership of its own file."""
    return atlas_mcp.open_catalog()


def candidates(connection, folder=None, pack=None, ext=None, kind="model"):
    """One row per distinct asset worth embedding, in archive order.

    The reasoning behind each clause is in this module's docstring; it is all
    load-bearing and each part was measured.

    `kind` picks what is being embedded. Everything else -- the grouping, the
    representative, the ordering -- is the same for both, because it is all
    about duplicate files and archive locality rather than about geometry.
    """
    if kind not in SOURCE_BY_KIND:
        raise ValueError("kind must be one of %s, not %r"
                         % (", ".join(sorted(SOURCE_BY_KIND)), kind))
    wanted_exts = IMAGE_EXTS if kind == "image" else RENDERABLE_EXTS
    where = ["ignored = 0",
             "ext IN (%s)" % ", ".join(["?"] * len(wanted_exts))]
    params = list(wanted_exts)

    if kind == "image":
        # Only for images: a package cache holds almost no models, and the
        # few it holds are no worse than anything else to look at.
        for marker in NON_ASSET_PATH_MARKERS:
            where.append("lower(relative_path) NOT LIKE ?")
            params.append("%" + marker + "%")

    if ext:
        where.append("ext = ?")
        params.append(ext.lower().lstrip("."))
    if folder:
        where.append("lower(relative_path) LIKE ?")
        params.append("%" + folder.lower().replace("\\", "/") + "%")
    if pack:
        where.append("lower(path) LIKE ?")
        params.append("%" + pack.lower() + "%")

    rows = connection.execute(
        # referenced_by_model is selected although these are all models and
        # effective_type short-circuits before reading it: relying on the
        # order of those checks would make this break on a reordering
        # somewhere else entirely.
        "SELECT min(id) AS id, path, name, relative_path, model_kind, type, "
        "size, referenced_by_model, count(*) AS copies, "
        "group_concat(id, char(10)) AS sibling_ids "
        "FROM catalog_assets WHERE %s "
        "GROUP BY lower(name), size ORDER BY path, relative_path"
        % " AND ".join(where), params).fetchall()

    if kind == "image":
        # The animation test below is about geometry, and asking it of a PNG
        # would only invite a classifier change to start dropping textures.
        return rows
    return [row for row in rows
            if atlas_mcp.effective_type(row) != "animation"]


def asset_ids_matching(connection, folder=None, pack=None):
    """Every asset id whose path matches, as a set, for narrowing a search.

    Not `candidates`: that answers "what still needs embedding" and returns
    one representative per duplicate group, where a search narrows over
    whatever is already in the store -- which may be any sibling of such a
    group, whichever one the pass happened to reach first.

    The clauses are the same two `candidates` uses, so "that pack" means the
    same thing to a search as it does to a pass.
    """
    where = []
    params = []
    if folder:
        where.append("lower(relative_path) LIKE ?")
        params.append("%" + folder.lower().replace("\\", "/") + "%")
    if pack:
        where.append("lower(path) LIKE ?")
        params.append("%" + pack.lower() + "%")
    if not where:
        return None
    return {row[0] for row in connection.execute(
        "SELECT id FROM catalog_assets WHERE %s" % " AND ".join(where),
        params)}


def group_ids(row):
    """Every asset id in a candidate's duplicate group."""
    joined = row["sibling_ids"] or row["id"]
    return [asset_id for asset_id in joined.split("\n") if asset_id]


def group_is_done(store, row):
    """Whether any member of this duplicate group already has a vector."""
    return any(store.row_of(asset_id) is not None
               for asset_id in group_ids(row))


def group_is_hopeless(row, failure_counts, max_attempts):
    """Whether every member of this group has failed too often to try again.

    Every member, not any: one sibling failing says little, because the other
    copy may well read fine.
    """
    if max_attempts <= 0:
        return False
    return all(failure_counts.get(asset_id, 0) >= max_attempts
               for asset_id in group_ids(row))


class WorkList:
    """What is left to do, and what has already happened.

    Counted as well as listed, because a driver has to be able to show
    progress without walking the whole catalog itself -- and because
    "31,495 selected, 264 done" is the only honest way to describe a job
    whose queue is derived rather than stored.
    """

    def __init__(self, selected, done, given_up, pending):
        self.selected = selected
        self.done = done
        self.given_up = given_up
        self.pending = pending

    @property
    def remaining(self):
        return len(self.pending)

    def as_dict(self, limit=None):
        items = self.pending if limit is None else self.pending[:limit]
        return {
            "selected": self.selected,
            "done": self.done,
            "given_up": self.given_up,
            "remaining": self.remaining,
            # size is here for the image driver, which refuses a file too big
            # to decode *before* reading it -- checking afterwards would mean
            # holding the thing it is trying not to hold.
            "assets": [{"asset_id": row["id"],
                        "path": row["path"],
                        "name": row["name"],
                        "relative_path": row["relative_path"],
                        "size": row["size"]}
                       for row in items],
        }


def work_list(store, connection, folder=None, pack=None, ext=None,
              max_attempts=DEFAULT_MAX_ATTEMPTS, limit=None, kind="model"):
    """The outstanding work, derived from the store rather than remembered.

    Nothing records what is left: whatever has no vector is the job. That is
    what makes an interrupted pass free to resume, and it is why this is a
    query rather than a file.

    Models and images share one store and one failure table, and they do not
    collide: the queue is derived per asset id, so a model with a vector says
    nothing about the texture beside it.
    """
    rows = candidates(connection, folder=folder, pack=pack, ext=ext,
                      kind=kind)
    failure_counts = store.failure_counts()

    outstanding = [row for row in rows if not group_is_done(store, row)]
    worth_trying = [row for row in outstanding
                    if not group_is_hopeless(row, failure_counts,
                                             max_attempts)]
    given_up = len(outstanding) - len(worth_trying)
    # The limit is applied last, so `remaining` describes a batch while the
    # three counts above still describe the whole job.
    pending = (worth_trying if limit is None else worth_trying[:limit])

    return WorkList(selected=len(rows),
                    done=len(rows) - len(outstanding),
                    given_up=given_up,
                    pending=pending)
