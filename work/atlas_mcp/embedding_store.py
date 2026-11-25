"""Fixed-stride embedding vectors on disk, with an indexed sidecar.

Measured against the two SQLite alternatives before this was written (see
DECISIONS.md, EMB-001). The deciding number is the full scan: a similarity
search dots the query against every vector, so the hot path is "expose all of
it", not "look one up". Memory-mapping a fixed-stride file does that in 0.3ms
for 42.8MB, where reading the same payload out of BLOB rows costs 111ms --
SQLite stores blobs per row, so a scan pays a copy per row and cannot be
mapped. On disk the same payload is 46.6MB here against 60.3MB.

So vectors live in a flat file and their metadata lives in SQLite, each in the
store that suits it. This module owns both, because the ordering that makes a
crash survivable spans the pair and splitting it across callers is how that
ordering gets broken:

    1. vectors appended past the committed count, then flushed
    2. the header's count raised, then flushed
    3. the index rows committed

A crash between 1 and 2 leaves bytes past `count`, which a reader ignores.
Between 2 and 3 it leaves counted vectors nothing refers to, which waste
space and are harmless. The reverse order would leave index rows pointing at
vectors that do not exist, which is a wrong answer rather than a missing one.

`model_id` is in the header because a different embedding model invalidates
every vector in the file. Opening with a mismatched id reports zero usable
rows rather than silently comparing vectors from two different spaces.

The index also records what could not be embedded. The queue that feeds this
store is derived from it -- whatever has no vector is the work -- so without
somewhere to write a failure, a file that can never be rendered is retried on
every run and the pass never reaches "nothing to do". A count is kept rather
than a flag, because the usual failure is transient.

Standard library only, like the rest of this directory: the MCP server has to
start without a working pip.
"""

import array
import mmap
import os
import sqlite3
import struct

MAGIC = b"ATLASEMB"
FORMAT_VERSION = 1

# magic 8 + version 4 + dims 4 + count 8 + model_id 32 + reserved 8
HEADER_BYTES = 64
_HEADER_STRUCT = struct.Struct("<8sIIQ32s8s")
MODEL_ID_BYTES = 32

BYTES_PER_FLOAT = 4


class EmbeddingStoreError(Exception):
    """The file is not an embedding store, or not one we can read."""


class EmbeddingStore:
    """Append-only float32 vectors, addressed by row, keyed by asset id."""

    def __init__(self, vectors_path, index_path, dims, model_id):
        self.vectors_path = vectors_path
        self.index_path = index_path
        self.dims = dims
        self.model_id = model_id
        self._stride = dims * BYTES_PER_FLOAT
        self._committed = 0
        self._index = None
        self._map = None
        self._view = None

    # ------------------------------------------------------------- opening

    @classmethod
    def create(cls, vectors_path, index_path, dims, model_id):
        """Starts an empty store, replacing anything already at those paths."""
        if dims <= 0:
            raise ValueError("dims must be positive, got %r" % (dims,))
        encoded = model_id.encode("utf-8")
        if len(encoded) > MODEL_ID_BYTES:
            raise ValueError(
                "model_id is %d bytes, over the %d the header holds"
                % (len(encoded), MODEL_ID_BYTES))

        store = cls(vectors_path, index_path, dims, model_id)
        with open(vectors_path, "wb") as handle:
            handle.write(store._header_bytes(0))
            handle.flush()
            os.fsync(handle.fileno())
        if os.path.exists(index_path):
            os.remove(index_path)
        store._open_index(create=True)
        return store

    @classmethod
    def open(cls, vectors_path, index_path, expect_model_id=None):
        """Opens an existing store for reading and appending.

        A file whose `model_id` is not `expect_model_id` opens with zero
        usable rows: the vectors are real but they are in another model's
        space, and comparing across spaces returns confident nonsense.
        """
        with open(vectors_path, "rb") as handle:
            raw = handle.read(HEADER_BYTES)
        if len(raw) < HEADER_BYTES:
            raise EmbeddingStoreError(
                "%s is %d bytes, shorter than a %d byte header"
                % (vectors_path, len(raw), HEADER_BYTES))

        magic, version, dims, count, model_raw, _ = _HEADER_STRUCT.unpack(raw)
        if magic != MAGIC:
            raise EmbeddingStoreError(
                "%s does not start with %r" % (vectors_path, MAGIC))
        if version != FORMAT_VERSION:
            raise EmbeddingStoreError(
                "%s is format version %d, this reads %d"
                % (vectors_path, version, FORMAT_VERSION))
        if dims <= 0:
            raise EmbeddingStoreError(
                "%s claims %d dimensions" % (vectors_path, dims))

        model_id = model_raw.rstrip(b"\0").decode("utf-8", "replace")
        store = cls(vectors_path, index_path, dims, model_id)

        # Whatever the header claims, no row can exist past the end of the
        # file: a write cut short by a crash or a full disk leaves the count
        # ahead of the bytes.
        on_disk = max(os.path.getsize(vectors_path) - HEADER_BYTES, 0)
        store._committed = min(count, on_disk // store._stride)

        if expect_model_id is not None and model_id != expect_model_id:
            store._committed = 0
            store._model_mismatch = True

        store._open_index(create=not os.path.exists(index_path))
        return store

    def _open_index(self, create):
        self._index = sqlite3.connect(self.index_path)
        self._index.execute("PRAGMA journal_mode=WAL")
        if create:
            self._index.execute(
                "CREATE TABLE IF NOT EXISTS embedding_index ("
                "  asset_id TEXT PRIMARY KEY,"
                "  row INTEGER NOT NULL,"
                "  source TEXT NOT NULL,"
                "  computed_ms INTEGER NOT NULL)")
            self._index.commit()
        # Created unconditionally, not only on create: a store written before
        # this table existed must gain it on open rather than raise on the
        # first failure it has to record.
        self._index.execute(
            "CREATE TABLE IF NOT EXISTS embedding_failures ("
            "  asset_id TEXT PRIMARY KEY,"
            "  attempts INTEGER NOT NULL,"
            "  reason TEXT,"
            "  last_ms INTEGER NOT NULL)")
        self._index.commit()

    # ------------------------------------------------------------- writing

    def _header_bytes(self, count):
        return _HEADER_STRUCT.pack(
            MAGIC, FORMAT_VERSION, self.dims, count,
            self.model_id.encode("utf-8"), b"\0" * 8)

    def append(self, entries):
        """Appends `(asset_id, vector, source, computed_ms)` rows.

        Returns the row index of the first one. The three steps below are in
        the order a crash can survive; see the module docstring.
        """
        entries = list(entries)
        if not entries:
            return self._committed

        payload = array.array("f")
        for asset_id, vector, _source, _computed_ms in entries:
            if len(vector) != self.dims:
                raise ValueError(
                    "%s has %d dimensions, the store holds %d"
                    % (asset_id, len(vector), self.dims))
            payload.extend(vector)

        first_row = self._committed
        self._release_map()

        # 1. the vectors, written past the committed count so a reader that
        #    is part way through this call still sees only whole rows.
        with open(self.vectors_path, "r+b") as handle:
            handle.seek(HEADER_BYTES + first_row * self._stride)
            handle.write(payload.tobytes())
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())

            # 2. the count, which is what publishes them.
            handle.seek(0)
            handle.write(self._header_bytes(first_row + len(entries)))
            handle.flush()
            os.fsync(handle.fileno())

        self._committed = first_row + len(entries)

        # 3. the index. Rows already counted but not yet indexed are wasted
        #    space, never a wrong answer.
        self._index.executemany(
            "INSERT OR REPLACE INTO embedding_index VALUES (?,?,?,?)",
            [(asset_id, first_row + offset, source, computed_ms)
             for offset, (asset_id, _vector, source, computed_ms)
             in enumerate(entries)])
        self._index.commit()
        return first_row

    # ------------------------------------------------------------- reading

    @property
    def count(self):
        """Rows that are both counted by the header and present on disk."""
        return self._committed

    def matrix(self):
        """Every committed vector as one `memoryview` of floats.

        This is the search path. The mapping is kept so repeated searches do
        not remap, and released on `close` -- an open mapping holds the file
        open on Windows, exactly as an open zip handle does elsewhere here.
        """
        if self._committed == 0:
            return memoryview(bytearray()).cast("f")
        if self._map is None:
            handle = open(self.vectors_path, "rb")
            try:
                self._map = mmap.mmap(
                    handle.fileno(), 0, access=mmap.ACCESS_READ)
            finally:
                handle.close()
        end = HEADER_BYTES + self._committed * self._stride
        if self._view is None:
            self._view = memoryview(self._map)
        return self._view[HEADER_BYTES:end].cast("f")

    def vector(self, row):
        """One vector, without mapping the whole file."""
        if not 0 <= row < self._committed:
            raise IndexError(
                "row %d outside the %d committed" % (row, self._committed))
        with open(self.vectors_path, "rb") as handle:
            handle.seek(HEADER_BYTES + row * self._stride)
            raw = handle.read(self._stride)
        result = array.array("f")
        result.frombytes(raw)
        return result

    def row_of(self, asset_id):
        """The row holding `asset_id`, or None.

        A row the index names but the header has not published is reported as
        absent: that is the crash window between steps 2 and 3, and the
        vector there may be half written.
        """
        found = self._index.execute(
            "SELECT row FROM embedding_index WHERE asset_id=?",
            (asset_id,)).fetchone()
        if found is None or not 0 <= found[0] < self._committed:
            return None
        return found[0]

    def asset_ids_by_row(self):
        """Row -> asset id for every published row, for reporting results."""
        names = [None] * self._committed
        for asset_id, row in self._index.execute(
                "SELECT asset_id, row FROM embedding_index"):
            if 0 <= row < self._committed:
                names[row] = asset_id
        return names

    def sources_by_row(self):
        """Row -> what the vector was made from, for every published row.

        "render" is a picture drawn from a model; "image" is a file that was
        already a picture. A search uses this to answer about one kind only:
        asked for a material, ranking a model's silhouette alongside it is
        noise, and the other way round for a shape.

        None for a row the index does not name, exactly as asset_ids_by_row,
        so the two are the same length and can be read together.
        """
        sources = [None] * self._committed
        for source, row in self._index.execute(
                "SELECT source, row FROM embedding_index"):
            if 0 <= row < self._committed:
                sources[row] = source
        return sources

    def missing(self, asset_ids):
        """Which of `asset_ids` still need embedding. Drives the queue."""
        return [asset_id for asset_id in asset_ids
                if self.row_of(asset_id) is None]

    # ------------------------------------------------------------ failures

    def record_failure(self, asset_id, reason, when_ms):
        """Note that this asset could not be embedded, and count the attempt.

        Committed one at a time on purpose. A failure recorded only at the
        end of a run would be lost by the interruption that caused it.
        """
        self._index.execute(
            "INSERT INTO embedding_failures (asset_id, attempts, reason, "
            "last_ms) VALUES (?, 1, ?, ?) "
            "ON CONFLICT(asset_id) DO UPDATE SET "
            "  attempts = attempts + 1, reason = excluded.reason, "
            "  last_ms = excluded.last_ms",
            (asset_id, (reason or "")[:500], int(when_ms)))
        self._index.commit()

    def failure_counts(self):
        """asset_id -> attempts, for everything that has ever failed."""
        return {asset_id: attempts for asset_id, attempts
                in self._index.execute(
                    "SELECT asset_id, attempts FROM embedding_failures")}

    def failures(self, limit=50):
        """The worst offenders, for reporting: (asset_id, attempts, reason)."""
        return self._index.execute(
            "SELECT asset_id, attempts, reason FROM embedding_failures "
            "ORDER BY attempts DESC, asset_id LIMIT ?", (int(limit),)
        ).fetchall()

    def clear_failures(self, asset_ids=None):
        """Forget failures, so they are tried again. All of them, or some.

        Returns how many rows were forgotten.
        """
        if asset_ids is None:
            cursor = self._index.execute("DELETE FROM embedding_failures")
        else:
            asset_ids = list(asset_ids)
            if not asset_ids:
                return 0
            cursor = self._index.executemany(
                "DELETE FROM embedding_failures WHERE asset_id = ?",
                [(asset_id,) for asset_id in asset_ids])
        self._index.commit()
        return cursor.rowcount if cursor.rowcount and cursor.rowcount > 0 else 0

    def forget_failure(self, asset_id):
        """Drop one failure record, for an asset that has now succeeded."""
        self._index.execute(
            "DELETE FROM embedding_failures WHERE asset_id = ?", (asset_id,))
        self._index.commit()

    def refresh(self):
        """Pick up rows another process published since this store opened.

        `open` reads the count once, which is right for a pass that owns the
        file and wrong for a search process that outlives one: a server that
        holds a store for an hour while a tagging pass runs would keep
        answering out of the library as it was when it started.

        Safe to call at any time because of the order `append` writes in --
        vectors, then the count, then the index -- so a count read here names
        only rows whose bytes are already on disk. The on-disk clamp stays
        for the same reason `open` has it: a write cut short leaves the count
        ahead of the bytes.

        Returns how many rows were gained, and drops the mapping when there
        are any: a mapping covers the length the file had when it was made,
        so the new rows are not in it.
        """
        if getattr(self, "_model_mismatch", False):
            return 0
        try:
            with open(self.vectors_path, "rb") as handle:
                raw = handle.read(HEADER_BYTES)
            on_disk = max(os.path.getsize(self.vectors_path) - HEADER_BYTES, 0)
        except OSError:
            return 0
        if len(raw) < HEADER_BYTES:
            return 0
        magic, version, dims, count, _model, _spare = _HEADER_STRUCT.unpack(
            raw)
        # A header that no longer agrees with this object is not something to
        # paper over by carrying on with the old count: the file was replaced
        # under us, and saying zero leaves the caller with what it had.
        if magic != MAGIC or version != FORMAT_VERSION or dims != self.dims:
            return 0
        published = min(count, on_disk // self._stride)
        if published <= self._committed:
            return 0
        gained = published - self._committed
        self._committed = published
        self._release_map()
        return gained

    def unmap(self):
        """Drop the mapping but stay open.

        For a process that searches now and then rather than in one pass:
        `matrix` remakes the mapping in microseconds, and not holding one
        between searches leaves the file to whoever is appending to it.
        """
        self._release_map()

    # ------------------------------------------------------------- closing

    def _release_map(self):
        """Drops the mapping, and says so plainly when a caller still holds it.

        `mmap.close` refuses while any `memoryview` over it is alive, with a
        bare `BufferError: cannot close exported pointers exist` naming
        neither the file nor the call to fix. A search holds the matrix for
        as long as it is searching, so this is the ordinary way to meet it,
        not an exotic one.
        """
        if self._view is not None:
            self._view.release()
            self._view = None
        if self._map is not None:
            try:
                self._map.close()
            except BufferError:
                raise EmbeddingStoreError(
                    "%s is still mapped: a memoryview from matrix() is "
                    "alive. Release it (del, or let it fall out of scope) "
                    "before closing, or the file stays open on Windows."
                    % self.vectors_path) from None
            self._map = None

    def close(self):
        self._release_map()
        if self._index is not None:
            self._index.close()
            self._index = None

    def __enter__(self):
        return self

    def __exit__(self, *_exception):
        self.close()
        return False
