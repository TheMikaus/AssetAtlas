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

    def test_the_order_of_the_remaining_work_is_kept(self):
        # candidates() returns archive order, and missing() has to preserve
        # it or the locality that ordering bought is thrown away.
        self.store.append([("b", [0.0, 1.0, 0.0, 0.0], "render", 1)])
        self.assertEqual(self.store.missing(["a", "b", "c", "d"]),
                         ["a", "c", "d"])


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
