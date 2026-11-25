"""Tests for the visual tagging pass and the embedder.

Split by what they cost. Everything here that does not need the SigLIP files
runs always: the tokenizer contract, the ranking maths, the candidate query,
the resume rule. The handful that do load a 55 MB or 270 MB ONNX session skip
themselves when the files are absent, because the models are not in the
repository -- a checkout without them should still be able to run the suite
and find out that the rest is sound.

Run: python -m unittest test_tagging
"""

import base64
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import atlas_embed
import embedding_store
import tag_assets
import tag_images
import tagging


def models_present():
    return all(os.path.exists(os.path.join(atlas_embed.MODEL_DIR, name))
               for name in (atlas_embed.VISION_MODEL, atlas_embed.TEXT_MODEL,
                            atlas_embed.TOKENIZER))


needs_models = unittest.skipUnless(
    models_present(),
    "the SigLIP files are not in %s; see README.md" % atlas_embed.MODEL_DIR)

try:
    import numpy as _numpy
except ImportError:
    _numpy = None

needs_numpy = unittest.skipUnless(_numpy is not None, "numpy is not installed")


class EmbedderContractTest(unittest.TestCase):
    """The constants the store and the model have to agree on.

    A mismatch here is not a crash, it is silently wrong numbers: a vector
    written at the wrong width, or ranked against a model that did not
    produce it.
    """

    def test_the_model_id_fits_the_store_header(self):
        # _HEADER_STRUCT reserves 32 bytes. A longer id would be truncated on
        # write and then fail to match on read, for no visible reason.
        self.assertLessEqual(len(atlas_embed.MODEL_ID.encode("utf-8")), 32)

    def test_the_dimensions_match_what_the_pass_writes(self):
        self.assertEqual(atlas_embed.DIMS, 768)
        self.assertEqual(tagging.DIMS, atlas_embed.DIMS)

    def test_the_vision_model_is_not_the_int8_build(self):
        # vision_model_int8.onnx contains ConvInteger(10), for which
        # onnxruntime ships no CPU kernel: it fails at session load with
        # NOT_IMPLEMENTED. Naming it here keeps it from being chosen back.
        self.assertNotIn("int8", atlas_embed.VISION_MODEL)

    def test_the_render_size_is_the_model_input_size(self):
        # Rendering larger is thrown away by the resize; smaller loses detail.
        self.assertEqual(tagging.RENDER_SIZE, atlas_embed.IMAGE_SIZE)

    def test_only_formats_with_geometry_are_rendered(self):
        # Audio has nothing to see and .uasset is unreadable outside Unreal,
        # so neither can produce a picture to embed. The list may only hold
        # formats Atlas itself can turn into triangles -- it is the renderer,
        # and a format it cannot read fails every asset of that kind on every
        # run for ever.
        self.assertEqual(set(tagging.RENDERABLE_EXTS),
                         {"fbx", "obj", "stl"})

    def test_the_formats_not_rendered_are_the_ones_atlas_cannot_read(self):
        # DAE and GLB are in the catalog as models and are deliberately
        # absent: 3,045 and 3,035 files that nothing here can draw yet.
        for ext in ("dae", "glb", "blend", "uasset", "wav"):
            self.assertNotIn(ext, tagging.RENDERABLE_EXTS)

    def test_the_default_thread_count_leaves_the_machine_usable(self):
        # The whole point of the queue is that it runs behind an interactive
        # app. onnxruntime defaults to every core it can see.
        self.assertLessEqual(atlas_embed.DEFAULT_THREADS, 2)


class TokenizerTest(unittest.TestCase):
    """The text side of the contract, from tokenizer_config.json."""

    @needs_models
    def setUp(self):
        self.embedder = atlas_embed.Embedder()

    def test_it_pads_to_the_models_window(self):
        ids = self.embedder._token_ids("a grungy metal barrel")
        self.assertEqual(len(ids), atlas_embed.TEXT_TOKENS)

    def test_it_ends_with_eos_then_padding(self):
        # add_eos_token is true and padding_side is right.
        ids = self.embedder._token_ids("barrel")
        self.assertIn(atlas_embed._EOS_ID, ids)
        tail = ids[ids.index(atlas_embed._EOS_ID) + 1:]
        self.assertTrue(all(value == atlas_embed._PAD_ID for value in tail))

    def test_case_is_folded(self):
        # do_lower_case is true, so these must tokenize identically.
        self.assertEqual(self.embedder._token_ids("BARREL"),
                         self.embedder._token_ids("barrel"))

    def test_an_overlong_phrase_is_truncated_not_refused(self):
        ids = self.embedder._token_ids("barrel " * 200)
        self.assertEqual(len(ids), atlas_embed.TEXT_TOKENS)
        self.assertEqual(ids[-1], atlas_embed._EOS_ID)

    def test_an_empty_phrase_still_produces_a_window(self):
        ids = self.embedder._token_ids("")
        self.assertEqual(len(ids), atlas_embed.TEXT_TOKENS)


class RankingTest(unittest.TestCase):
    """The maths that turns vectors into an order."""

    @needs_numpy
    def setUp(self):
        self.numpy = _numpy

    def test_a_cosine_with_itself_is_one(self):
        vectors = self.numpy.asarray([[3.0, 4.0], [1.0, 0.0]],
                                     dtype=self.numpy.float32)
        scores = atlas_embed.rank_against(self.numpy, vectors, vectors[0])
        self.assertAlmostEqual(float(scores[0]), 1.0, places=5)

    def test_length_does_not_affect_the_score(self):
        # Only direction carries meaning; a brighter render must not rank
        # higher for being brighter.
        vectors = self.numpy.asarray([[1.0, 0.0], [100.0, 0.0]],
                                     dtype=self.numpy.float32)
        scores = atlas_embed.rank_against(self.numpy, vectors, vectors[0])
        self.assertAlmostEqual(float(scores[0]), float(scores[1]), places=5)

    def test_opposite_directions_rank_last(self):
        vectors = self.numpy.asarray([[1.0, 0.0], [-1.0, 0.0]],
                                     dtype=self.numpy.float32)
        scores = atlas_embed.rank_against(self.numpy, vectors, vectors[0])
        self.assertLess(float(scores[1]), float(scores[0]))

    def test_a_zero_vector_scores_zero_rather_than_nan(self):
        # A NaN would sort unpredictably instead of last, so one bad row
        # would scramble the whole ranking rather than sitting at the bottom.
        vectors = self.numpy.asarray([[0.0, 0.0], [1.0, 0.0]],
                                     dtype=self.numpy.float32)
        scores = atlas_embed.rank_against(self.numpy, vectors, vectors[1])
        self.assertFalse(bool(self.numpy.isnan(scores).any()))
        self.assertEqual(float(scores[0]), 0.0)


class CandidateQueryTest(unittest.TestCase):
    """Which assets the pass picks, and in what order.

    Both matter for the cost: collapsing duplicates removes 45% of the work,
    and walking in archive order was worth 600 ms an asset over a random one.
    """

    SCHEMA = (
        "CREATE TABLE catalog_assets ("
        " id TEXT PRIMARY KEY, name TEXT, path TEXT, relative_path TEXT,"
        " ext TEXT, type TEXT, size INTEGER, ignored INTEGER DEFAULT 0,"
        " model_kind TEXT, rig_family TEXT, referenced_by_model INTEGER"
        " DEFAULT 0, tags_json TEXT)")

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(self.SCHEMA)

    def tearDown(self):
        self.connection.close()

    def add(self, asset_id, name, path, relative_path, ext="fbx", size=100,
            ignored=0):
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, tags_json) VALUES (?,?,?,?,?,?,?,?,'[]')",
            (asset_id, name, path, relative_path, ext, "model", size,
             ignored))

    def ids(self, **kwargs):
        return [row["id"] for row in
                tagging.candidates(self.connection, **kwargs)]

    def test_identical_copies_collapse_to_one_render(self):
        # Same name and size in two engine builds is the same picture. This
        # is 34,801 FBX rows becoming 18,948 renders.
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        chosen = self.ids()
        self.assertEqual(len(chosen), 1)

    def test_a_different_size_is_a_different_file(self):
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx",
                 size=100)
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx",
                 size=200)
        self.assertEqual(len(self.ids()), 2)

    def test_the_representative_is_the_same_on_every_run(self):
        # A bare id lets SQLite pick any row in the group, and it varies:
        # 212 vectors had been written where only 101 counted as done,
        # because a later run chose a different sibling and rendered it
        # again. min(id) pins it.
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.assertEqual(self.ids(), self.ids())
        self.assertEqual(self.ids(), ["a"])

    def test_the_bare_columns_come_from_the_chosen_row(self):
        # SQLite guarantees this only while exactly one min() or max() is in
        # the select. If that ever stops holding, the path would describe a
        # different file from the id and the wrong asset would be rendered
        # under the right name.
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        row = tagging.candidates(self.connection)[0]
        self.assertEqual(row["id"], "a")
        self.assertEqual(row["path"], "zip:p1.zip::Barrel.fbx")

    def test_every_id_in_the_group_comes_back(self):
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        row = tagging.candidates(self.connection)[0]
        self.assertEqual(sorted(tagging.group_ids(row)), ["a", "b"])

    def test_the_copy_count_comes_back(self):
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        rows = tagging.candidates(self.connection)
        self.assertEqual(rows[0]["copies"], 2)

    def test_ignored_assets_are_not_rendered(self):
        self.add("a", "Keep.fbx", "zip:p.zip::Keep.fbx", "p/Keep.fbx")
        self.add("b", "Skip.fbx", "zip:p.zip::Skip.fbx", "p/Skip.fbx",
                 ignored=1)
        self.assertEqual(self.ids(), ["a"])

    def test_formats_with_no_geometry_are_skipped(self):
        self.add("a", "Model.fbx", "zip:p.zip::Model.fbx", "p/Model.fbx")
        self.add("b", "Sound.wav", "zip:p.zip::Sound.wav", "p/Sound.wav",
                 ext="wav")
        self.add("c", "Built.uasset", "zip:p.zip::Built.uasset",
                 "p/Built.uasset", ext="uasset")
        self.assertEqual(self.ids(), ["a"])

    def test_animation_clips_are_not_rendered(self):
        # The renderer refuses them -- "has no geometry to draw: it is an
        # animation" -- so left in, all 801 would fail every run for ever.
        self.add("a", "SM_Barrel.fbx", "zip:p.zip::SM_Barrel.fbx",
                 "p/Models/SM_Barrel.fbx")
        self.add("b", "A_Run.fbx", "zip:p.zip::A_Run.fbx",
                 "p/Animations/A_Run.fbx")
        self.assertEqual(self.ids(), ["a"])

    def test_a_probed_mesh_in_an_animation_folder_is_still_rendered(self):
        # The folder rule is a fallback; a probed answer outranks it.
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, model_kind, tags_json)"
            " VALUES ('a','SM_Hull.fbx','zip:p.zip::SM_Hull.fbx',"
            "'p/Animations/SM_Hull.fbx','fbx','model',100,0,'mesh','[]')")
        self.assertEqual(self.ids(), ["a"])

    def test_a_probed_clip_outside_an_animation_folder_is_skipped(self):
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, model_kind, tags_json)"
            " VALUES ('a','Run.fbx','zip:p.zip::Run.fbx',"
            "'p/Models/Run.fbx','fbx','model',100,0,'animation','[]')")
        self.assertEqual(self.ids(), [])

    def test_obj_is_rendered_too(self):
        self.add("a", "Thing.obj", "zip:p.zip::Thing.obj", "p/Thing.obj",
                 ext="obj")
        self.assertEqual(self.ids(), ["a"])

    def test_it_walks_in_archive_order(self):
        # Consecutive renders from one archive measured 972 ms against
        # 1,570 ms jumping between them, so the ordering is load-bearing.
        self.add("b", "B.fbx", "zip:second.zip::B.fbx", "s/B.fbx")
        self.add("a", "A.fbx", "zip:first.zip::A.fbx", "f/A.fbx")
        self.add("c", "C.fbx", "zip:first.zip::C.fbx", "f/C.fbx")
        self.assertEqual(self.ids(), ["a", "c", "b"])

    def test_a_folder_slice_narrows_it(self):
        self.add("a", "A.fbx", "zip:p.zip::A.fbx", "Town/Props/A.fbx")
        self.add("b", "B.fbx", "zip:p.zip::B.fbx", "Castle/Props/B.fbx")
        self.assertEqual(self.ids(folder="town"), ["a"])

    def test_a_folder_slice_accepts_windows_separators(self):
        self.add("a", "A.fbx", "zip:p.zip::A.fbx", "Town/Props/A.fbx")
        self.assertEqual(self.ids(folder="town\\props"), ["a"])

    def test_a_pack_slice_matches_the_archive(self):
        self.add("a", "A.fbx", "zip:POLYGON_Town.zip::A.fbx", "t/A.fbx")
        self.add("b", "B.fbx", "zip:POLYGON_Castle.zip::B.fbx", "c/B.fbx")
        self.assertEqual(self.ids(pack="polygon_town"), ["a"])

    def test_an_ext_slice_narrows_within_the_renderable_set(self):
        self.add("a", "A.fbx", "zip:p.zip::A.fbx", "p/A.fbx")
        self.add("b", "B.obj", "zip:p.zip::B.obj", "p/B.obj", ext="obj")
        self.assertEqual(self.ids(ext="obj"), ["b"])
        self.assertEqual(self.ids(ext=".OBJ"), ["b"])


class ResumeTest(unittest.TestCase):
    """The queue is derived from the store, which is what makes it resumable.

    Nothing records what is left to do. Whatever has no vector is the work,
    so an interrupted run loses at most the batch in flight -- and that only
    because the store publishes a batch at a time.
    """

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="atlas-tagging-test-")
        self.store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"),
            dims=4, model_id="test-model")

    def tearDown(self):
        self.store.close()

    def test_everything_is_missing_from_an_empty_store(self):
        self.assertEqual(self.store.missing(["a", "b"]), ["a", "b"])

    def test_what_was_stored_is_no_longer_missing(self):
        self.store.append([("a", [1.0, 0.0, 0.0, 0.0], "render", 1)])
        self.assertEqual(self.store.missing(["a", "b"]), ["b"])

    def test_a_vector_on_any_sibling_counts_for_the_group(self):
        # The same file by name and size draws the same picture, so one
        # vector answers for all of them -- and the queue then survives the
        # representative changing.
        row = {"id": "a", "sibling_ids": chr(10).join(["a", "b"])}
        self.assertFalse(tagging.group_is_done(self.store, row))
        self.store.append([("b", [1.0, 0.0, 0.0, 0.0], "render", 1)])
        self.assertTrue(tagging.group_is_done(self.store, row))

    def test_a_group_of_one_still_works(self):
        row = {"id": "solo", "sibling_ids": "solo"}
        self.assertFalse(tagging.group_is_done(self.store, row))
        self.store.append([("solo", [0.0, 1.0, 0.0, 0.0], "render", 1)])
        self.assertTrue(tagging.group_is_done(self.store, row))

    def test_a_missing_sibling_list_falls_back_to_the_id(self):
        # group_concat returns NULL for an empty group, and a row built by
        # hand may not carry the column at all.
        row = {"id": "solo", "sibling_ids": None}
        self.assertEqual(tagging.group_ids(row), ["solo"])

    def test_the_order_of_the_remaining_work_is_kept(self):
        # candidates() returns archive order, and missing() has to preserve
        # it or the locality that ordering bought is thrown away.
        self.store.append([("b", [0.0, 1.0, 0.0, 0.0], "render", 1)])
        self.assertEqual(self.store.missing(["a", "b", "c", "d"]),
                         ["a", "c", "d"])


class FailureRecordTest(unittest.TestCase):
    """Why a failure has to be written down at all.

    The queue is derived from the store: whatever has no vector is the work.
    With nowhere to record a failure, a file that can never be rendered is
    selected on every run for ever, and the pass never reaches "nothing to
    do" -- which over an overnight job restarted a few times is the
    difference between finishing and not.
    """

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="atlas-fail-test-")
        self.store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"),
            dims=4, model_id="test-model")

    def tearDown(self):
        self.store.close()

    def row(self, asset_id, siblings=None):
        return {"id": asset_id,
                "sibling_ids": chr(10).join(siblings or [asset_id])}

    def test_nothing_has_failed_to_begin_with(self):
        self.assertEqual(self.store.failure_counts(), {})

    def test_a_failure_is_counted(self):
        self.store.record_failure("a", "boom", 1)
        self.assertEqual(self.store.failure_counts(), {"a": 1})

    def test_attempts_accumulate_across_runs(self):
        # Each run is a separate process, so this has to survive reopening.
        for _ in range(3):
            self.store.record_failure("a", "boom", 1)
        self.assertEqual(self.store.failure_counts()["a"], 3)

    def test_the_reason_is_kept_and_the_latest_wins(self):
        self.store.record_failure("a", "first reason", 1)
        self.store.record_failure("a", "second reason", 2)
        rows = self.store.failures()
        self.assertEqual(rows[0][2], "second reason")

    def test_a_very_long_reason_does_not_bloat_the_index(self):
        self.store.record_failure("a", "x" * 5000, 1)
        self.assertLessEqual(len(self.store.failures()[0][2]), 500)

    def test_a_group_is_given_up_on_only_when_every_member_has(self):
        # One sibling failing says little -- the other copy may read fine.
        counts = {"a": 3}
        row = self.row("a", ["a", "b"])
        self.assertFalse(tagging.group_is_hopeless(row, counts, 3))
        counts["b"] = 3
        self.assertTrue(tagging.group_is_hopeless(row, counts, 3))

    def test_below_the_limit_it_is_still_tried(self):
        row = self.row("a")
        self.assertFalse(tagging.group_is_hopeless(row, {"a": 2}, 3))
        self.assertTrue(tagging.group_is_hopeless(row, {"a": 3}, 3))

    def test_zero_attempts_means_never_give_up(self):
        row = self.row("a")
        self.assertFalse(tagging.group_is_hopeless(row, {"a": 99}, 0))

    def test_success_clears_the_record(self):
        # A file that failed twice and then worked must not keep the two
        # attempts against it, or a later run gives up on something fine.
        self.store.record_failure("a", "boom", 1)
        self.store.record_failure("a", "boom", 2)
        self.store.forget_failure("a")
        self.assertEqual(self.store.failure_counts(), {})

    def test_retrying_forgets_every_failure(self):
        self.store.record_failure("a", "boom", 1)
        self.store.record_failure("b", "boom", 1)
        self.assertEqual(self.store.clear_failures(), 2)
        self.assertEqual(self.store.failure_counts(), {})

    def test_the_table_appears_on_a_store_written_without_it(self):
        # A store from before this existed has to gain the table on open,
        # rather than raise on the first failure it has to record.
        vectors_path, index_path = self.store.vectors_path, self.store.index_path
        self.store.record_failure("a", "boom", 1)
        self.store.close()
        reopened = embedding_store.EmbeddingStore.open(
            vectors_path, index_path, expect_model_id="test-model")
        try:
            self.assertEqual(reopened.failure_counts(), {"a": 1})
        finally:
            reopened.close()
        self.store = embedding_store.EmbeddingStore.open(
            vectors_path, index_path, expect_model_id="test-model")


class ForceTest(unittest.TestCase):
    """Redoing what is already embedded.

    A vector is a picture of a model as Atlas drew it on the day. When the
    way Atlas draws changes -- the pack's own texture, found where the file
    named none -- the old vectors are pictures of something else, and
    nothing in the store can say which. Without this the queue reports
    "nothing to do" for a library that is entirely out of date, which is
    exactly what it did report.
    """

    SCHEMA = (
        "CREATE TABLE catalog_assets ("
        " id TEXT PRIMARY KEY, name TEXT, path TEXT, relative_path TEXT,"
        " ext TEXT, type TEXT, size INTEGER, ignored INTEGER DEFAULT 0,"
        " model_kind TEXT, rig_family TEXT, referenced_by_model INTEGER"
        " DEFAULT 0, tags_json TEXT)")

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(self.SCHEMA)
        for index, name in enumerate(["SM_Crate_01.fbx", "SM_Barrel_01.fbx",
                                      "SM_Crate_02.fbx"]):
            self.connection.execute(
                "INSERT INTO catalog_assets (id, name, path, relative_path,"
                " ext, type, size, ignored, tags_json)"
                " VALUES (?,?,?,?,'fbx','model',?,0,'[]')",
                ("a%d" % index, name, "zip:p.zip::%s" % name,
                 "p/%s" % name, 100 + index))
        self.directory = tempfile.mkdtemp(prefix="atlas-force-")
        self.store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"),
            dims=4, model_id="test-model")

    def tearDown(self):
        self.store.close()
        self.connection.close()

    def work(self, **kwargs):
        return tagging.work_list(self.store, self.connection, **kwargs)

    def embed_everything(self):
        self.store.append([
            (row["id"], [0.1, 0.2, 0.3, 0.4], "render", 1)
            for row in tagging.candidates(self.connection)
        ])

    def test_an_embedded_library_has_nothing_to_do(self):
        self.embed_everything()
        work = self.work()
        self.assertEqual(work.as_dict()["remaining"], 0)
        self.assertEqual(work.as_dict()["done"], work.as_dict()["selected"])

    def test_force_takes_them_all_again(self):
        self.embed_everything()
        work = self.work(force=True).as_dict()
        self.assertEqual(work["remaining"], work["selected"])
        self.assertGreater(work["remaining"], 0)

    def test_force_still_respects_the_limit(self):
        self.embed_everything()
        self.assertEqual(self.work(force=True, limit=2)
                         .as_dict()["remaining"], 2)

    def test_force_is_not_the_default(self):
        self.embed_everything()
        self.assertEqual(self.work().as_dict()["remaining"], 0)

    def test_force_on_an_empty_store_changes_nothing(self):
        before = self.work().as_dict()["remaining"]
        self.assertEqual(self.work(force=True).as_dict()["remaining"], before)


class InterruptedRunTest(unittest.TestCase):
    """What survives stopping the pass part way through.

    The whole design rests on this: an 8-hour job nobody can resume is a job
    nobody will start. Driven with fakes rather than signals -- `timeout -s
    INT` under Git Bash never reached the Python child and the run completed
    all forty, which would have made this test a no-op.
    """

    SCHEMA = (
        "CREATE TABLE catalog_assets ("
        " id TEXT PRIMARY KEY, name TEXT, path TEXT, relative_path TEXT,"
        " ext TEXT, type TEXT, size INTEGER, ignored INTEGER DEFAULT 0,"
        " model_kind TEXT, rig_family TEXT, referenced_by_model INTEGER"
        " DEFAULT 0, tags_json TEXT)")

    TOTAL = 10

    class Arguments:
        folder = pack = ext = None
        limit = None
        batch = 4
        threads = 1
        pace_ms = 0
        dry_run = False
        max_attempts = 3
        retry_failed = False
        force = False
        ids_file = None

    class FakeWorker:
        """Stands in for the child process, not for the queue.

        Everything that decides anything -- which assets are outstanding,
        what counts as done, what a failure costs -- is delegated to the real
        store and the real tagging.work_list, so these tests exercise the
        queue rather than a reimplementation of it. Only the model is faked,
        because loading it would make every test below take a second.
        """

        def __init__(self, _threads, vectors_path, index_path):
            self.store = tagging.open_or_create_store(vectors_path,
                                                      index_path)
            self.image_calls = 0

        def ask(self, op, **message):
            if op == "next":
                limit = message.get("limit")
                with tagging.open_catalog_readonly() as connection:
                    work = tagging.work_list(
                        self.store, connection,
                        folder=message.get("folder"),
                        pack=message.get("pack"),
                        ext=message.get("ext"),
                        max_attempts=int(
                            message.get("max_attempts")
                            or tagging.DEFAULT_MAX_ATTEMPTS),
                        limit=None if limit is None else int(limit),
                        force=bool(message.get("force")))
                reply = {"ok": True}
                reply.update(work.as_dict())
                return reply
            if op == "images":
                self.image_calls += 1
                entries = message.get("entries") or []
                now = 0
                # The real width, because the store's header refuses
                # anything else -- which is the guard working.
                self.store.append([
                    (entry["asset_id"],
                     [float(index)] + [0.0] * (atlas_embed.DIMS - 1),
                     "render", now)
                    for index, entry in enumerate(entries)])
                for entry in entries:
                    self.store.forget_failure(entry["asset_id"])
                return {"ok": True, "stored": len(entries),
                        "count": self.store.count, "ms": 0}
            if op == "failed":
                for entry in message.get("entries") or []:
                    self.store.record_failure(
                        entry["asset_id"], entry.get("reason") or "", 0)
                return {"ok": True,
                        "recorded": len(message.get("entries") or [])}
            if op == "retry":
                return {"ok": True,
                        "forgotten": self.store.clear_failures()}
            raise AssertionError("the driver asked for an op nobody "
                                 "implements: %r" % op)

        def close(self):
            self.store.close()

    def setUp(self):
        import atlas_mcp
        self.atlas_mcp = atlas_mcp
        self.directory = tempfile.mkdtemp(prefix="atlas-interrupt-test-")
        self.previous_db = atlas_mcp.DB_PATH
        atlas_mcp.DB_PATH = os.path.join(self.directory, "catalog.db")

        connection = sqlite3.connect(atlas_mcp.DB_PATH)
        connection.execute(self.SCHEMA)
        for index in range(self.TOTAL):
            name = "SM_Thing_%02d.fbx" % index
            connection.execute(
                "INSERT INTO catalog_assets (id, name, path, relative_path,"
                " ext, type, size, tags_json)"
                " VALUES (?,?,?,?,'fbx','model',?, '[]')",
                ("id:%02d" % index, name, "K:/lib/" + name,
                 "pack/" + name, 100 + index))
        connection.commit()
        connection.close()

        self.previous_version = atlas_mcp.bridge_version
        self.previous_render = tag_assets.render
        self.previous_worker = tag_assets.Worker
        atlas_mcp.bridge_version = lambda: "test"
        tag_assets.Worker = self.FakeWorker

    def tearDown(self):
        self.atlas_mcp.bridge_version = self.previous_version
        tag_assets.render = self.previous_render
        tag_assets.Worker = self.previous_worker
        self.atlas_mcp.DB_PATH = self.previous_db

    def set_render(self, behaviour):
        tag_assets.render = behaviour

    def run_pass(self):
        out = io.StringIO()
        code = tag_assets.run(self.Arguments(), out)
        return code, out.getvalue()

    def stored(self):
        store = tagging.open_or_create_store()
        try:
            return store.count, store.failure_counts()
        finally:
            store.close()

    def renders_then(self, count, error):
        """A render that works `count` times, then raises `error`."""
        state = {"calls": 0}

        def behaviour(row):
            state["calls"] += 1
            if state["calls"] > count:
                raise error
            return b"png-%s" % row["asset_id"].encode("ascii")

        return behaviour

    # ------------------------------------------------------- the baseline

    def test_an_uninterrupted_run_stores_everything(self):
        self.set_render(lambda row: b"png")
        code, body = self.run_pass()
        self.assertEqual(code, 0)
        count, failures = self.stored()
        self.assertEqual(count, self.TOTAL)
        self.assertEqual(failures, {})
        self.assertIn("%d embedded" % self.TOTAL, body)

    def test_the_final_progress_line_is_not_printed_twice(self):
        # 8 divides by a batch of 4, so the loop flushes the last batch and
        # the tail had nothing left to do.
        self.Arguments.limit = 8
        try:
            self.set_render(lambda row: b"png")
            _code, body = self.run_pass()
            lines = [line for line in body.splitlines() if "8/8" in line]
            self.assertEqual(len(lines), 1, body)
        finally:
            self.Arguments.limit = None

    # ---------------------------------------------------- the interruption

    def test_ctrl_c_keeps_the_batch_in_flight(self):
        # This is the point. Six renders into a batch of four means one full
        # batch flushed and two in hand; discarding those two threw away work
        # for no reason, since a partial batch is exactly as safe to append.
        self.set_render(self.renders_then(6, KeyboardInterrupt()))
        code, body = self.run_pass()
        self.assertEqual(code, 0)
        count, _failures = self.stored()
        self.assertEqual(count, 6)
        self.assertIn("Stopped", body)
        self.assertIn("rerun to continue", body)

    def test_a_dead_embedder_is_handled_like_an_interruption(self):
        # It dies in flush(), which is where EmbedderProcess.ask raises, not
        # in render(). Injecting it through render() was what exposed the
        # blame bug below, but it is not how this actually happens.
        class DyingWorker(InterruptedRunTest.FakeWorker):
            def ask(self, op, **message):
                if op == "next":
                    return InterruptedRunTest.FakeWorker.ask(
                        self, op, **message)
                raise RuntimeError("the embedder stopped answering")

        tag_assets.Worker = DyingWorker
        self.set_render(lambda row: b"png")
        code, body = self.run_pass()
        self.assertEqual(code, 0)
        self.assertIn("embedder stopped", body)
        # Nothing was stored, and crucially nothing was blamed: the files
        # were never the problem.
        count, failures = self.stored()
        self.assertEqual(count, 0)
        self.assertEqual(failures, {})

    def test_atlas_vanishing_mid_run_blames_nothing(self):
        # The bug this exists for: a render failure was charged to the file
        # whatever the cause, so Atlas being closed half way through would
        # charge every remaining asset an attempt, and three such runs would
        # retire thousands of files that are perfectly fine.
        state = {"alive": True}
        self.atlas_mcp.bridge_version = lambda: "test" if state["alive"] else None

        def dies_after_six(row):
            if len(state) > 1 or row["asset_id"] >= "id:06":
                state["alive"] = False
                raise RuntimeError("connection refused")
            return b"png"

        self.set_render(dies_after_six)
        code, body = self.run_pass()
        self.assertEqual(code, 0)
        self.assertIn("Atlas stopped answering", body)
        count, failures = self.stored()
        self.assertEqual(count, 6)
        self.assertEqual(failures, {},
                         "no asset should carry an attempt for this")

    def test_the_six_already_rendered_are_still_kept(self):
        # Stopping without blame must not also mean stopping without saving.
        state = {"alive": True}
        self.atlas_mcp.bridge_version = lambda: "test" if state["alive"] else None

        def dies_after_six(row):
            if row["asset_id"] >= "id:06":
                state["alive"] = False
                raise RuntimeError("connection refused")
            return b"png"

        self.set_render(dies_after_six)
        self.run_pass()
        self.assertEqual(self.stored()[0], 6)

        # And the next run picks up exactly where it left off.
        state["alive"] = True
        self.set_render(lambda row: b"png")
        _code, body = self.run_pass()
        self.assertIn("6 already embedded", body)
        self.assertEqual(self.stored()[0], self.TOTAL)

    def test_a_long_run_of_failures_stops_rather_than_retiring_everything(self):
        # Atlas answering but refusing everything looks exactly like a
        # library of broken models. It is not, and the difference matters
        # because the wrong reading is permanent.
        # The real threshold is 25, which this fixture is too small to
        # reach; lowering it here tests the mechanism rather than the number.
        previous = tag_assets.GIVE_UP_AFTER_CONSECUTIVE
        tag_assets.GIVE_UP_AFTER_CONSECUTIVE = 4
        try:
            self.set_render(self.renders_then(0, RuntimeError("refused")))
            code, body = self.run_pass()
            self.assertEqual(code, 0)
            self.assertIn("systemic", body)
            # Fewer than the whole run were blamed: it stopped early.
            self.assertLess(len(self.stored()[1]), self.TOTAL)
        finally:
            tag_assets.GIVE_UP_AFTER_CONSECUTIVE = previous

    def test_a_single_bad_file_among_good_ones_is_still_blamed(self):
        # The guards must not swallow the ordinary case they were built
        # around: one unreadable file in a working library.
        def one_bad(row):
            if row["asset_id"] == "id:03":
                raise RuntimeError("has no geometry to draw")
            return b"png"

        self.set_render(one_bad)
        self.run_pass()
        count, failures = self.stored()
        self.assertEqual(count, self.TOTAL - 1)
        self.assertEqual(list(failures), ["id:03"])

    def test_an_interrupted_run_resumes_where_it_stopped(self):
        self.set_render(self.renders_then(6, KeyboardInterrupt()))
        self.run_pass()
        self.assertEqual(self.stored()[0], 6)

        self.set_render(lambda row: b"png")
        _code, body = self.run_pass()
        self.assertIn("6 already embedded", body)
        self.assertEqual(self.stored()[0], self.TOTAL)

    def test_nothing_is_rendered_twice_across_the_two_runs(self):
        self.set_render(self.renders_then(6, KeyboardInterrupt()))
        self.run_pass()
        seen = []

        def counting(row):
            seen.append(row["asset_id"])
            return b"png"

        self.set_render(counting)
        self.run_pass()
        self.assertEqual(len(seen), self.TOTAL - 6)
        self.assertEqual(len(set(seen)), len(seen))

    def test_a_second_run_after_a_complete_one_does_nothing(self):
        self.set_render(lambda row: b"png")
        self.run_pass()
        _code, body = self.run_pass()
        self.assertIn("Nothing to do", body)

    # -------------------------------------------------------- the failures

    def test_a_render_failure_is_recorded_and_the_run_continues(self):
        def flaky(row):
            if row["asset_id"] == "id:03":
                raise RuntimeError("has no geometry to draw")
            return b"png"

        self.set_render(flaky)
        _code, body = self.run_pass()
        count, failures = self.stored()
        self.assertEqual(count, self.TOTAL - 1)
        self.assertEqual(list(failures), ["id:03"])
        self.assertIn("1 failed", body)

    def test_a_failure_is_retried_until_the_limit_then_dropped(self):
        def always_fails(row):
            if row["asset_id"] == "id:03":
                raise RuntimeError("broken")
            return b"png"

        self.set_render(always_fails)
        for expected_attempts in (1, 2, 3):
            self.run_pass()
            self.assertEqual(self.stored()[1].get("id:03"), expected_attempts)

        # Three strikes: it is no longer selected, and the run says so.
        _code, body = self.run_pass()
        self.assertEqual(self.stored()[1].get("id:03"), 3)
        self.assertIn("given up", body)

    def test_retry_failed_puts_them_back_in_the_queue(self):
        def always_fails(row):
            if row["asset_id"] == "id:03":
                raise RuntimeError("broken")
            return b"png"

        self.set_render(always_fails)
        for _ in range(3):
            self.run_pass()
        self.Arguments.retry_failed = True
        try:
            _code, body = self.run_pass()
            self.assertIn("forgotten", body)
            # Tried again, and failed again, so it is back to one attempt.
            self.assertEqual(self.stored()[1].get("id:03"), 1)
        finally:
            self.Arguments.retry_failed = False

    def test_a_failure_that_later_succeeds_loses_its_record(self):
        state = {"fail": True}

        def recovers(row):
            if row["asset_id"] == "id:03" and state["fail"]:
                raise RuntimeError("busy")
            return b"png"

        self.set_render(recovers)
        self.run_pass()
        self.assertEqual(self.stored()[1].get("id:03"), 1)
        state["fail"] = False
        self.run_pass()
        self.assertEqual(self.stored()[1], {})
        self.assertEqual(self.stored()[0], self.TOTAL)

    def test_atlas_being_closed_is_reported_rather_than_crashed(self):
        self.atlas_mcp.bridge_version = lambda: None
        self.set_render(lambda row: b"png")
        code, body = self.run_pass()
        self.assertEqual(code, 2)
        self.assertIn("not running", body)
        self.assertEqual(self.stored()[0], 0)


class IdsFileTest(InterruptedRunTest):
    """Re-embedding exactly the assets on a list.

    A forced pass over this library is tens of hours and most of it would
    be work for nothing: the pictures that changed are the models whose
    file named no texture. Those can be listed in a few minutes from the
    importer's own probe, and the pass takes the list.

    Inherits the driver harness above: the same fake worker, the same real
    store and real work_list.
    """

    def ids_file(self, ids):
        path = os.path.join(self.directory, "ids.txt")
        with io.open(path, "w", encoding="utf-8", newline="\n") as handle:
            for asset_id in ids:
                handle.write(asset_id + "\n")
        return path

    def run_with(self, **overrides):
        arguments = self.Arguments()
        for name, value in overrides.items():
            setattr(arguments, name, value)
        out = io.StringIO()
        code = tag_assets.run(arguments, out)
        return code, out.getvalue()

    def test_only_the_listed_assets_are_embedded(self):
        self.set_render(lambda row: b"png")
        wanted = ["id:03", "id:07"]
        code, body = self.run_with(ids_file=self.ids_file(wanted))
        self.assertEqual(code, 0)
        count, _failures = self.stored()
        self.assertEqual(count, 2, body)

    def test_it_says_how_many_of_the_ids_it_found(self):
        self.set_render(lambda row: b"png")
        _code, body = self.run_with(
            ids_file=self.ids_file(["id:01", "id:02", "not-in-this-catalog"]))
        self.assertIn("ids file", body)
        self.assertIn("3 ids", body)
        self.assertIn("2 of them", body)

    def test_an_empty_list_does_nothing_rather_than_everything(self):
        self.set_render(lambda row: b"png")
        _code, body = self.run_with(ids_file=self.ids_file([]))
        count, _failures = self.stored()
        self.assertEqual(count, 0, body)

    def test_the_limit_still_applies_on_top(self):
        self.set_render(lambda row: b"png")
        self.run_with(ids_file=self.ids_file(["id:01", "id:02", "id:03"]),
                      limit=2)
        count, _failures = self.stored()
        self.assertEqual(count, 2)

    def test_it_redoes_what_is_already_embedded_when_forced(self):
        self.set_render(lambda row: b"png")
        path = self.ids_file(["id:05"])
        self.run_with(ids_file=path)
        before, _ = self.stored()
        # Without force the asset is done and the list selects nothing.
        self.run_with(ids_file=path)
        self.assertEqual(self.stored()[0], before)
        # With it, the picture is taken again.
        self.run_with(ids_file=path, force=True)
        self.assertEqual(self.stored()[0], before + 1)


class DurationTest(unittest.TestCase):
    """Progress reporting, which is the only window into an 8.7 hour job."""

    def test_short_waits_are_seconds(self):
        self.assertEqual(tag_assets.format_duration(45), "45 s")

    def test_medium_waits_are_minutes(self):
        self.assertEqual(tag_assets.format_duration(600), "10 min")

    def test_long_waits_are_hours(self):
        self.assertEqual(tag_assets.format_duration(31392), "8.7 h")

    def test_the_boundaries_do_not_read_absurdly(self):
        # "90 s" and "5400 s" would both be true and useless.
        self.assertEqual(tag_assets.format_duration(89), "89 s")
        self.assertEqual(tag_assets.format_duration(91), "2 min")
        self.assertEqual(tag_assets.format_duration(5401), "1.5 h")


class StorePathTest(unittest.TestCase):
    def test_the_pass_and_the_server_agree_on_where_the_store_is(self):
        # Two modules compute these paths. Disagreeing would mean the pass
        # writes vectors the server never finds, with no error anywhere.
        import atlas_mcp
        self.assertEqual(tagging.store_paths(),
                         atlas_mcp.embedding_store_paths())

    def test_it_sits_beside_the_catalog(self):
        import atlas_mcp
        vectors_path, index_path = tagging.store_paths()
        catalog_dir = os.path.dirname(atlas_mcp.DB_PATH)
        self.assertEqual(os.path.dirname(vectors_path), catalog_dir)
        self.assertEqual(os.path.dirname(index_path), catalog_dir)


class ServeProtocolTest(unittest.TestCase):
    """The protocol both drivers speak, exercised without the model.

    A driver blocked on a pipe that will never answer is the worst failure
    mode here, so the first rule is that every line gets a reply -- a
    malformed one, an unknown op, or a handler that raised.
    """

    class FakeEmbedder:
        numpy = None

        def prepare_images(self, pngs):
            # Everything decodes, nothing is rejected: what this fake is for
            # is the protocol, and the real decode has its own tests.
            return [(position, None) for position in range(len(pngs))], []

        def embed_prepared(self, prepared):
            return [[0.0] * atlas_embed.DIMS for _ in prepared]

        def embed_images(self, pngs):
            return [[0.0] * atlas_embed.DIMS for _ in pngs]

        def embed_text(self, phrases):
            return [[1.0] * atlas_embed.DIMS for _ in phrases]

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="atlas-serve-test-")

    def serve(self, lines, with_store=False):
        out = io.StringIO()
        paths = {}
        if with_store:
            paths = {
                "vectors_path": os.path.join(self.directory, "v.f32"),
                "index_path": os.path.join(self.directory, "i.sqlite"),
            }
        atlas_embed.run_serve(
            self.FakeEmbedder(), iter(lines), out, **paths)
        return [json.loads(line) for line in
                out.getvalue().strip().splitlines()]

    def test_ping_names_the_model(self):
        replies = self.serve(['{"op": "ping"}'])
        self.assertTrue(replies[0]["ok"])
        self.assertEqual(replies[0]["model_id"], atlas_embed.MODEL_ID)

    def test_an_unknown_op_is_refused_by_name(self):
        replies = self.serve(['{"op": "sing"}'])
        self.assertFalse(replies[0]["ok"])
        self.assertIn("sing", replies[0]["error"])

    def test_an_unreadable_line_still_gets_a_reply(self):
        replies = self.serve(["not json"])
        self.assertFalse(replies[0]["ok"])

    def test_blank_lines_are_skipped_without_a_reply(self):
        # One reply per request, or the driver's reads fall out of step with
        # its writes and every answer afterwards is the wrong one.
        replies = self.serve(["", '{"op": "ping"}', "   "])
        self.assertEqual(len(replies), 1)

    def test_replies_come_back_in_order(self):
        replies = self.serve(['{"op": "ping"}', '{"op": "nope"}',
                              '{"op": "ping"}'])
        self.assertEqual([reply["ok"] for reply in replies],
                         [True, False, True])

    def test_an_entry_with_no_image_is_refused_not_crashed(self):
        replies = self.serve(['{"op": "images", "entries": [{"asset_id": "a"}]}'])
        self.assertFalse(replies[0]["ok"])
        self.assertIn("png", replies[0]["error"])

    def test_text_with_no_phrases_is_refused(self):
        replies = self.serve(['{"op": "text", "phrases": []}'])
        self.assertFalse(replies[0]["ok"])

    def test_an_entry_with_no_asset_id_is_refused(self):
        # The worker stores these itself, so a picture with no name to store
        # it under is not something to guess at.
        replies = self.serve(
            [json.dumps({"op": "images",
                         "entries": [{"png": "aGk="}]})],
            with_store=True)
        self.assertFalse(replies[0]["ok"])
        self.assertIn("asset_id", replies[0]["error"])

    def test_the_store_ops_refuse_without_a_store(self):
        # The worker owns the store but does not guess where the catalog is,
        # and saying so beats inventing a path beside the script.
        for op in ("next", "images", "failed", "retry"):
            with self.subTest(op=op):
                replies = self.serve([json.dumps(
                    {"op": op, "entries": [{"asset_id": "a",
                                            "png": "aGk="}]})])
                self.assertFalse(replies[0]["ok"])
                self.assertIn("--vectors", replies[0]["error"])

    def test_ping_says_whether_it_has_a_store(self):
        # A driver can then fail usefully at startup instead of on its first
        # batch, twenty minutes of rendering later.
        self.assertFalse(self.serve(['{"op": "ping"}'])[0]["store"])
        self.assertTrue(
            self.serve(['{"op": "ping"}'], with_store=True)[0]["store"])

    def test_images_appends_rather_than_returning_vectors(self):
        # The store is only crash-safe while one writer keeps an ordering
        # that spans two files, so the worker holds the pen and a driver
        # never sees the numbers.
        replies = self.serve([json.dumps({
            "op": "images",
            "entries": [{"asset_id": "a", "png": "aGk="},
                        {"asset_id": "b", "png": "aGk="}]})],
            with_store=True)
        self.assertTrue(replies[0]["ok"])
        self.assertEqual(replies[0]["stored"], 2)
        self.assertEqual(replies[0]["count"], 2)
        self.assertNotIn("vectors", replies[0])

    def test_a_failure_is_recorded_and_can_be_forgotten(self):
        replies = self.serve([
            json.dumps({"op": "failed",
                        "entries": [{"asset_id": "a", "reason": "boom"}]}),
            json.dumps({"op": "retry"}),
        ], with_store=True)
        self.assertEqual(replies[0]["recorded"], 1)
        self.assertEqual(replies[1]["forgotten"], 1)

    def test_text_needs_no_store(self):
        # A search embeds a phrase and writes nothing, so it must work
        # against a library that has never been tagged.
        replies = self.serve(['{"op": "text", "phrases": ["grungy"]}'])
        self.assertTrue(replies[0]["ok"])
        self.assertEqual(len(replies[0]["vectors"][0]), atlas_embed.DIMS)


class ModelRunTest(unittest.TestCase):
    """One real inference each way. Slow, and skipped without the files."""

    @needs_models
    @needs_numpy
    def setUp(self):
        self.embedder = atlas_embed.Embedder(threads=1)

    def test_an_image_embeds_to_the_stored_width(self):
        png = atlas_embed._blank_png(self.embedder)
        vectors = self.embedder.embed_images([png])
        self.assertEqual(len(vectors), 1)
        self.assertEqual(len(vectors[0]), atlas_embed.DIMS)

    def test_a_batch_comes_back_in_order_and_whole(self):
        png = atlas_embed._blank_png(self.embedder)
        vectors = self.embedder.embed_images([png] * 3)
        self.assertEqual(len(vectors), 3)

    def test_unrelated_phrases_do_not_embed_alike(self):
        # The failure this catches is a tower that loads and then does not
        # really run -- it returns the same vector for everything, and every
        # ranking afterwards is arbitrary but looks plausible.
        vectors = self.embedder.embed_text(
            ["a grungy rusted metal barrel", "a clean white marble column"])
        scores = atlas_embed.rank_against(
            _numpy, _numpy.stack(vectors), vectors[0])
        self.assertAlmostEqual(float(scores[0]), 1.0, places=4)
        self.assertLess(float(scores[1]), 0.95)

    def test_transparency_is_flattened_onto_white(self):
        # Atlas renders on transparency. PIL's RGB conversion drops alpha to
        # black, which turns every silhouette into a dark blob and makes
        # unrelated models embed alike.
        from PIL import Image
        buffer = io.BytesIO()
        Image.new("RGBA", (8, 8), (0, 0, 0, 0)).save(buffer, format="PNG")
        pixels = self.embedder._pixels(buffer.getvalue())
        # White is 1.0 after the rescale and normalise; black would be -1.0.
        self.assertAlmostEqual(float(pixels.max()), 1.0, places=5)
        self.assertGreater(float(pixels.min()), 0.5)


class FindSimilarTest(unittest.TestCase):
    """The tool, over a store built by hand.

    Vectors are chosen so the order is known in advance: the query is row 0,
    and every other row is a measured distance from it. That makes a wrong
    ranking a failure rather than something to squint at.
    """

    SCHEMA = (
        "CREATE TABLE catalog_assets ("
        " id TEXT PRIMARY KEY, name TEXT, path TEXT, relative_path TEXT,"
        " source_root TEXT, source_name TEXT, ext TEXT, type TEXT,"
        " size INTEGER, modified_ms INTEGER, tags_json TEXT,"
        " ignored INTEGER DEFAULT 0, model_kind TEXT,"
        " referenced_by_model INTEGER DEFAULT 0, rig_family TEXT)")

    # (asset_id, name, size, vector). Two rows share a name and differ in
    # size, which is the Unreal_Characters re-export case: separate files,
    # one picture.
    ASSETS = (
        ("id:hero-a", "SK_Hero.fbx", 1000, [1.0, 0.0, 0.0, 0.0]),
        ("id:hero-b", "SK_Hero.fbx", 2000, [0.99, 0.01, 0.0, 0.0]),
        ("id:near", "SM_Barrel.fbx", 3000, [0.8, 0.6, 0.0, 0.0]),
        ("id:far", "SM_Cloud.fbx", 4000, [0.0, 0.0, 1.0, 0.0]),
    )

    @staticmethod
    def path_of(asset_id, name):
        # A distinct path per row. Giving two rows the same path made
        # _find_row offer a choice between two identical paths, which is
        # advice nobody can act on -- and cannot happen in the real catalog,
        # where the path is what identifies a file.
        return "K:/lib/%s/%s" % (asset_id.split(":")[-1], name)

    def setUp(self):
        import atlas_mcp
        self.atlas_mcp = atlas_mcp
        self.directory = tempfile.mkdtemp(prefix="atlas-similar-test-")
        self.previous_db = atlas_mcp.DB_PATH
        atlas_mcp.DB_PATH = os.path.join(self.directory, "catalog.db")

        connection = sqlite3.connect(atlas_mcp.DB_PATH)
        connection.execute(self.SCHEMA)
        for asset_id, name, size, _vector in self.ASSETS:
            connection.execute(
                "INSERT INTO catalog_assets (id, name, path, relative_path,"
                " source_root, source_name, ext, type, size, modified_ms,"
                " tags_json) VALUES (?,?,?,?,?,?,?,?,?,?,'[]')",
                (asset_id, name, self.path_of(asset_id, name),
                 "pack/" + asset_id.split(":")[-1] + "/" + name,
                 "K:/lib", "lib", "fbx", "model", size, 0))
        connection.commit()
        connection.close()

    def tearDown(self):
        self.atlas_mcp.DB_PATH = self.previous_db

    def build_store(self):
        vectors_path, index_path = self.atlas_mcp.embedding_store_paths()
        store = embedding_store.EmbeddingStore.create(
            vectors_path, index_path, dims=4,
            model_id=atlas_embed.MODEL_ID)
        store.append([(asset_id, vector, "render", 0)
                      for asset_id, _name, _size, vector in self.ASSETS])
        store.close()

    def body_of(self, result):
        self.assertFalse(result.get("isError"),
                         result["content"][0].get("text"))
        return result["content"][0]["text"]

    @staticmethod
    def ranked_lines(body):
        """Only the numbered result lines.

        Counting a name in the whole report counts it twice: once in its own
        line and once in the path underneath, which ends with the filename.
        """
        return [line.strip() for line in body.splitlines()
                if line[:4].strip().rstrip(".").isdigit()]

    def ranked_names(self, body):
        return [line.split("  ")[1] for line in self.ranked_lines(body)]

    # --------------------------------------------------- without a store

    def test_with_no_store_it_says_what_to_run(self):
        # The one thing a caller can do about it is run the pass, so the
        # message has to name it rather than reporting an absent file.
        with self.assertRaises(self.atlas_mcp.AtlasError) as caught:
            self.atlas_mcp.run_visual_search(phrase="grungy")
        message = str(caught.exception)
        self.assertIn("tag_assets.py", message)
        self.assertIn("no visual embeddings", message)

    def test_embeddings_present_is_false_before_the_pass_runs(self):
        self.assertFalse(self.atlas_mcp.embeddings_present())
        self.build_store()
        self.assertTrue(self.atlas_mcp.embeddings_present())

    # ------------------------------------------------------- bad requests

    def test_it_needs_something_to_look_for(self):
        result = self.atlas_mcp.tool_search_assets  # keep the import used
        del result
        reply = self.atlas_mcp.handle_tools_call(
            {"name": "find_similar", "arguments": {}})
        self.assertTrue(reply.get("isError"))
        self.assertIn("like_path", reply["content"][0]["text"])

    def test_text_and_like_path_together_are_refused(self):
        # They are different questions and their scores are not comparable,
        # so answering both at once would be answering neither.
        reply = self.atlas_mcp.handle_tools_call(
            {"name": "find_similar",
             "arguments": {"text": "a barrel", "like_path": "K:/lib/x.fbx"}})
        self.assertTrue(reply.get("isError"))

    # ---------------------------------------------------- the ranking

    @needs_numpy
    def test_it_ranks_by_distance_from_the_given_asset(self):
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:hero-a", "SK_Hero.fbx"), "limit": 10}))
        # SM_Barrel sits closer to the query than SM_Cloud by construction.
        self.assertLess(body.index("SM_Barrel.fbx"), body.index("SM_Cloud.fbx"))

    @needs_numpy
    def test_the_asset_asked_about_is_not_its_own_answer(self):
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:hero-a", "SK_Hero.fbx"), "limit": 10}))
        # id:hero-a was the query. Its same-named sibling is a repeat of it,
        # so neither should take a place in the ranking.
        self.assertNotIn("SK_Hero.fbx", self.ranked_names(body))

    @needs_numpy
    def test_repeats_of_one_name_collapse_to_one_place(self):
        # SK_Character_SchoolBoy_01.fbx came back three times at an identical
        # 0.1301 before this: different files, same picture, same answer.
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:far", "SM_Cloud.fbx"), "limit": 10}))
        self.assertEqual(self.ranked_names(body).count("SK_Hero.fbx"), 1)
        self.assertIn("+1 copy elsewhere", body)

    @needs_numpy
    def test_an_answer_can_be_asked_the_next_question_with(self):
        # It printed the relative path, which spells an archive entry
        # `pack.zip!/entry` where every tool that takes a path wants
        # `zip:Z:\...\pack.zip::entry`. So inspect_model answered "nothing in
        # the catalog matches" to a result find_similar had just produced,
        # and an agent chaining the two hit a dead end.
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:far", "SM_Cloud.fbx"),
             "limit": 10}))
        self.assertIn(
            self.path_of("id:near", "SM_Barrel.fbx"), body,
            "a result has to carry the path the other tools take")

    def test_it_says_how_much_was_searched_and_not_a_fixed_total(self):
        # A baked denominator went stale the moment the library was
        # rescanned, from 73,865 rows to 221,183.
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:far", "SM_Cloud.fbx"), "limit": 10}))
        self.assertIn("%d assets" % len(self.ASSETS), body)
        self.assertNotIn("32,296", body)

    @needs_numpy
    def test_it_warns_against_reading_the_scores_as_probabilities(self):
        # The instinct on seeing 0.12 is to call it a bad match.
        self.build_store()
        body = self.body_of(self.atlas_mcp.tool_find_similar(
            {"like_path": self.path_of("id:far", "SM_Cloud.fbx"), "limit": 10}))
        self.assertIn("rank", body.lower())

    @needs_numpy
    def test_an_asset_with_no_vector_says_so(self):
        vectors_path, index_path = self.atlas_mcp.embedding_store_paths()
        store = embedding_store.EmbeddingStore.create(
            vectors_path, index_path, dims=4, model_id=atlas_embed.MODEL_ID)
        store.append([("id:far", [0.0, 0.0, 1.0, 0.0], "render", 0)])
        store.close()
        reply = self.atlas_mcp.handle_tools_call(
            {"name": "find_similar",
             "arguments": {"like_path": self.path_of("id:hero-a", "SK_Hero.fbx")}})
        self.assertTrue(reply.get("isError"))
        self.assertIn("no vector", reply["content"][0]["text"])

    @needs_numpy
    def test_a_store_from_another_model_is_refused_not_ranked(self):
        # Vectors from a different model are not comparable; ranking them
        # would return a confident order that means nothing.
        vectors_path, index_path = self.atlas_mcp.embedding_store_paths()
        store = embedding_store.EmbeddingStore.create(
            vectors_path, index_path, dims=4, model_id="some-other-model")
        store.append([(asset_id, vector, "render", 0)
                      for asset_id, _n, _s, vector in self.ASSETS])
        store.close()
        reply = self.atlas_mcp.handle_tools_call(
            {"name": "find_similar",
             "arguments": {"like_path": self.path_of("id:hero-a", "SK_Hero.fbx")}})
        self.assertTrue(reply.get("isError"))


class CommandLineTest(unittest.TestCase):
    """The two entry points, as the app and the server actually invoke them."""

    @needs_models
    def test_probe_reports_both_towers(self):
        finished = subprocess.run(
            [sys.executable, "-P", os.path.join(HERE, "atlas_embed.py"),
             "--probe"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=HERE, timeout=300)
        self.assertEqual(finished.returncode, 0,
                         finished.stderr.decode("utf-8", "replace"))
        report = finished.stdout.decode("utf-8", "replace")
        for expected in ("vision", "text", "tokenizer", "768 dims"):
            self.assertIn(expected, report)

    def test_search_without_a_store_says_which_arguments_are_missing(self):
        finished = subprocess.run(
            [sys.executable, "-P", os.path.join(HERE, "atlas_embed.py"),
             "--search", "anything"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=HERE,
            timeout=300)
        self.assertEqual(finished.returncode, 2)
        self.assertIn("--vectors",
                      finished.stderr.decode("utf-8", "replace"))

    def test_the_server_explains_an_empty_store_rather_than_failing(self):
        import atlas_mcp
        if atlas_mcp.embeddings_present():
            self.skipTest("this machine has a store; the message is for one "
                          "that does not")
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.run_visual_search(phrase="grungy")
        self.assertIn("tag_assets.py", str(caught.exception))


class StoreRefreshTest(unittest.TestCase):
    """Seeing rows another process published after this store opened.

    `open` reads the count once, which is right for a pass that owns the
    file and wrong for a server that outlives one. Without this a search
    process held for an hour during a tagging pass keeps answering out of
    the library as it was when it started.
    """

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="atlas-refresh-")
        self.vectors = os.path.join(self.directory, "v.f32")
        self.index = os.path.join(self.directory, "i.sqlite")
        writer = embedding_store.EmbeddingStore.create(
            self.vectors, self.index, dims=4, model_id="test-model")
        writer.append([("first", [1.0, 0.0, 0.0, 0.0], "render", 1)])
        writer.close()

    def reader(self):
        return embedding_store.EmbeddingStore.open(
            self.vectors, self.index, expect_model_id="test-model")

    def append(self, asset_id):
        writer = embedding_store.EmbeddingStore.open(
            self.vectors, self.index, expect_model_id="test-model")
        writer.append([(asset_id, [0.0, 1.0, 0.0, 0.0], "image", 2)])
        writer.close()

    def test_a_reader_does_not_see_a_later_row_until_it_refreshes(self):
        reader = self.reader()
        try:
            self.assertEqual(reader.count, 1)
            self.append("second")
            self.assertEqual(reader.count, 1)
            self.assertEqual(reader.refresh(), 1)
            self.assertEqual(reader.count, 2)
        finally:
            reader.close()

    def test_refreshing_with_nothing_new_gains_nothing(self):
        reader = self.reader()
        try:
            self.assertEqual(reader.refresh(), 0)
            self.assertEqual(reader.count, 1)
        finally:
            reader.close()

    def test_the_new_row_can_be_found_and_read(self):
        # The count is not enough: the index has to be readable too, or the
        # row is a vector nothing can name.
        reader = self.reader()
        try:
            self.append("second")
            reader.refresh()
            row = reader.row_of("second")
            self.assertIsNotNone(row)
            self.assertEqual(list(reader.vector(row)), [0.0, 1.0, 0.0, 0.0])
        finally:
            reader.close()

    def test_the_matrix_grows_with_it(self):
        # The mapping covers the length the file had when it was made, so a
        # refresh has to drop it or the new rows are not in what is searched.
        reader = self.reader()
        try:
            first = len(bytes(reader.matrix()))
            self.append("second")
            reader.refresh()
            self.assertGreater(len(bytes(reader.matrix())), first)
        finally:
            reader.close()

    def test_a_store_in_another_model_space_stays_empty(self):
        reader = embedding_store.EmbeddingStore.open(
            self.vectors, self.index, expect_model_id="a-different-model")
        try:
            self.append("second")
            self.assertEqual(reader.refresh(), 0)
            self.assertEqual(reader.count, 0)
        finally:
            reader.close()

    def test_unmapping_leaves_the_store_usable(self):
        reader = self.reader()
        try:
            self.assertEqual(len(bytes(reader.matrix())), 16)
            reader.unmap()
            self.assertEqual(len(bytes(reader.matrix())), 16)
        finally:
            reader.close()


class SourceFilterTest(unittest.TestCase):
    """Ranking one kind of vector only.

    Models are ranked from a picture drawn of them and images from the file
    itself. Both in one store is what lets a search ask about a material and
    a shape in the same breath; asked about one, the other is noise.
    """

    VECTORS = (
        ("model:a", [1.0, 0.0, 0.0, 0.0], "render"),
        ("image:a", [0.99, 0.01, 0.0, 0.0], "image"),
        ("model:b", [0.0, 1.0, 0.0, 0.0], "render"),
        ("image:b", [0.0, 0.99, 0.01, 0.0], "image"),
    )

    def setUp(self):
        if _numpy is None:
            self.skipTest("numpy is not installed")
        self.directory = tempfile.mkdtemp(prefix="atlas-source-filter-")
        self.store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"),
            dims=4, model_id=atlas_embed.MODEL_ID)
        self.store.append([(asset_id, vector, source, 0)
                           for asset_id, vector, source in self.VECTORS])

    def tearDown(self):
        self.store.close()

    def search(self, source=None, top=10):
        # like_asset_id, not a phrase: the text tower would have to load, and
        # what is under test is the filter rather than the embedding.
        return atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=top, source=source)

    def test_without_a_filter_both_kinds_can_answer(self):
        found = [item["asset_id"] for item in self.search()["results"]]
        self.assertIn("image:a", found)
        self.assertIn("model:b", found)

    def test_asking_for_images_returns_no_models(self):
        found = [item["asset_id"] for item in
                 self.search(source="image")["results"]]
        self.assertEqual(sorted(found), ["image:a", "image:b"])

    def test_asking_for_renders_returns_no_images(self):
        found = [item["asset_id"] for item in
                 self.search(source="render")["results"]]
        # model:a is the query, so it is not its own answer.
        self.assertEqual(found, ["model:b"])

    def test_the_count_reported_is_what_could_have_answered(self):
        # Saying it searched the whole store when a filter excluded most of
        # it overstates the search, and that number is how a consumer judges
        # whether the answer is worth anything.
        filtered = self.search(source="image")
        self.assertEqual(filtered["searched"], 2)
        self.assertEqual(filtered["held"], 4)
        self.assertEqual(self.search()["searched"], 4)

    def test_a_filter_that_excludes_everything_says_so_rather_than_guessing(
            self):
        store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "only.f32"),
            os.path.join(self.directory, "only.sqlite"),
            dims=4, model_id=atlas_embed.MODEL_ID)
        try:
            store.append([("model:solo", [1.0, 0.0, 0.0, 0.0], "render", 0),
                          ("model:other", [0.0, 1.0, 0.0, 0.0], "render", 0)])
            reply = atlas_embed.search_store(
                atlas_embed.Embedder(threads=1), store,
                like_asset_id="model:solo", top=10, source="image")
            self.assertEqual(reply["results"], [])
            self.assertEqual(reply["searched"], 0)
            self.assertEqual(reply["held"], 2)
        finally:
            store.close()

    def test_a_narrowed_search_ranks_only_those_assets(self):
        reply = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=10, only_ids={"image:b"})
        self.assertEqual([item["asset_id"] for item in reply["results"]],
                         ["image:b"])
        self.assertEqual(reply["searched"], 1)
        self.assertEqual(reply["held"], 4)

    def test_the_count_describes_the_corpus_not_the_answer(self):
        # Whichever asset is named, the number of vectors that were looked
        # through is the same; a count that moved with the query would be a
        # worse answer to "how much was searched".
        first = self.search(source="image")["searched"]
        other = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="image:a", top=10, source="image")["searched"]
        self.assertEqual(first, other)

    def test_narrowing_and_the_kind_filter_both_apply(self):
        reply = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=10, source="render",
            only_ids={"image:b", "model:b"})
        self.assertEqual([item["asset_id"] for item in reply["results"]],
                         ["model:b"])

    def test_a_row_that_should_not_be_in_the_store_cannot_answer(self):
        # The vector file is append-only, so rows embedded before a rule
        # existed to keep them out cannot be taken back; this is what stops
        # them answering.
        reply = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=10, exclude_ids={"image:a"})
        found = [item["asset_id"] for item in reply["results"]]
        self.assertNotIn("image:a", found)
        # Three left in scope, not two: the asset asked about is still part
        # of what was looked through, it just cannot be its own answer.
        self.assertEqual(reply["searched"], 3)
        self.assertEqual(reply["held"], 4)

    def test_an_exclusion_beats_an_explicit_narrowing(self):
        reply = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=10, only_ids={"image:a"},
            exclude_ids={"image:a"})
        self.assertEqual(reply["results"], [])

    def test_narrowing_to_nothing_embedded_returns_nothing(self):
        reply = atlas_embed.search_store(
            atlas_embed.Embedder(threads=1), self.store,
            like_asset_id="model:a", top=10, only_ids={"not:embedded"})
        self.assertEqual(reply["results"], [])
        self.assertEqual(reply["searched"], 0)

    def test_the_filter_does_not_cost_the_results_it_should_have_found(self):
        # Taking the top `top` first and filtering after is how a filtered
        # search comes back short: here the two best rows are both renders,
        # so a top-1 slice would leave an image search empty.
        reply = self.search(source="image", top=1)
        self.assertEqual(len(reply["results"]), 1)
        self.assertEqual(reply["results"][0]["asset_id"], "image:a")


class EmbedWorkerTest(unittest.TestCase):
    """The child that stays alive, and what happens when it does not.

    `ping` is used throughout because it is the one operation that touches
    neither the model nor the store, so this tests the plumbing rather than
    the 283 MB file behind it.
    """

    def setUp(self):
        import atlas_mcp
        self.atlas_mcp = atlas_mcp
        self.directory = tempfile.mkdtemp(prefix="atlas-worker-")
        self.worker = atlas_mcp.EmbedWorker(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"))

    def tearDown(self):
        self.worker.close()

    def test_it_answers_at_all(self):
        reply = self.worker.ask(op="ping")
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["model_id"], atlas_embed.MODEL_ID)

    def test_two_questions_are_one_child(self):
        # The whole point: the text tower costs about 1.6 s to construct, and
        # a process per question paid it every time.
        self.worker.ask(op="ping")
        self.worker.ask(op="ping")
        self.assertEqual(self.worker.starts, 1)

    def test_a_child_that_died_while_nobody_looked_is_replaced(self):
        self.worker.ask(op="ping")
        self.worker.process.kill()
        self.worker.process.wait(timeout=10)
        reply = self.worker.ask(op="ping")
        self.assertTrue(reply["ok"])
        self.assertEqual(self.worker.starts, 2)

    def test_closing_twice_is_not_an_error(self):
        self.worker.ask(op="ping")
        self.worker.close()
        self.worker.close()

    def test_a_refusal_comes_back_as_an_error_not_a_reply(self):
        with self.assertRaises(self.atlas_mcp.AtlasError):
            self.worker.ask(op="no_such_operation")

    def test_a_question_after_closing_starts_another_child(self):
        self.worker.ask(op="ping")
        self.worker.close()
        self.assertTrue(self.worker.ask(op="ping")["ok"])
        self.assertEqual(self.worker.starts, 2)

    def test_an_unstartable_embedder_is_explained(self):
        broken = self.atlas_mcp.EmbedWorker("nowhere.f32", "nowhere.sqlite")
        previous = self.atlas_mcp.EMBED_SCRIPT
        self.atlas_mcp.EMBED_SCRIPT = os.path.join(
            self.directory, "not_a_script.py")
        try:
            with self.assertRaises(self.atlas_mcp.AtlasError) as caught:
                broken.ask(op="ping")
            # The child's own words, not a bare "it failed": a missing model
            # file and a missing interpreter look identical otherwise.
            self.assertIn("error output", str(caught.exception))
        finally:
            self.atlas_mcp.EMBED_SCRIPT = previous
            broken.close()


class FindSimilarKindTest(unittest.TestCase):
    """The consumer-facing word for a kind, and what it refuses."""

    def setUp(self):
        import atlas_mcp
        self.atlas_mcp = atlas_mcp

    def test_the_three_kinds_map_onto_what_the_store_records(self):
        self.assertEqual(self.atlas_mcp.SOURCE_BY_KIND["model"], "render")
        self.assertEqual(self.atlas_mcp.SOURCE_BY_KIND["image"], "image")
        self.assertIsNone(self.atlas_mcp.SOURCE_BY_KIND["any"])

    def test_an_unknown_kind_is_refused_before_anything_is_loaded(self):
        with self.assertRaises(self.atlas_mcp.AtlasError) as caught:
            self.atlas_mcp.tool_find_similar(
                {"text": "a barrel", "kind": "sounds"})
        self.assertIn("kind is sounds", str(caught.exception))

    def test_the_schema_offers_the_kinds_so_a_client_can_discover_them(self):
        found = [tool for tool in self.atlas_mcp.TOOLS
                 if tool["name"] == "find_similar"]
        self.assertEqual(len(found), 1)
        kind = found[0]["inputSchema"]["properties"]["kind"]
        self.assertEqual(sorted(kind["enum"]), ["any", "image", "model"])


class ImageCandidateTest(unittest.TestCase):
    """The second queue: images, which are embedded as they stand.

    The grouping and the ordering are deliberately the same code as the model
    queue -- they are about duplicate files and archive locality, not about
    geometry -- so what is tested here is only what differs.
    """

    SCHEMA = CandidateQueryTest.SCHEMA

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(self.SCHEMA)

    def tearDown(self):
        self.connection.close()

    def add(self, asset_id, name, path, ext, asset_type, size=100,
            ignored=0, model_kind=None):
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, model_kind, tags_json)"
            " VALUES (?,?,?,?,?,?,?,?,?,'[]')",
            (asset_id, name, path, path, ext, asset_type, size, ignored,
             model_kind))

    def ids(self, **kwargs):
        return [row["id"] for row in
                tagging.candidates(self.connection, **kwargs)]

    def test_the_two_queues_do_not_see_each_other(self):
        self.add("m", "Hut.fbx", "zip:p.zip::Hut.fbx", "fbx", "model")
        self.add("t", "Hut_BC.png", "zip:p.zip::Hut_BC.png", "png", "image")
        self.assertEqual(self.ids(kind="model"), ["m"])
        self.assertEqual(self.ids(kind="image"), ["t"])

    def test_model_is_what_a_caller_that_says_nothing_gets(self):
        # Every existing caller -- Atlas's queue included -- passes no kind.
        self.add("m", "Hut.fbx", "zip:p.zip::Hut.fbx", "fbx", "model")
        self.add("t", "Hut_BC.png", "zip:p.zip::Hut_BC.png", "png", "image")
        self.assertEqual(self.ids(), ["m"])

    def test_an_unknown_kind_is_refused_rather_than_guessed(self):
        with self.assertRaises(ValueError):
            tagging.candidates(self.connection, kind="sounds")

    def test_stl_is_rendered_like_any_other_model(self):
        # 2,843 of these were in the catalog and invisible to a search that
        # ranks by shape, which is the one thing an STL does carry.
        self.add("s", "blasterA.stl", "zip:p.zip::blasterA.stl", "stl",
                 "model")
        self.assertEqual(self.ids(kind="model"), ["s"])

    def test_an_stl_is_not_mistaken_for_an_image(self):
        self.add("s", "blasterA.stl", "zip:p.zip::blasterA.stl", "stl",
                 "model")
        self.assertEqual(self.ids(kind="image"), [])

    def test_every_image_extension_in_the_library_is_selected(self):
        for index, ext in enumerate(("png", "jpg", "gif", "bmp", "psd")):
            self.add("i%d" % index, "T.%s" % ext, "zip:p.zip::T.%s" % ext,
                     ext, "image")
        self.assertEqual(len(self.ids(kind="image")), 5)

    def test_a_model_is_not_dragged_in_by_its_extension(self):
        # An FBX row mislabelled type=image must still not reach the image
        # queue, because the extension is what decides whether PIL can read
        # it and nothing else.
        self.add("m", "Hut.fbx", "zip:p.zip::Hut.fbx", "fbx", "image")
        self.assertEqual(self.ids(kind="image"), [])

    def test_ignored_images_are_left_alone(self):
        self.add("t", "T.png", "zip:p.zip::T.png", "png", "image",
                 ignored=1)
        self.assertEqual(self.ids(kind="image"), [])

    def test_identical_copies_collapse_here_too(self):
        self.add("a", "T_Wood.png", "zip:p1.zip::T_Wood.png", "png", "image")
        self.add("b", "T_Wood.png", "zip:p2.zip::T_Wood.png", "png", "image")
        self.assertEqual(self.ids(kind="image"), ["a"])

    def test_a_package_cache_is_not_an_asset(self):
        # These are in the catalog because a scan walked a whole Unity
        # project. The first texture query answered with render-pipeline
        # documentation figures, which beat a tiling texture at looking like
        # the thing the texture is of.
        self.add("t", "T_Wall.png", "zip:p.zip::T_Wall.png", "png", "image")
        self.connection.execute(
            "UPDATE catalog_assets SET relative_path = ?"
            " WHERE id = 't'",
            ("Future Slums/Library/PackageCache/com.unity.render-pipelines"
             ".high-definition@10.7.0/Documentation~/Images/T_Wall.png",))
        self.assertEqual(self.ids(kind="image"), [])

    def test_a_pack_that_merely_says_documentation_is_kept(self):
        # Narrow on purpose: "Documentation~" with the tilde is Unity's own
        # convention for an excluded folder, where a pack with a plain
        # Documentation folder is just a pack.
        self.add("t", "T_Wall.png", "zip:p.zip::T_Wall.png", "png", "image")
        self.connection.execute(
            "UPDATE catalog_assets SET relative_path = ?"
            " WHERE id = 't'", ("Synty/Documentation/T_Wall.png",))
        self.assertEqual(self.ids(kind="image"), ["t"])

    def test_a_model_in_a_package_cache_is_still_rendered(self):
        # The exclusion is about images only: a package cache holds almost no
        # models, and the few it holds are no worse to look at than any.
        self.add("m", "Hut.fbx", "zip:p.zip::Hut.fbx", "fbx", "model")
        self.connection.execute(
            "UPDATE catalog_assets SET relative_path = ?"
            " WHERE id = 'm'", ("Thing/Library/PackageCache/x/Hut.fbx",))
        self.assertEqual(self.ids(kind="model"), ["m"])

    def test_narrowing_a_search_matches_the_same_way_a_pass_does(self):
        self.add("a", "T_One.png", "zip:POLY_Town.zip::T_One.png", "png",
                 "image")
        self.add("b", "T_Two.png", "zip:Other.zip::T_Two.png", "png", "image")
        self.assertEqual(
            tagging.asset_ids_matching(self.connection, pack="poly_town"),
            {"a"})
        self.assertIsNone(tagging.asset_ids_matching(self.connection))

    def test_an_image_marked_animation_is_still_embedded(self):
        # The animation rule exists because a clip has no geometry to draw.
        # An image needs no geometry, so applying it here would drop textures
        # on a classifier change that has nothing to do with them.
        self.add("t", "T.png", "zip:p.zip::T.png", "png", "image",
                 model_kind="animation")
        self.assertEqual(self.ids(kind="image"), ["t"])

    def test_the_size_comes_back_so_the_cap_can_be_checked_first(self):
        self.add("t", "T.png", "zip:p.zip::T.png", "png", "image",
                 size=4096)
        rows = tagging.candidates(self.connection, kind="image")
        self.assertEqual(rows[0]["size"], 4096)

    def test_the_work_list_reports_the_size_as_well(self):
        self.add("t", "T.png", "zip:p.zip::T.png", "png", "image", size=77)
        directory = tempfile.mkdtemp(prefix="atlas-image-worklist-")
        store = embedding_store.EmbeddingStore.create(
            os.path.join(directory, "v.f32"),
            os.path.join(directory, "i.sqlite"),
            dims=4, model_id="test-model")
        try:
            work = tagging.work_list(store, self.connection, kind="image")
            self.assertEqual(work.as_dict()["assets"][0]["size"], 77)
        finally:
            store.close()


class ImageQueueIndependenceTest(unittest.TestCase):
    """One store, two queues, and no crosstalk between them.

    Models and images share embeddings.f32 and one failure table. A model
    having a vector must not mark the texture beside it as done, or the pass
    would quietly skip whatever sits next to finished work.
    """

    SCHEMA = CandidateQueryTest.SCHEMA

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(self.SCHEMA)
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, tags_json)"
            " VALUES ('m','Hut.fbx','zip:p.zip::Hut.fbx','Hut.fbx','fbx',"
            "'model',100,0,'[]')")
        self.connection.execute(
            "INSERT INTO catalog_assets (id, name, path, relative_path, ext,"
            " type, size, ignored, tags_json)"
            " VALUES ('t','Hut_BC.png','zip:p.zip::Hut_BC.png',"
            "'Hut_BC.png','png','image',100,0,'[]')")
        self.directory = tempfile.mkdtemp(prefix="atlas-image-queue-")
        self.store = embedding_store.EmbeddingStore.create(
            os.path.join(self.directory, "v.f32"),
            os.path.join(self.directory, "i.sqlite"),
            dims=4, model_id="test-model")

    def tearDown(self):
        self.store.close()

    def remaining(self, kind):
        return [asset["asset_id"] for asset in
                tagging.work_list(self.store, self.connection,
                                  kind=kind).as_dict()["assets"]]

    def test_both_start_outstanding(self):
        self.assertEqual(self.remaining("model"), ["m"])
        self.assertEqual(self.remaining("image"), ["t"])

    def test_embedding_the_model_leaves_the_texture_to_do(self):
        self.store.append([("m", [1.0, 0.0, 0.0, 0.0], "render", 1)])
        self.assertEqual(self.remaining("model"), [])
        self.assertEqual(self.remaining("image"), ["t"])

    def test_embedding_the_texture_leaves_the_model_to_do(self):
        self.store.append([("t", [0.0, 1.0, 0.0, 0.0], "image", 1)])
        self.assertEqual(self.remaining("image"), [])
        self.assertEqual(self.remaining("model"), ["m"])

    def test_the_source_of_each_vector_is_kept(self):
        self.store.append([("m", [1.0, 0.0, 0.0, 0.0], "render", 1),
                           ("t", [0.0, 1.0, 0.0, 0.0], "image", 2)])
        names = self.store.asset_ids_by_row()
        sources = self.store.sources_by_row()
        self.assertEqual(len(names), len(sources))
        by_asset = dict(zip(names, sources))
        self.assertEqual(by_asset["m"], "render")
        self.assertEqual(by_asset["t"], "image")


class ImageReaderTest(unittest.TestCase):
    """Reading the bytes: one archive handle, and the cap checked first."""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="atlas-image-reader-")
        self.first = os.path.join(self.directory, "one.zip")
        self.second = os.path.join(self.directory, "two.zip")
        with zipfile.ZipFile(self.first, "w") as archive:
            archive.writestr("a.png", b"first-a")
            archive.writestr("b.png", b"first-b")
        with zipfile.ZipFile(self.second, "w") as archive:
            archive.writestr("c.png", b"second-c")
        self.reader = tag_images.ArchiveReader()

    def tearDown(self):
        self.reader.close()

    def entry(self, container, name):
        return "zip:%s::%s" % (container, name)

    def test_the_bytes_are_the_entry_asked_for(self):
        self.assertEqual(self.reader.read(self.entry(self.first, "a.png")),
                         b"first-a")
        self.assertEqual(self.reader.read(self.entry(self.second, "c.png")),
                         b"second-c")

    def test_consecutive_entries_reuse_one_handle(self):
        # Candidates come back in path order, so this is the common case; a
        # handle per file would re-parse a central directory of tens of
        # thousands of entries each time.
        self.reader.read(self.entry(self.first, "a.png"))
        self.reader.read(self.entry(self.first, "b.png"))
        self.assertEqual(self.reader.opened, 1)

    def test_a_different_archive_swaps_the_handle(self):
        self.reader.read(self.entry(self.first, "a.png"))
        self.reader.read(self.entry(self.second, "c.png"))
        self.reader.read(self.entry(self.first, "b.png"))
        self.assertEqual(self.reader.opened, 3)

    def test_a_loose_file_needs_no_archive(self):
        loose = os.path.join(self.directory, "loose.png")
        with open(loose, "wb") as handle:
            handle.write(b"on-disk")
        self.assertEqual(self.reader.read(loose), b"on-disk")
        self.assertEqual(self.reader.opened, 0)

    def test_an_oversized_image_is_refused_without_being_read(self):
        # The point of the cap is not to hold the file in memory, so it has
        # to be checked from the catalog's size rather than after reading.
        huge = {"path": self.entry(self.first, "a.png"), "size": 200 * 1024,
                "asset_id": "x"}
        with self.assertRaises(RuntimeError) as caught:
            tag_images.load(self.reader, huge, 100 * 1024)
        self.assertIn("over the", str(caught.exception))
        self.assertEqual(self.reader.opened, 0)

    def test_the_cap_can_be_turned_off(self):
        huge = {"path": self.entry(self.first, "a.png"), "size": 200 * 1024,
                "asset_id": "x"}
        self.assertEqual(tag_images.load(self.reader, huge, 0), b"first-a")

    def test_an_image_within_the_cap_is_read(self):
        asset = {"path": self.entry(self.first, "b.png"), "size": 7,
                 "asset_id": "b"}
        self.assertEqual(tag_images.load(self.reader, asset, 100 * 1024),
                         b"first-b")

    def test_an_empty_file_is_a_failure_not_a_vector(self):
        with zipfile.ZipFile(self.first, "a") as archive:
            archive.writestr("empty.png", b"")
        asset = {"path": self.entry(self.first, "empty.png"), "size": 0,
                 "asset_id": "e"}
        with self.assertRaises(RuntimeError):
            tag_images.load(self.reader, asset, 100 * 1024)

    def test_a_missing_entry_raises_rather_than_returning_nothing(self):
        asset = {"path": self.entry(self.first, "absent.png"), "size": 10,
                 "asset_id": "a"}
        with self.assertRaises(KeyError):
            tag_images.load(self.reader, asset, 100 * 1024)


class PixelBatchTest(unittest.TestCase):
    """Preparing a batch concurrently must not change a single pixel.

    The store holds 31,491 vectors prepared one image at a time. A vector
    prepared differently cannot be ranked against them, and the model id in
    the header would not catch it, because the model would be the same. So
    this is the test that lets the pool exist.
    """

    def setUp(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        if _numpy is None:
            self.skipTest("numpy is not installed")
        self.Image = Image

    def pngs(self, count):
        """Pictures with alpha, since the composite is what the pool runs."""
        made = []
        for index in range(count):
            picture = self.Image.new("RGBA", (40 + index, 32), (0, 0, 0, 0))
            for x in range(picture.width):
                for y in range(picture.height):
                    picture.putpixel(
                        (x, y),
                        ((x * 7 + index) % 256, (y * 11) % 256,
                         (x + y) % 256, (x * 5) % 256))
            buffer = io.BytesIO()
            picture.save(buffer, format="PNG")
            made.append(buffer.getvalue())
        return made

    def test_the_pool_and_the_loop_agree_exactly(self):
        images = self.pngs(5)
        pooled = atlas_embed.Embedder(threads=4)
        serial = atlas_embed.Embedder(threads=1)
        one_at_a_time = [serial._pixels(data) for data in images]
        together = pooled._pixel_batch(images)
        self.assertEqual(len(together), len(one_at_a_time))
        for index, (left, right) in enumerate(zip(together, one_at_a_time)):
            self.assertTrue(
                _numpy.array_equal(left, right),
                "image %d differs when prepared in a pool" % index)

    def test_the_order_out_matches_the_order_in(self):
        # The vectors are zipped back onto the entries by position, so a
        # reordering here would store every vector under the wrong asset.
        images = self.pngs(6)
        embedder = atlas_embed.Embedder(threads=4)
        together = embedder._pixel_batch(images)
        for index, prepared in enumerate(together):
            expected = embedder._pixels(images[index])
            self.assertTrue(_numpy.array_equal(prepared, expected),
                            "position %d is not the image sent there" % index)

    def test_one_image_does_not_start_a_pool(self):
        images = self.pngs(1)
        embedder = atlas_embed.Embedder(threads=4)
        self.assertEqual(len(embedder._pixel_batch(images)), 1)

    def test_a_single_threaded_worker_still_works(self):
        images = self.pngs(3)
        embedder = atlas_embed.Embedder(threads=1)
        self.assertEqual(len(embedder._pixel_batch(images)), 3)

    def test_an_empty_batch_asks_the_model_nothing(self):
        self.assertEqual(atlas_embed.Embedder(threads=4).embed_images([]), [])


class UndecodableImageTest(unittest.TestCase):
    """One file that will not decode must not take its batch with it.

    This is the bug that stopped a real pass 8,203 images short. The driver
    reads bytes and hands them over; whether PIL can make sense of them is
    discovered a batch later, in the worker. Raising there failed all eight
    images in the batch, and the batch failing looked to the driver exactly
    like the worker having died, so it gave up on the whole run.
    """

    def setUp(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        if _numpy is None:
            self.skipTest("numpy is not installed")
        self.Image = Image

    def png(self, shade=10):
        picture = self.Image.new("RGB", (8, 8), (shade, shade, shade))
        buffer = io.BytesIO()
        picture.save(buffer, format="PNG")
        return buffer.getvalue()

    def test_the_good_ones_are_prepared_and_the_bad_one_named(self):
        embedder = atlas_embed.Embedder(threads=4)
        batch = [self.png(10), b"this is not an image", self.png(20)]
        prepared, failures = embedder.prepare_images(batch)
        self.assertEqual([position for position, _ in prepared], [0, 2])
        self.assertEqual([position for position, _ in failures], [1])
        self.assertIn("Error", failures[0][1])

    def test_a_whole_batch_of_rubbish_is_not_an_exception(self):
        embedder = atlas_embed.Embedder(threads=4)
        prepared, failures = embedder.prepare_images([b"no", b"nope"])
        self.assertEqual(prepared, [])
        self.assertEqual(len(failures), 2)

    def test_an_empty_batch_prepares_nothing(self):
        embedder = atlas_embed.Embedder(threads=4)
        self.assertEqual(embedder.prepare_images([]), ([], []))

    def test_preparing_tolerantly_gives_the_same_pixels_as_strictly(self):
        # The tolerant path must not be a different preparation, or vectors
        # from a pass that used it could not be ranked against the rest.
        embedder = atlas_embed.Embedder(threads=4)
        images = [self.png(10), self.png(20)]
        prepared, failures = embedder.prepare_images(images)
        self.assertEqual(failures, [])
        for position, array in prepared:
            self.assertTrue(
                _numpy.array_equal(array, embedder._pixels(images[position])))

    def test_the_single_threaded_path_is_tolerant_too(self):
        embedder = atlas_embed.Embedder(threads=1)
        prepared, failures = embedder.prepare_images([b"no", self.png()])
        self.assertEqual(len(prepared), 1)
        self.assertEqual(len(failures), 1)

    def test_a_render_that_will_not_decode_still_raises(self):
        # embed_images stays strict: its caller produced the bytes, so a
        # failure there is a bug and not a file.
        embedder = atlas_embed.Embedder(threads=2)
        with self.assertRaises(Exception):
            embedder.embed_images([self.png(), b"not an image"])


class UndecodableOverTheWireTest(unittest.TestCase):
    """The same thing through the worker, which is where it bit."""

    def setUp(self):
        if not models_present():
            self.skipTest("the SigLIP files are not present")
        try:
            import PIL  # noqa: F401
        except ImportError:
            self.skipTest("Pillow is not installed")
        self.directory = tempfile.mkdtemp(prefix="atlas-undecodable-")
        self.vectors = os.path.join(self.directory, "v.f32")
        self.index = os.path.join(self.directory, "i.sqlite")
        embedding_store.EmbeddingStore.create(
            self.vectors, self.index, dims=atlas_embed.DIMS,
            model_id=atlas_embed.MODEL_ID).close()
        self.worker = tag_assets.Worker(2, self.vectors, self.index)

    def tearDown(self):
        self.worker.close()

    def good_png(self):
        from PIL import Image
        buffer = io.BytesIO()
        Image.new("RGB", (8, 8), (30, 60, 90)).save(buffer, format="PNG")
        return base64.b64encode(buffer.getvalue()).decode("ascii")

    def test_the_batch_survives_one_unreadable_file(self):
        reply = self.worker.ask(op="images", entries=[
            {"asset_id": "good:1", "image": self.good_png(),
             "source": "image"},
            {"asset_id": "bad:1",
             "image": base64.b64encode(b"not an image").decode("ascii"),
             "source": "image"},
            {"asset_id": "good:2", "image": self.good_png(),
             "source": "image"},
        ])
        self.assertEqual(reply["stored"], 2)
        self.assertEqual([item["asset_id"] for item in reply["rejected"]],
                         ["bad:1"])

    def test_the_file_is_written_down_so_it_is_not_retried_for_ever(self):
        self.worker.ask(op="images", entries=[
            {"asset_id": "bad:2",
             "image": base64.b64encode(b"rubbish").decode("ascii"),
             "source": "image"},
        ])
        failures = self.worker.ask(op="failed", entries=[])
        self.assertEqual(failures["recorded"], 0)
        store = embedding_store.EmbeddingStore.open(
            self.vectors, self.index, expect_model_id=atlas_embed.MODEL_ID)
        try:
            self.assertEqual(store.failure_counts().get("bad:2"), 1)
        finally:
            store.close()

    def test_the_good_ones_are_findable_afterwards(self):
        self.worker.ask(op="images", entries=[
            {"asset_id": "keep:1", "image": self.good_png(),
             "source": "image"},
            {"asset_id": "drop:1",
             "image": base64.b64encode(b"x").decode("ascii"),
             "source": "image"},
        ])
        store = embedding_store.EmbeddingStore.open(
            self.vectors, self.index, expect_model_id=atlas_embed.MODEL_ID)
        try:
            self.assertIsNotNone(store.row_of("keep:1"))
            self.assertIsNone(store.row_of("drop:1"))
        finally:
            store.close()


class ImageHandoverTest(unittest.TestCase):
    """What the image driver sends the worker."""

    class Recorder:
        def __init__(self):
            self.messages = []

        def ask(self, **message):
            self.messages.append(message)
            return {"ok": True, "stored": len(message.get("entries") or [])}

    def test_the_vectors_are_labelled_as_images_not_renders(self):
        # The label is what lets a search ask for one kind only; mislabelled,
        # a texture would be indistinguishable from a render of a model.
        recorder = self.Recorder()
        batch = [({"asset_id": "t", "relative_path": "T.png"}, b"bytes")]
        tag_images.flush(recorder, batch, io.StringIO())
        entry = recorder.messages[0]["entries"][0]
        self.assertEqual(entry["source"], "image")
        self.assertEqual(entry["asset_id"], "t")

    def test_the_bytes_go_over_as_base64_under_the_image_key(self):
        recorder = self.Recorder()
        batch = [({"asset_id": "t", "relative_path": "T.png"}, b"bytes")]
        tag_images.flush(recorder, batch, io.StringIO())
        entry = recorder.messages[0]["entries"][0]
        self.assertEqual(base64.b64decode(entry["image"]), b"bytes")

    def test_a_rejection_is_named_and_counted_as_a_failure(self):
        class Rejecting(self.Recorder):
            def ask(self, **message):
                self.messages.append(message)
                return {"ok": True, "stored": 1,
                        "rejected": [{"asset_id": "b",
                                      "reason": "UnidentifiedImageError: x"}]}

        recorder = Rejecting()
        batch = [({"asset_id": "a", "relative_path": "a.png"}, b"1"),
                 ({"asset_id": "b", "relative_path": "bad/b.png"}, b"2")]
        out = io.StringIO()
        failed = []
        self.assertEqual(tag_images.flush(recorder, batch, out, failed), 1)
        self.assertIn("could not decode", out.getvalue())
        self.assertIn("bad/b.png", out.getvalue())
        # In the run's own tally, so the summary at the end is honest.
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0][0], "bad/b.png")

    def test_a_short_count_is_reported_rather_than_assumed(self):
        class Partial(self.Recorder):
            def ask(self, **message):
                self.messages.append(message)
                return {"ok": True, "stored": 1}

        recorder = Partial()
        batch = [({"asset_id": "a", "relative_path": "a.png"}, b"1"),
                 ({"asset_id": "b", "relative_path": "b.png"}, b"2")]
        out = io.StringIO()
        self.assertEqual(tag_images.flush(recorder, batch, out), 1)
        self.assertIn("kept 1 of 2", out.getvalue())


if __name__ == "__main__":
    unittest.main()
