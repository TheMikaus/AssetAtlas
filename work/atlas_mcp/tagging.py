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


def candidates(connection, folder=None, pack=None, ext=None):
    """One row per distinct renderable model, in archive order.

    The reasoning behind each clause is in this module's docstring; it is all
    load-bearing and each part was measured.
    """
    where = ["ignored = 0",
             "ext IN (%s)" % ", ".join(["?"] * len(RENDERABLE_EXTS))]
    params = list(RENDERABLE_EXTS)

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
        "referenced_by_model, count(*) AS copies, "
        "group_concat(id, char(10)) AS sibling_ids "
        "FROM catalog_assets WHERE %s "
        "GROUP BY lower(name), size ORDER BY path, relative_path"
        % " AND ".join(where), params).fetchall()

    return [row for row in rows
            if atlas_mcp.effective_type(row) != "animation"]


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
            "assets": [{"asset_id": row["id"],
                        "path": row["path"],
                        "name": row["name"],
                        "relative_path": row["relative_path"]}
                       for row in items],
        }


def work_list(store, connection, folder=None, pack=None, ext=None,
              max_attempts=DEFAULT_MAX_ATTEMPTS, limit=None):
    """The outstanding work, derived from the store rather than remembered.

    Nothing records what is left: whatever has no vector is the job. That is
    what makes an interrupted pass free to resume, and it is why this is a
    query rather than a file.
    """
    rows = candidates(connection, folder=folder, pack=pack, ext=ext)
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
