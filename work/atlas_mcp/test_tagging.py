"""Tests for the visual tagging pass and the embedder.

Split by what they cost. Everything here that does not need the SigLIP files
runs always: the tokenizer contract, the ranking maths, the candidate query,
the resume rule. The handful that do load a 55 MB or 270 MB ONNX session skip
themselves when the files are absent, because the models are not in the
repository -- a checkout without them should still be able to run the suite
and find out that the rest is sound.

Run: python -m unittest test_tagging
"""

import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import atlas_embed
import embedding_store
import tag_assets


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
        self.assertEqual(tag_assets.DIMS, atlas_embed.DIMS)

    def test_the_vision_model_is_not_the_int8_build(self):
        # vision_model_int8.onnx contains ConvInteger(10), for which
        # onnxruntime ships no CPU kernel: it fails at session load with
        # NOT_IMPLEMENTED. Naming it here keeps it from being chosen back.
        self.assertNotIn("int8", atlas_embed.VISION_MODEL)

    def test_the_render_size_is_the_model_input_size(self):
        # Rendering larger is thrown away by the resize; smaller loses detail.
        self.assertEqual(tag_assets.RENDER_SIZE, atlas_embed.IMAGE_SIZE)

    def test_only_formats_with_geometry_are_rendered(self):
        # Audio has nothing to see and .uasset is unreadable outside Unreal,
        # so neither can produce a picture to embed.
        self.assertEqual(set(tag_assets.RENDERABLE_EXTS), {"fbx", "obj"})

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
                tag_assets.candidates(self.connection, **kwargs)]

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
        row = tag_assets.candidates(self.connection)[0]
        self.assertEqual(row["id"], "a")
        self.assertEqual(row["path"], "zip:p1.zip::Barrel.fbx")

    def test_every_id_in_the_group_comes_back(self):
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        row = tag_assets.candidates(self.connection)[0]
        self.assertEqual(sorted(tag_assets.group_ids(row)), ["a", "b"])

    def test_the_copy_count_comes_back(self):
        self.add("a", "Barrel.fbx", "zip:p1.zip::Barrel.fbx", "p1/Barrel.fbx")
        self.add("b", "Barrel.fbx", "zip:p2.zip::Barrel.fbx", "p2/Barrel.fbx")
        rows = tag_assets.candidates(self.connection)
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
        self.assertFalse(tag_assets.group_is_done(self.store, row))
        self.store.append([("b", [1.0, 0.0, 0.0, 0.0], "render", 1)])
        self.assertTrue(tag_assets.group_is_done(self.store, row))

    def test_a_group_of_one_still_works(self):
        row = {"id": "solo", "sibling_ids": "solo"}
        self.assertFalse(tag_assets.group_is_done(self.store, row))
        self.store.append([("solo", [0.0, 1.0, 0.0, 0.0], "render", 1)])
        self.assertTrue(tag_assets.group_is_done(self.store, row))

    def test_a_missing_sibling_list_falls_back_to_the_id(self):
        # group_concat returns NULL for an empty group, and a row built by
        # hand may not carry the column at all.
        row = {"id": "solo", "sibling_ids": None}
        self.assertEqual(tag_assets.group_ids(row), ["solo"])

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
        self.assertFalse(tag_assets.group_is_hopeless(row, counts, 3))
        counts["b"] = 3
        self.assertTrue(tag_assets.group_is_hopeless(row, counts, 3))

    def test_below_the_limit_it_is_still_tried(self):
        row = self.row("a")
        self.assertFalse(tag_assets.group_is_hopeless(row, {"a": 2}, 3))
        self.assertTrue(tag_assets.group_is_hopeless(row, {"a": 3}, 3))

    def test_zero_attempts_means_never_give_up(self):
        row = self.row("a")
        self.assertFalse(tag_assets.group_is_hopeless(row, {"a": 99}, 0))

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

    class FakeEmbedder:
        """Stands in for atlas_embed.py --serve.

        Vectors are the model's real width, because the store this writes to
        is the real one and its header refuses anything else -- which is the
        guard working, not a nuisance to design around.
        """

        def __init__(self, *_args, **_kwargs):
            self.calls = 0

        def ask(self, message):
            self.calls += 1
            entries = message.get("entries") or []
            return {"ok": True,
                    "vectors": [[float(index)] + [0.0] * (atlas_embed.DIMS - 1)
                                for index, _ in enumerate(entries)]}

        def close(self):
            pass

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
        self.previous_embedder = tag_assets.EmbedderProcess
        atlas_mcp.bridge_version = lambda: "test"
        tag_assets.EmbedderProcess = self.FakeEmbedder

    def tearDown(self):
        self.atlas_mcp.bridge_version = self.previous_version
        tag_assets.render = self.previous_render
        tag_assets.EmbedderProcess = self.previous_embedder
        self.atlas_mcp.DB_PATH = self.previous_db

    def set_render(self, behaviour):
        tag_assets.render = behaviour

    def run_pass(self):
        out = io.StringIO()
        code = tag_assets.run(self.Arguments(), out)
        return code, out.getvalue()

    def stored(self):
        store = tag_assets.open_or_create_store()
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
            return b"png-%s" % row["id"].encode("ascii")

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
        class DyingEmbedder(InterruptedRunTest.FakeEmbedder):
            def ask(self, message):
                raise RuntimeError("the embedder stopped answering")

        tag_assets.EmbedderProcess = DyingEmbedder
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
            if len(state) > 1 or row["id"] >= "id:06":
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
            if row["id"] >= "id:06":
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
            if row["id"] == "id:03":
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
            seen.append(row["id"])
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
            if row["id"] == "id:03":
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
            if row["id"] == "id:03":
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
            if row["id"] == "id:03":
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
            if row["id"] == "id:03" and state["fail"]:
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
        self.assertEqual(tag_assets.store_paths(),
                         atlas_mcp.embedding_store_paths())

    def test_it_sits_beside_the_catalog(self):
        import atlas_mcp
        vectors_path, index_path = tag_assets.store_paths()
        catalog_dir = os.path.dirname(atlas_mcp.DB_PATH)
        self.assertEqual(os.path.dirname(vectors_path), catalog_dir)
        self.assertEqual(os.path.dirname(index_path), catalog_dir)


class ServeProtocolTest(unittest.TestCase):
    """The protocol tag_assets.py drives, exercised without the model.

    A driver blocked on a pipe that will never answer is the worst failure
    mode here, so the rule under test is that every line gets a reply.
    """

    class FakeEmbedder:
        numpy = None

        def embed_images(self, pngs):
            return [[0.0] * 4 for _ in pngs]

        def embed_text(self, phrases):
            return [[1.0] * 4 for _ in phrases]

    def serve(self, lines):
        out = io.StringIO()
        atlas_embed.run_serve(self.FakeEmbedder(), iter(lines), out)
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

    def test_asset_ids_come_back_with_their_vectors(self):
        # The driver pairs them by position; returning one without the other
        # would attach vectors to the wrong assets.
        replies = self.serve([json.dumps({
            "op": "images",
            "entries": [{"asset_id": "a", "png": "aGk="},
                        {"asset_id": "b", "png": "aGk="}]})])
        self.assertEqual(replies[0]["asset_ids"], ["a", "b"])
        self.assertEqual(len(replies[0]["vectors"]), 2)


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


if __name__ == "__main__":
    unittest.main()
