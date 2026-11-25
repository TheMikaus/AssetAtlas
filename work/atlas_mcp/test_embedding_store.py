"""Tests for embedding_store, run as: python test_embedding_store.py

The cases that matter are the ones a crash makes: a count ahead of the bytes,
an index ahead of the count, and a file written by a different embedding
model. Each of those returns a wrong answer rather than an error if the store
trusts what it is told, which is why they are here rather than in a comment.
"""

import array
import os
import shutil
import struct
import sqlite3
import tempfile
import unittest

from embedding_store import (
    EmbeddingStore,
    EmbeddingStoreError,
    HEADER_BYTES,
    MAGIC,
    _HEADER_STRUCT,
)

DIMS = 8
MODEL = "siglip2-b16"


def vector(seed):
    return array.array("f", [float(seed + index) for index in range(DIMS)])


def entry(asset_id, seed, source="render"):
    return (asset_id, vector(seed), source, 1234)


class StoreTest(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="atlas_emb_")
        self.vectors = os.path.join(self.root, "embeddings.f32")
        self.index = os.path.join(self.root, "embeddings_index.sqlite")
        self.store = None

    def tearDown(self):
        # An open mapping holds the file open on Windows, so nothing can be
        # deleted until it is released -- the same rule as the zip cache.
        if self.store is not None:
            self.store.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def fresh(self, dims=DIMS, model_id=MODEL):
        self.store = EmbeddingStore.create(
            self.vectors, self.index, dims, model_id)
        return self.store

    def reopen(self, expect_model_id=MODEL):
        if self.store is not None:
            self.store.close()
        self.store = EmbeddingStore.open(
            self.vectors, self.index, expect_model_id=expect_model_id)
        return self.store

    # ------------------------------------------------------- the happy path

    def test_a_new_store_is_empty_but_readable(self):
        store = self.fresh()
        self.assertEqual(store.count, 0)
        self.assertEqual(len(store.matrix()), 0)

    def test_appended_vectors_come_back_unchanged(self):
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        self.assertEqual(store.count, 2)
        self.assertEqual(list(store.vector(0)), list(vector(1)))
        self.assertEqual(list(store.vector(1)), list(vector(2)))

    def test_append_returns_the_first_row_it_wrote(self):
        store = self.fresh()
        self.assertEqual(store.append([entry("a", 1)]), 0)
        self.assertEqual(store.append([entry("b", 2), entry("c", 3)]), 1)

    def test_the_matrix_is_every_vector_end_to_end(self):
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        flat = list(store.matrix())
        self.assertEqual(flat, list(vector(1)) + list(vector(2)))

    def test_an_asset_is_found_by_id(self):
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        self.assertEqual(store.row_of("b"), 1)
        self.assertIsNone(store.row_of("never-embedded"))

    def test_rows_map_back_to_asset_ids(self):
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        self.assertEqual(store.asset_ids_by_row(), ["a", "b"])

    def test_missing_reports_what_the_queue_still_owes(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        self.assertEqual(store.missing(["a", "b", "c"]), ["b", "c"])

    def test_an_empty_append_changes_nothing(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        self.assertEqual(store.append([]), 1)
        self.assertEqual(store.count, 1)

    def test_re_embedding_an_asset_points_it_at_the_new_row(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        store.append([entry("a", 9)])
        self.assertEqual(store.row_of("a"), 1)
        self.assertEqual(list(store.vector(store.row_of("a"))),
                         list(vector(9)))

    def test_a_store_survives_being_closed_and_reopened(self):
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        store = self.reopen()
        self.assertEqual(store.count, 2)
        self.assertEqual(store.row_of("b"), 1)
        self.assertEqual(list(store.vector(0)), list(vector(1)))

    def test_appending_after_a_reopen_continues_the_file(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        store = self.reopen()
        self.assertEqual(store.append([entry("b", 2)]), 1)
        self.assertEqual(store.count, 2)
        self.assertEqual(store.asset_ids_by_row(), ["a", "b"])

    # --------------------------------------------------- what a crash leaves

    def test_a_count_ahead_of_the_bytes_is_clamped(self):
        # The crash window between writing vectors and raising the count,
        # seen from the other side: the header says five, the file holds two.
        # Trusting the header hands out vectors made of whatever follows.
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        store.close()
        self.store = None

        with open(self.vectors, "r+b") as handle:
            magic, version, dims, _count, model, reserved = (
                _HEADER_STRUCT.unpack(handle.read(HEADER_BYTES)))
            handle.seek(0)
            handle.write(_HEADER_STRUCT.pack(
                magic, version, dims, 5, model, reserved))

        store = self.reopen()
        self.assertEqual(store.count, 2)
        self.assertEqual(list(store.matrix()),
                         list(vector(1)) + list(vector(2)))

    def test_a_half_written_row_is_not_published(self):
        # A write cut off mid-vector leaves a partial row. It must not be
        # counted: half a vector scores against a query like any other.
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        store.close()
        self.store = None

        with open(self.vectors, "r+b") as handle:
            handle.truncate(HEADER_BYTES + DIMS * 4 + 4)

        store = self.reopen()
        self.assertEqual(store.count, 1)
        self.assertEqual(list(store.vector(0)), list(vector(1)))

    def test_an_index_row_past_the_count_reads_as_absent(self):
        # The crash window between raising the count and committing the
        # index, inverted: an index entry whose vector was never published.
        store = self.fresh()
        store.append([entry("a", 1)])
        store.close()
        self.store = None

        connection = sqlite3.connect(self.index)
        connection.execute(
            "INSERT INTO embedding_index VALUES ('ghost', 7, 'render', 0)")
        connection.commit()
        connection.close()

        store = self.reopen()
        self.assertIsNone(store.row_of("ghost"))
        self.assertEqual(store.missing(["ghost"]), ["ghost"])

    def test_an_unindexed_published_row_wastes_space_but_answers(self):
        # The same window the other way: vectors counted, index not yet
        # committed. The row is real and readable; nothing names it.
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        store.close()
        self.store = None

        connection = sqlite3.connect(self.index)
        connection.execute("DELETE FROM embedding_index WHERE asset_id='b'")
        connection.commit()
        connection.close()

        store = self.reopen()
        self.assertEqual(store.count, 2)
        self.assertIsNone(store.row_of("b"))
        self.assertEqual(list(store.vector(1)), list(vector(2)))
        self.assertEqual(store.asset_ids_by_row(), ["a", None])

    # ------------------------------------------------------ wrong-file cases

    def test_a_different_model_makes_the_store_read_as_empty(self):
        # Vectors from two models are not comparable, and comparing them
        # returns a confident ranking rather than an error. So a mismatch
        # means re-embed, not reinterpret.
        store = self.fresh()
        store.append([entry("a", 1)])
        store.close()
        self.store = None

        store = self.reopen(expect_model_id="some-other-model")
        self.assertEqual(store.count, 0)
        self.assertEqual(store.missing(["a"]), ["a"])

    def test_opening_without_an_expectation_reports_the_model_it_has(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        store.close()
        self.store = None

        self.store = EmbeddingStore.open(self.vectors, self.index)
        self.assertEqual(self.store.model_id, MODEL)
        self.assertEqual(self.store.count, 1)

    def test_a_foreign_file_is_refused_rather_than_misread(self):
        with open(self.vectors, "wb") as handle:
            handle.write(b"PNG\r\n\x1a\n" + b"\0" * 120)
        with self.assertRaises(EmbeddingStoreError) as caught:
            EmbeddingStore.open(self.vectors, self.index)
        self.assertIn(str(MAGIC), str(caught.exception))

    def test_a_truncated_header_is_refused(self):
        with open(self.vectors, "wb") as handle:
            handle.write(MAGIC + b"\0" * 4)
        with self.assertRaises(EmbeddingStoreError):
            EmbeddingStore.open(self.vectors, self.index)

    def test_a_future_format_version_is_refused(self):
        self.fresh().close()
        self.store = None
        with open(self.vectors, "r+b") as handle:
            magic, _version, dims, count, model, reserved = (
                _HEADER_STRUCT.unpack(handle.read(HEADER_BYTES)))
            handle.seek(0)
            handle.write(_HEADER_STRUCT.pack(
                magic, 99, dims, count, model, reserved))
        with self.assertRaises(EmbeddingStoreError) as caught:
            EmbeddingStore.open(self.vectors, self.index)
        self.assertIn("99", str(caught.exception))

    # ---------------------------------------------------------- bad arguments

    def test_a_wrong_length_vector_is_refused_by_name(self):
        store = self.fresh()
        with self.assertRaises(ValueError) as caught:
            store.append([("odd-one", array.array("f", [1.0, 2.0]), "render", 0)])
        self.assertIn("odd-one", str(caught.exception))

    def test_nothing_is_written_when_a_vector_is_refused(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        with self.assertRaises(ValueError):
            store.append([entry("b", 2),
                          ("bad", array.array("f", [1.0]), "render", 0)])
        self.assertEqual(store.count, 1)
        self.assertIsNone(store.row_of("b"))

    def test_a_model_id_too_long_for_the_header_is_refused(self):
        with self.assertRaises(ValueError):
            EmbeddingStore.create(self.vectors, self.index, DIMS, "m" * 40)

    def test_zero_dimensions_is_refused(self):
        with self.assertRaises(ValueError):
            EmbeddingStore.create(self.vectors, self.index, 0, MODEL)

    def test_a_row_outside_the_store_is_an_index_error(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        with self.assertRaises(IndexError):
            store.vector(1)
        with self.assertRaises(IndexError):
            store.vector(-1)

    # --------------------------------------------------------------- shape

    def test_the_header_is_the_size_the_layout_claims(self):
        # 8 magic + 4 version + 4 dims + 8 count + 32 model_id + 8 reserved.
        # Exactly, not merely within: slack between the struct and
        # HEADER_BYTES would be bytes the writer never sets and a later
        # format version might read as meaningful.
        self.assertEqual(_HEADER_STRUCT.size, 64)
        self.assertEqual(_HEADER_STRUCT.size, HEADER_BYTES)

    def test_vectors_start_on_the_header_boundary(self):
        store = self.fresh()
        store.append([entry("a", 1)])
        store.close()
        self.store = None
        self.assertEqual(os.path.getsize(self.vectors),
                         HEADER_BYTES + DIMS * 4)

    def test_the_store_closes_its_mapping_so_the_file_can_be_replaced(self):
        # Windows keeps a mapped file open. The zip cache learned this the
        # hard way; a tagger that pinned its own output would be its own bug.
        store = self.fresh()
        store.append([entry("a", 1)])
        store.matrix()
        store.close()
        self.store = None
        os.remove(self.vectors)
        self.assertFalse(os.path.exists(self.vectors))

    def test_a_matrix_held_in_a_local_still_lets_the_store_close(self):
        # The version above discards the matrix, so the view is collected
        # before close and the bug hid. Holding it in a variable and then
        # dropping it is what a search actually does, and it used to fail
        # with "BufferError: cannot close exported pointers exist".
        store = self.fresh()
        store.append([entry("a", 1), entry("b", 2)])
        matrix = store.matrix()
        self.assertEqual(len(matrix), 2 * DIMS)
        del matrix
        store.close()
        self.store = None
        os.remove(self.vectors)

    def test_closing_while_a_matrix_is_alive_names_the_cause(self):
        # Unavoidable -- a view the caller holds cannot be revoked -- so the
        # error has to say which call to fix rather than report a bare
        # BufferError from inside mmap.
        store = self.fresh()
        store.append([entry("a", 1)])
        matrix = store.matrix()
        with self.assertRaises(EmbeddingStoreError) as caught:
            store.close()
        message = str(caught.exception)
        self.assertIn("matrix()", message)
        self.assertIn(os.path.basename(self.vectors), message)
        del matrix
        store.close()
        self.store = None

    def test_appending_while_a_matrix_is_alive_names_the_cause(self):
        # append releases the mapping too, because it rewrites the header
        # the mapping covers.
        store = self.fresh()
        store.append([entry("a", 1)])
        matrix = store.matrix()
        with self.assertRaises(EmbeddingStoreError):
            store.append([entry("b", 2)])
        del matrix
        store.append([entry("b", 2)])
        self.assertEqual(store.count, 2)

    def test_an_empty_store_hands_back_a_float_view(self):
        # Zero rows is the ordinary state on a first run, and the caller
        # should not have to special-case the element type.
        store = self.fresh()
        matrix = store.matrix()
        self.assertEqual(len(matrix), 0)
        self.assertEqual(matrix.format, "f")


if __name__ == "__main__":
    unittest.main(verbosity=1)
