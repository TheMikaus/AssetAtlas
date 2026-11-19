"""Tests for the Atlas MCP server.

Two kinds. The protocol and formatting tests build a catalog of their own in a
temporary file and need nothing else. The mirror test reads lib/main.dart and
fails if the attachment keywords here have drifted from the ones the app
actually uses -- the hazard of restating a table in a second language.

Run: python -m unittest discover -s work/atlas_mcp
"""

import base64
import http.server
import io
import json
import os
import re
import shutil
import sqlite3
import tempfile
import threading
import unittest
import zipfile

import atlas_mcp


SCHEMA = """
CREATE TABLE catalog_assets (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL,
  relative_path TEXT NOT NULL, source_root TEXT NOT NULL,
  source_name TEXT NOT NULL, ext TEXT NOT NULL, type TEXT NOT NULL,
  size INTEGER NOT NULL, modified_ms INTEGER NOT NULL, tags_json TEXT NOT NULL,
  ignored INTEGER NOT NULL DEFAULT 0, model_kind TEXT, rig_family TEXT,
  referenced_by_model INTEGER NOT NULL DEFAULT 0);
CREATE TABLE catalog_sources (root_path TEXT PRIMARY KEY);
CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL,
  root_path TEXT, created_ms INTEGER NOT NULL);
CREATE TABLE project_assets (project_id TEXT NOT NULL, asset_id TEXT NOT NULL,
  PRIMARY KEY (project_id, asset_id));
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

ROOT = r"K:\Assets\Synty"
PACK = r"zip:K:\Assets\Synty\POLYGON_Fantasy.zip::"


def _asset(name, entry, **overrides):
    ext = name.rsplit(".", 1)[-1].lower()
    row = {
        "id": "asset:v2:" + entry.lower(),
        "name": name,
        "path": PACK + entry,
        "relative_path": "Synty/POLYGON_Fantasy.zip!/" + entry,
        "source_root": ROOT,
        "source_name": "Synty",
        "ext": ext,
        "type": {"fbx": "model", "png": "image", "uasset": "unreal"}.get(ext, "other"),
        "size": 1024,
        "modified_ms": 0,
        "tags_json": json.dumps(name.lower().replace(".", "_").split("_")),
        "ignored": 0,
        "model_kind": None,
        "rig_family": None,
        "referenced_by_model": 0,
    }
    row.update(overrides)
    return row


FIXTURE = [
    _asset("SM_Chr_Captain_Male_01.fbx", "FBX/Characters/SM_Chr_Captain_Male_01.fbx",
           model_kind="mesh", rig_family="polygon"),
    _asset("SM_Chr_Archer_Female_01.fbx", "FBX/Characters/SM_Chr_Archer_Female_01.fbx",
           model_kind="mesh", rig_family="polygon"),
    _asset("SM_Chr_Attach_Helmet_01.fbx",
           "FBX/Characters/Attachments/SM_Chr_Attach_Helmet_01.fbx", model_kind="mesh"),
    _asset("SM_Chr_Attach_Cape_01.fbx",
           "FBX/Characters/Attachments/SM_Chr_Attach_Cape_01.fbx", model_kind="mesh"),
    _asset("SM_Prop_Anvil_01.fbx", "FBX/Props/SM_Prop_Anvil_01.fbx", model_kind="mesh"),
    _asset("A_Jump_Running_Femn.fbx", "Animations/A_Jump_Running_Femn.fbx",
           model_kind="animation"),
    _asset("A_Idle_Standing_Masc.fbx", "Animations/A_Idle_Standing_Masc.fbx",
           model_kind="animation"),
    _asset("PolygonFantasy_Texture_01.png", "Textures/PolygonFantasy_Texture_01.png"),
    _asset("Pack_Icon.png", "Pack_Icon.png"),
    _asset("SM_Bld_House_01.uasset", "Content/SM_Bld_House_01.uasset"),
]

# A file loose in the scanned root, beside the archive rather than inside it.
LOOSE = _asset("POLYGON_Fantasy_ICON.png", "ignored")
LOOSE.update({
    "id": "asset:v2:loose-icon",
    "path": ROOT + r"\POLYGON_Fantasy_ICON.png",
    "relative_path": "Synty/POLYGON_Fantasy_ICON.png",
})
FIXTURE.append(LOOSE)


def build_catalog(path):
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    columns = list(FIXTURE[0])
    connection.executemany(
        "INSERT INTO catalog_assets (%s) VALUES (%s)"
        % (",".join(columns), ",".join("?" * len(columns))),
        [[row[c] for c in columns] for row in FIXTURE])
    connection.execute("INSERT INTO catalog_sources VALUES (?)", (ROOT,))
    connection.commit()
    connection.close()


class CatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.mkdtemp(prefix="atlas-mcp-test-")
        cls.db = os.path.join(cls.directory, "catalog.db")
        build_catalog(cls.db)
        cls.previous = atlas_mcp.DB_PATH
        atlas_mcp.DB_PATH = cls.db

    @classmethod
    def tearDownClass(cls):
        atlas_mcp.DB_PATH = cls.previous

    def call(self, name, **arguments):
        result = atlas_mcp.handle_tools_call(
            {"name": name, "arguments": arguments})
        self.assertFalse(result.get("isError"), result["content"][0].get("text"))
        return result["content"][0]["text"]

    def call_raw(self, name, **arguments):
        return atlas_mcp.handle_tools_call({"name": name, "arguments": arguments})


class SearchTest(CatalogTest):
    def test_terms_are_anded_and_order_free(self):
        # The app's own example: two pieces of a name, neither adjacent nor
        # in order.
        body = self.call("search_assets", query="jump femn")
        self.assertIn("A_Jump_Running_Femn.fbx", body)
        self.assertNotIn("A_Idle_Standing_Masc.fbx", body)

    def test_a_term_matches_the_path_as_well_as_the_name(self):
        body = self.call("search_assets", query="attachments")
        self.assertIn("Helmet", body)
        self.assertIn("Cape", body)

    def test_animation_and_model_do_not_overlap(self):
        models = self.call("search_assets", type="model", limit=50)
        self.assertNotIn("A_Jump_Running_Femn.fbx", models)
        clips = self.call("search_assets", type="animation", limit=50)
        self.assertIn("A_Jump_Running_Femn.fbx", clips)
        self.assertNotIn("SM_Prop_Anvil_01.fbx", clips)

    def test_a_texture_folder_makes_an_image_a_texture(self):
        textures = self.call("search_assets", type="texture", limit=50)
        self.assertIn("PolygonFantasy_Texture_01.png", textures)
        # The pack icon sits at the top level, so it is an image, not a texture.
        self.assertNotIn("Pack_Icon.png", textures)

    def test_character_filter_uses_the_rig_column(self):
        body = self.call("search_assets", type="character", limit=50)
        self.assertIn("Captain", body)
        self.assertNotIn("Anvil", body)

    def test_an_empty_result_says_so_rather_than_erroring(self):
        self.assertIn("No assets matched", self.call("search_assets", query="zzzz"))

    def test_paging_reports_what_is_left(self):
        body = self.call("search_assets", limit=2)
        self.assertIn("offset=2", body)

    def test_an_unknown_type_is_a_tool_error_not_a_crash(self):
        result = self.call_raw("search_assets", type="spaceship")
        self.assertTrue(result["isError"])
        self.assertIn("Unknown type", result["content"][0]["text"])


class LookupTest(CatalogTest):
    def test_an_asset_can_be_found_by_path_or_by_name(self):
        by_name = self.call("get_asset", path="SM_Prop_Anvil_01.fbx", inspect="none")
        by_path = self.call("get_asset", path=PACK + "FBX/Props/SM_Prop_Anvil_01.fbx",
                            inspect="none")
        self.assertIn("SM_Prop_Anvil_01.fbx", by_name)
        self.assertEqual(by_name, by_path)

    def test_a_missing_asset_is_reported_not_raised(self):
        result = self.call_raw("get_asset", path="nothing.fbx")
        self.assertTrue(result["isError"])
        self.assertIn("Nothing in the catalog", result["content"][0]["text"])

    def test_the_pack_is_named_from_the_archive(self):
        body = self.call("get_asset", path="SM_Prop_Anvil_01.fbx", inspect="none")
        self.assertIn("POLYGON_Fantasy.zip", body)

    def test_nearby_images_are_listed(self):
        body = self.call("get_asset",
                         path="PolygonFantasy_Texture_01.png", inspect="none")
        self.assertIn("images beside it", body)


class PacksAndFoldersTest(CatalogTest):
    def test_packs_are_counted_by_archive(self):
        body = self.call("list_packs")
        self.assertIn("POLYGON_Fantasy.zip", body)

    def test_a_file_loose_in_the_root_is_not_a_pack_of_its_own(self):
        # A pack's icon sits beside its archive, not inside it; counting it as
        # a pack listed every icon in the library as an empty one.
        body = self.call("list_packs")
        self.assertNotIn("POLYGON_Fantasy_ICON.png", body)
        self.assertIn("Synty", body)

    def test_browse_walks_one_level_at_a_time(self):
        top = self.call("browse")
        self.assertIn("Synty", top)
        inside = self.call("browse", folder="Synty/POLYGON_Fantasy.zip!")
        self.assertIn("FBX", inside)
        self.assertIn("Animations", inside)
        # Files directly in this folder are listed, deeper ones are not.
        self.assertIn("Pack_Icon.png", inside)
        self.assertNotIn("SM_Prop_Anvil_01.fbx", inside)

    def test_browsing_nowhere_says_so(self):
        self.assertIn("Nothing under", self.call("browse", folder="Synty/Nope"))

    def test_stats_report_the_rig_coverage_gap(self):
        body = self.call("catalog_stats")
        self.assertIn("rig_family known for", body)


class AttachmentTest(CatalogTest):
    def test_kit_is_grouped_by_the_body_part_the_name_claims(self):
        body = self.call("find_attachments", path=None,
                         character="SM_Chr_Captain_Male_01.fbx")
        self.assertIn("Head", body)
        self.assertIn("Helmet", body)
        self.assertIn("Back", body)
        self.assertIn("Cape", body)

    def test_the_character_is_not_offered_as_its_own_hat(self):
        body = self.call("find_attachments", character="SM_Chr_Captain_Male_01.fbx")
        # The header names the character; the listed kit must not.
        listed = body.split("where they go.", 1)[1]
        self.assertNotIn("SM_Chr_Captain_Male_01.fbx", listed)

    def test_another_character_is_not_offered_as_kit(self):
        # Atlas excludes anything already known to have a rig of its own.
        body = self.call("find_attachments", character="SM_Chr_Captain_Male_01.fbx")
        self.assertNotIn("Archer", body)

    def test_a_prop_that_claims_no_body_part_is_left_out(self):
        body = self.call("find_attachments", character="SM_Chr_Captain_Male_01.fbx")
        self.assertNotIn("Anvil", body)


class AttachPointTest(unittest.TestCase):
    def test_whole_tokens_only(self):
        # `cape` contains `cap`; matching loosely once put every cloak in the
        # library on a character's head.
        self.assertEqual(atlas_mcp.attach_point_for("SM_Chr_Attach_Cape_01.fbx"), "Back")
        self.assertEqual(atlas_mcp.attach_point_for("SM_Chr_Attach_Helmet_01.fbx"), "Head")
        self.assertIsNone(atlas_mcp.attach_point_for("SM_Prop_Anvil_01.fbx"))

    def test_mirrors_the_table_in_main_dart(self):
        here = os.path.dirname(os.path.abspath(__file__))
        dart = os.path.join(here, os.pardir, "asset_atlas_native", "lib", "main.dart")
        if not os.path.exists(dart):
            self.skipTest("lib/main.dart is not beside this checkout")
        with io.open(dart, encoding="utf-8") as handle:
            source = handle.read()
        start = source.index("const attachPoints =")
        block = source[start:source.index("\n];", start)]
        from_dart = {}
        for match in re.finditer(r"name: '([^']+)',\s*keywords: \[(.*?)\]", block, re.S):
            from_dart[match.group(1)] = re.findall(r"'([^']+)'", match.group(2))
        self.assertEqual(from_dart, dict(atlas_mcp.ATTACH_POINTS),
                         "the attachment keywords here have drifted from "
                         "attachPoints in lib/main.dart")

    def test_the_order_matches_too(self):
        here = os.path.dirname(os.path.abspath(__file__))
        dart = os.path.join(here, os.pardir, "asset_atlas_native", "lib", "main.dart")
        if not os.path.exists(dart):
            self.skipTest("lib/main.dart is not beside this checkout")
        with io.open(dart, encoding="utf-8") as handle:
            source = handle.read()
        start = source.index("const attachPoints =")
        block = source[start:source.index("\n];", start)]
        names = re.findall(r"name: '([^']+)',\s*keywords:", block)
        self.assertEqual(names, [name for name, _ in atlas_mcp.ATTACH_POINTS])


class RigTest(unittest.TestCase):
    def test_sidekick_wins_over_the_mannequin_it_extends(self):
        # A Sidekick rig is the Unreal mannequin plus attachment bones, so it
        # carries the mannequin's markers as well as its own.
        markers = ["pelvis", "spine_01", "hipAttachFront", "ik_hand_root"]
        self.assertEqual(atlas_mcp.rig_family_from_markers(markers), "sidekick")

    def test_polygon_and_unreal_are_told_apart_by_case(self):
        self.assertEqual(atlas_mcp.rig_family_from_markers(["Hips", "Spine_01"]),
                         "polygon")
        self.assertEqual(atlas_mcp.rig_family_from_markers(["pelvis", "spine_01"]),
                         "unreal")

    def test_no_markers_is_no_rig(self):
        self.assertEqual(atlas_mcp.rig_family_from_markers([]), "none")


class ProtocolTest(unittest.TestCase):
    def drive(self, *messages):
        stdin = io.StringIO("".join(json.dumps(m) + "\n" for m in messages))
        stdout = io.StringIO()
        atlas_mcp.serve(stdin, stdout)
        return [json.loads(line) for line in stdout.getvalue().splitlines()]

    def test_initialize_echoes_a_version_it_knows(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "atlas")

    def test_an_unknown_version_falls_back_rather_than_failing(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": "1999-01-01"}})
        self.assertEqual(replies[0]["result"]["protocolVersion"],
                         atlas_mcp.DEFAULT_PROTOCOL)

    def test_notifications_get_no_reply(self):
        replies = self.drive({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual(replies, [])

    def test_every_tool_is_listed_with_a_schema(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = replies[0]["result"]["tools"]
        self.assertEqual(len(tools), len(atlas_mcp.HANDLERS))
        for tool in tools:
            self.assertIn("description", tool)
            self.assertEqual(tool["inputSchema"]["type"], "object")
            self.assertNotIn("handler", tool)

    def test_an_unknown_method_is_a_jsonrpc_error(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 3, "method": "nonsense"})
        self.assertEqual(replies[0]["error"]["code"], -32601)

    def test_an_unknown_tool_is_a_tool_error_not_a_protocol_one(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                              "params": {"name": "nope", "arguments": {}}})
        self.assertTrue(replies[0]["result"]["isError"])

    def test_a_broken_line_does_not_end_the_session(self):
        stdin = io.StringIO("{not json\n" +
                            json.dumps({"jsonrpc": "2.0", "id": 5, "method": "ping"}) + "\n")
        stdout = io.StringIO()
        atlas_mcp.serve(stdin, stdout)
        replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(replies[0]["id"], 5)

    def test_nothing_but_json_reaches_stdout(self):
        replies = self.drive({"jsonrpc": "2.0", "id": 6, "method": "ping"})
        self.assertEqual(replies, [{"jsonrpc": "2.0", "id": 6, "result": {}}])


class FormattingTest(unittest.TestCase):
    def test_bytes_read_like_the_app(self):
        self.assertEqual(atlas_mcp.format_bytes(512), "512 B")
        self.assertEqual(atlas_mcp.format_bytes(1536), "1.5 KB")
        self.assertEqual(atlas_mcp.format_bytes(1024 * 1024 * 3), "3.0 MB")

    def test_texture_folders_are_recognised_either_slash(self):
        self.assertTrue(atlas_mcp.looks_like_texture_location("a/Textures/b.png"))
        self.assertTrue(atlas_mcp.looks_like_texture_location(r"a\Material\b.png"))
        self.assertFalse(atlas_mcp.looks_like_texture_location("a/Icons/b.png"))

    def test_bounds_are_printed_as_ranges_that_run_forwards(self):
        # The reader sends min x, min y, min z, max x, max y, max z. Printed
        # in that order the pairs interleave and every range reads backwards.
        lines = atlas_mcp.format_bounds([-1.0, -0.2, -0.5, 1.0, 2.0, 0.5])
        self.assertIn("x -1..1", lines[0])
        self.assertIn("y -0.2..2", lines[0])
        self.assertIn("z -0.5..0.5", lines[0])
        self.assertIn("2 x 2.2 x 1 units", lines[1])

    def test_a_zip_path_comes_apart_into_archive_and_entry(self):
        self.assertEqual(
            atlas_mcp.parse_zip_path("zip:K:/a.zip::b/c.fbx"),
            ("K:/a.zip", "b/c.fbx"))
        self.assertIsNone(atlas_mcp.parse_zip_path("K:/a/b.fbx"))


# A second catalog, richer than FIXTURE: the same pack several times over, the
# way Synty actually ships -- source files, two engine builds, and a pack
# re-release -- because that is what the duplicate and build tools are about.
BUILDS_ROOT = r"K:\Assets\Synty"


def _build_asset(archive, entry, name, size, **overrides):
    ext = name.rsplit(".", 1)[-1].lower()
    row = {
        "id": "asset:v2:" + (archive + "/" + entry).lower(),
        "name": name,
        "path": "zip:%s\\%s::%s" % (BUILDS_ROOT, archive, entry),
        "relative_path": "Synty/%s!/%s" % (archive, entry),
        "source_root": BUILDS_ROOT,
        "source_name": "Synty",
        "ext": ext,
        "type": {"fbx": "model", "png": "image",
                 "uasset": "unreal", "umap": "unreal"}.get(ext, "other"),
        "size": size,
        "modified_ms": 0,
        "tags_json": json.dumps(name.lower().replace(".", "_").split("_")),
        "ignored": 0,
        "model_kind": "mesh" if ext == "fbx" else None,
        "rig_family": None,
        "referenced_by_model": 0,
    }
    row.update(overrides)
    return row


# SM_Bld_Door_01.fbx is byte-identical in three archives; the Wall is unique.
BUILD_FIXTURE = [
    _build_asset("POLYGON_Town_SourceFiles.zip", "SourceFiles/FBX/SM_Bld_Door_01.fbx",
                 "SM_Bld_Door_01.fbx", 2048),
    _build_asset("POLYGON_Town_SourceFiles_v3.zip", "SourceFiles/FBX/SM_Bld_Door_01.fbx",
                 "SM_Bld_Door_01.fbx", 2048),
    _build_asset("PolygonTown_Source_Files.zip", "SourceFiles/FBX/SM_Bld_Door_01.fbx",
                 "SM_Bld_Door_01.fbx", 2048),
    _build_asset("POLYGON_Town_SourceFiles.zip", "SourceFiles/FBX/SM_Bld_Wall_01.fbx",
                 "SM_Bld_Wall_01.fbx", 3072),
    _build_asset("POLYGON_Town_Unreal_5_4_v1_2_0.zip",
                 "PolygonTown/Content/SM_Bld_Door_01.uasset",
                 "SM_Bld_Door_01.uasset", 9000),
    _build_asset("POLYGON_Town_Unreal_4_25_v1_1_0.zip",
                 "PolygonTown/Content/SM_Bld_Door_01.uasset",
                 "SM_Bld_Door_01.uasset", 8000),
    _build_asset("POLYGON_Dungeon_Realms_Unreal_5_4_v1_5_0.zip",
                 "PolygonDungeon/Content/SM_Bld_Crypt_01.uasset",
                 "SM_Bld_Crypt_01.uasset", 7000),
    _build_asset("POLYGON_Dungeons_Realms_SourceFiles_v4.zip",
                 "SourceFiles/FBX/SM_Bld_Crypt_01.fbx",
                 "SM_Bld_Crypt_01.fbx", 4096),
]


def build_builds_catalog(path):
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    columns = list(BUILD_FIXTURE[0])
    connection.executemany(
        "INSERT INTO catalog_assets (%s) VALUES (%s)"
        % (",".join(columns), ",".join("?" * len(columns))),
        [[row[c] for c in columns] for row in BUILD_FIXTURE])
    connection.execute("INSERT INTO catalog_sources VALUES (?)", (BUILDS_ROOT,))
    connection.commit()
    connection.close()


class ArchiveNameTest(unittest.TestCase):
    """The one place a name is read on purpose: which engine a build targets.

    That fact is not inside the files -- an Unreal build is .uasset, which
    says nothing about its engine version -- and it is the first thing anyone
    assembling a project needs.
    """

    def test_a_built_archive_yields_its_engine_and_pack_version(self):
        info = atlas_mcp.parse_archive_name("POLYGON_Shops_Unreal_5_4_v1_9_0.zip")
        self.assertEqual(info["family"], "polygon")
        self.assertEqual(info["pack_key"], "shop")
        self.assertEqual(info["build"], "unreal")
        self.assertEqual(info["engine"], "5.4")
        self.assertEqual(info["version"], "1_9_0")

    def test_source_builds_carry_no_engine(self):
        info = atlas_mcp.parse_archive_name("POLYGON_Town_SourceFiles_v4.zip")
        self.assertEqual(info["build"], "source")
        self.assertIsNone(info["engine"])
        self.assertEqual(info["version"], "4")

    def test_unity_is_told_apart_from_unreal(self):
        info = atlas_mcp.parse_archive_name("POLYGON_City_Characters_Unity_5_6.zip")
        self.assertEqual(info["build"], "unity")
        self.assertEqual(info["engine"], "5.6")

    def test_a_camel_joined_prefix_groups_with_the_underscored_one(self):
        # PolygonOffice_SourceFiles and POLYGON_Office_SourceFiles_v2 are one
        # pack. Stripping the family before splitting runCamelCase missed
        # this and split Office, Town and Shops into two packs each.
        self.assertEqual(
            atlas_mcp.parse_archive_name("PolygonOffice_SourceFiles.zip")["pack_key"],
            atlas_mcp.parse_archive_name(
                "POLYGON_Office_SourceFiles_v2.zip")["pack_key"])

    def test_a_stray_plural_groups_too(self):
        # Synty ships "Dungeon_Realms" and "Dungeons_Realms".
        self.assertEqual(
            atlas_mcp.parse_archive_name(
                "POLYGON_Dungeon_Realms_Unreal_5_1_v1_5_0.zip")["pack_key"],
            atlas_mcp.parse_archive_name(
                "POLYGON_Dungeons_Realms_SourceFiles_v4.zip")["pack_key"])

    def test_a_bare_version_with_no_engine_word_is_an_unreal_project(self):
        # PolygonDungeonRealms_4_22_Sub_02.zip: every archive shaped like this
        # in the library is an Unreal export.
        info = atlas_mcp.parse_archive_name("PolygonDungeonRealms_4_22_Sub_02.zip")
        self.assertEqual(info["build"], "unreal")
        self.assertEqual(info["engine"], "4.22")
        self.assertEqual(info["pack_key"], "dungeon realm")

    def test_a_browser_copy_marker_is_not_part_of_the_name(self):
        info = atlas_mcp.parse_archive_name(
            "POLYGON_BattleRoyale_Unreal_5_3_v1_8_0 (1).zip")
        self.assertEqual(info["pack_key"], "battle royale")
        self.assertEqual(info["engine"], "5.3")

    def test_near_miss_names_are_left_apart_rather_than_guessed(self):
        # "Explorer" and "Explorer Kit" may well be the same product, but
        # fuzzy-merging pack names would also merge things that are not.
        self.assertNotEqual(
            atlas_mcp.parse_archive_name("POLYGON_Explorer_Unreal_4_25_v1_4.zip")["pack_key"],
            atlas_mcp.parse_archive_name("POLYGON_ExplorerKit_SourceFiles.zip")["pack_key"])

    def test_a_build_reads_as_one_phrase(self):
        self.assertEqual(
            atlas_mcp.describe_build(atlas_mcp.parse_archive_name(
                "POLYGON_Town_Unreal_5_4_v1_2_0.zip")),
            "unreal 5.4 (v1_2_0)")
        self.assertEqual(atlas_mcp.describe_build(None), "loose files")


class BuildsCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.mkdtemp(prefix="atlas-mcp-builds-")
        cls.db = os.path.join(cls.directory, "builds.db")
        build_builds_catalog(cls.db)
        cls.previous = atlas_mcp.DB_PATH
        atlas_mcp.DB_PATH = cls.db

    @classmethod
    def tearDownClass(cls):
        atlas_mcp.DB_PATH = cls.previous

    def call(self, name, **arguments):
        result = atlas_mcp.handle_tools_call({"name": name, "arguments": arguments})
        self.assertFalse(result.get("isError"), result["content"][0].get("text"))
        return result["content"][0]["text"]

    def call_raw(self, name, **arguments):
        return atlas_mcp.handle_tools_call({"name": name, "arguments": arguments})

    def rows_in(self, body):
        """The numbered result lines, so a count is of rows not substrings.

        Every row prints the file name twice -- once in the summary line and
        again inside its path -- so counting the name counts double.
        """
        return [line for line in body.splitlines()
                if re.match(r"\s*\d+\. ", line)]

class DedupSearchTest(BuildsCatalogTest):
    def test_identical_copies_collapse_to_one_row(self):
        body = self.call("search_assets", query="door", ext="fbx")
        rows = self.rows_in(body)
        self.assertEqual(len(rows), 1, body)
        self.assertIn("SM_Bld_Door_01.fbx", rows[0])
        self.assertIn("x3 copies", rows[0])

    def test_the_row_says_where_the_other_copies_live(self):
        body = self.call("search_assets", query="door", ext="fbx")
        self.assertIn("also in:", body)
        self.assertIn("POLYGON_Town_SourceFiles_v3.zip", body)
        self.assertIn("PolygonTown_Source_Files.zip", body)

    def test_a_unique_file_is_not_labelled_as_duplicated(self):
        body = self.call("search_assets", query="wall", ext="fbx")
        rows = self.rows_in(body)
        self.assertEqual(len(rows), 1, body)
        self.assertIn("SM_Bld_Wall_01.fbx", rows[0])
        self.assertNotIn("copies", rows[0])
        self.assertNotIn("also in:", body)

    def test_distinct_false_returns_every_row(self):
        body = self.call("search_assets", query="door", ext="fbx", distinct=False)
        self.assertEqual(len(self.rows_in(body)), 3, body)

    def test_the_count_is_of_distinct_files_not_rows(self):
        grouped = self.call("search_assets", query="door", ext="fbx")
        self.assertIn("1 distinct files", grouped)
        every = self.call("search_assets", query="door", ext="fbx", distinct=False)
        self.assertIn("3 matches", every)

    def test_files_that_differ_in_size_are_not_merged(self):
        # The same name in two engine builds, different bytes: two files.
        body = self.call("search_assets", query="door", ext="uasset")
        self.assertIn("2 distinct files", body)


class EngineFilterTest(BuildsCatalogTest):
    def test_an_engine_version_restricts_to_that_build(self):
        body = self.call("search_assets", query="door", engine="5.4")
        self.assertIn("POLYGON_Town_Unreal_5_4_v1_2_0.zip", body)
        self.assertNotIn("4_25", body)

    def test_a_build_kind_restricts_to_source_or_engine_assets(self):
        body = self.call("search_assets", query="door", build="source")
        self.assertIn("SM_Bld_Door_01.fbx", body)
        self.assertNotIn(".uasset", body)

    def test_an_engine_nobody_has_is_an_error_that_lists_what_there_is(self):
        result = self.call_raw("search_assets", query="door", engine="9.9")
        self.assertTrue(result.get("isError"))
        body = result["content"][0]["text"]
        self.assertIn("5.4", body)
        self.assertIn("4.25", body)

    def test_an_unknown_build_kind_is_a_tool_error(self):
        result = self.call_raw("search_assets", build="godot")
        self.assertTrue(result.get("isError"))
        self.assertIn("source", result["content"][0]["text"])


class FindPacksTest(BuildsCatalogTest):
    def test_archives_of_one_pack_are_one_row_with_its_builds(self):
        body = self.call("find_packs", query="town")
        self.assertIn("1 packs", body)
        self.assertIn("source", body)
        self.assertIn("unreal 5.4", body)
        self.assertIn("unreal 4.25", body)

    def test_the_engine_filter_keeps_only_packs_built_for_it(self):
        body = self.call("find_packs", engine="4.25")
        self.assertIn("Town", body)
        self.assertNotIn("Dungeon", body)

    def test_a_pack_with_no_match_says_so_rather_than_erroring(self):
        body = self.call("find_packs", query="spaceship")
        self.assertIn("No packs matched", body)

    def test_the_plural_and_singular_spellings_are_one_pack(self):
        body = self.call("find_packs", query="dungeon")
        self.assertIn("1 packs", body)
        self.assertIn("unreal 5.4", body)
        self.assertIn("source", body)


class FindDuplicatesTest(BuildsCatalogTest):
    def test_the_waste_is_counted_in_bytes_not_just_files(self):
        body = self.call("find_duplicates")
        self.assertIn("SM_Bld_Door_01.fbx", body)
        self.assertIn("3 copies", body)
        # Two redundant copies of a 2048-byte file.
        self.assertIn("4.0 KB", body)

    def test_unique_files_are_not_listed(self):
        body = self.call("find_duplicates")
        self.assertNotIn("SM_Bld_Wall_01.fbx", body)

    def test_an_extension_narrows_it(self):
        body = self.call("find_duplicates", ext="uasset")
        self.assertIn("No duplicates", body)


class ExportTest(unittest.TestCase):
    """Writing assets out of their archives, which is a real side effect."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.mkdtemp(prefix="atlas-mcp-export-")
        cls.archive = os.path.join(cls.directory, "POLYGON_Town_Unreal_5_4_v1_2_0.zip")
        with zipfile.ZipFile(cls.archive, "w") as zf:
            zf.writestr("PolygonTown/Content/SM_Bld_Door_01.uasset", b"door-bytes")
            zf.writestr("PolygonTown/Content/SM_Bld_Wall_01.uasset", b"wall-bytes")

        cls.db = os.path.join(cls.directory, "export.db")
        connection = sqlite3.connect(cls.db)
        connection.executescript(SCHEMA)
        rows = []
        for entry, name, size in (
                ("PolygonTown/Content/SM_Bld_Door_01.uasset",
                 "SM_Bld_Door_01.uasset", 10),
                ("PolygonTown/Content/SM_Bld_Wall_01.uasset",
                 "SM_Bld_Wall_01.uasset", 10)):
            rows.append({
                "id": "asset:v2:" + entry.lower(),
                "name": name,
                "path": "zip:%s::%s" % (cls.archive, entry),
                "relative_path": "Town/POLYGON_Town_Unreal_5_4_v1_2_0.zip!/" + entry,
                "source_root": cls.directory,
                "source_name": "Town",
                "ext": "uasset",
                "type": "unreal",
                "size": size,
                "modified_ms": 0,
                "tags_json": "[]",
                "ignored": 0,
                "model_kind": None,
                "rig_family": None,
                "referenced_by_model": 0,
            })
        columns = list(rows[0])
        connection.executemany(
            "INSERT INTO catalog_assets (%s) VALUES (%s)"
            % (",".join(columns), ",".join("?" * len(columns))),
            [[row[c] for c in columns] for row in rows])
        connection.execute("INSERT INTO catalog_sources VALUES (?)", (cls.directory,))
        connection.commit()
        connection.close()

        cls.previous = atlas_mcp.DB_PATH
        atlas_mcp.DB_PATH = cls.db

    @classmethod
    def tearDownClass(cls):
        atlas_mcp.DB_PATH = cls.previous

    def export(self, **arguments):
        result = atlas_mcp.handle_tools_call(
            {"name": "export_assets", "arguments": arguments})
        return result

    def test_entries_keep_their_archive_relative_path(self):
        dest = tempfile.mkdtemp(prefix="atlas-export-dest-")
        body = self.export(dest=dest, ext="uasset")["content"][0]["text"]
        self.assertIn("Wrote 2 files", body)
        landed = os.path.join(dest, "PolygonTown", "Content", "SM_Bld_Door_01.uasset")
        self.assertTrue(os.path.exists(landed))
        with open(landed, "rb") as handle:
            self.assertEqual(handle.read(), b"door-bytes")

    def test_existing_files_are_left_alone_unless_asked(self):
        dest = tempfile.mkdtemp(prefix="atlas-export-dest-")
        self.export(dest=dest, ext="uasset")
        again = self.export(dest=dest, ext="uasset")["content"][0]["text"]
        self.assertIn("Wrote 0 files", again)
        self.assertIn("already-present", again)
        forced = self.export(dest=dest, ext="uasset",
                             overwrite=True)["content"][0]["text"]
        self.assertIn("Wrote 2 files", forced)

    def test_a_selection_is_required(self):
        dest = tempfile.mkdtemp(prefix="atlas-export-dest-")
        result = self.export(dest=dest)
        self.assertTrue(result.get("isError"))
        self.assertIn("whole catalog", result["content"][0]["text"])

    def test_a_destination_is_required(self):
        result = self.export(ext="uasset")
        self.assertTrue(result.get("isError"))

    def test_one_asset_can_be_named_outright(self):
        dest = tempfile.mkdtemp(prefix="atlas-export-dest-")
        body = self.export(
            dest=dest, paths=["SM_Bld_Wall_01.uasset"])["content"][0]["text"]
        self.assertIn("Wrote 1 files", body)
        self.assertTrue(os.path.exists(os.path.join(
            dest, "PolygonTown", "Content", "SM_Bld_Wall_01.uasset")))


class SafePathTest(unittest.TestCase):
    """An archive is untrusted input, and an export writes to disk."""

    def test_an_entry_cannot_climb_out_of_the_destination(self):
        for entry in ("../../evil.txt", "a/../../b", "/etc/passwd",
                      "C:/evil.txt", "..", ""):
            self.assertIsNone(atlas_mcp._safe_relative(entry), entry)

    def test_an_ordinary_entry_survives(self):
        self.assertEqual(
            atlas_mcp._safe_relative("PolygonTown/Content/A.uasset"),
            os.path.join("PolygonTown", "Content", "A.uasset"))

    def test_a_leading_dot_is_dropped_rather_than_refused(self):
        self.assertEqual(atlas_mcp._safe_relative("./x/y.png"),
                         os.path.join("x", "y.png"))


# A stub standing in for the running app. Atlas's own side of this contract is
# tested in Dart (test/bridge_test.dart); what is tested here is the client:
# that it finds the endpoint, carries the token, and turns the app's JSON into
# something worth reading.
BRIDGE_ROUTES = {}
BRIDGE_SEEN = []
BRIDGE_TOKEN = "token-for-tests"


class _StubAtlas(http.server.BaseHTTPRequestHandler):

    def log_message(self, *args):
        """Quiet: the test runner's output is not a web server log."""

    def _reply(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._serve(None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self._serve(json.loads(raw.decode("utf-8")) if raw else {})

    def _serve(self, payload):
        token = self.headers.get("X-Atlas-Token")
        BRIDGE_SEEN.append({"path": self.path, "payload": payload,
                            "token": token})
        if token != BRIDGE_TOKEN:
            self._reply(403, {"error": "Bad or missing bridge token."})
            return
        if self.path not in BRIDGE_ROUTES:
            self._reply(404, {"error": "No route %s." % self.path})
            return
        status, body = BRIDGE_ROUTES[self.path]
        self._reply(status, body)


INSPECT_REPORT = {
    "name": "SK_PolygonMech_Main_Full.fbx",
    "archive": "POLYGON_Mech_SourceFiles_v2.zip",
    "path": r"zip:Z:\Polygon-Mech.zip::Mech/SK_PolygonMech_Main_Full.fbx",
    "pack": "Polygon-Mech",
    "shape": "kit",
    "faces": 261410,
    "vertices": 148302,
    "objects": 215,
    "authoredSize": [180.0, 420.5, 160.25],
    "materials": [
        {"name": "Mech_Body", "summary": "textured 2048x2048, normal map"},
        {"name": "Mech_Glass", "summary": "missing: asks for 1 texture, none found"},
    ],
    "texturesResolved": 1,
    "texturesMissing": 1,
    "rig": {"family": "polygon", "label": "Polygon", "bones": 52,
            "skinned": True, "frames": 0, "durationSeconds": 0, "clips": []},
    "slots": [{"key": "geo_head", "label": "Head", "variants": 8},
              {"key": "geo_l_shoulder", "label": "Shoulder L", "variants": 10}],
    "attachments": [{"name": "SM_Wep_Rifle_01.fbx", "path": "x", "point": "Right hand"}],
    "textureVariants": [{"name": "T_Mech_Red.png", "path": "y"}],
    "warnings": ["This file is a kit: 2 slots of interchangeable parts."],
}

RIG_REPORT = {
    "character": {"name": "Chr_Hero.fbx", "path": "a", "family": "polygon",
                  "label": "Polygon", "bones": 52},
    "clip": {"name": "A_Jump.fbx", "path": "b", "family": "sidekick",
             "label": "Sidekick", "bones": 121, "frames": 40,
             "durationSeconds": 1.33},
    "sharedBones": 0,
    "familiesCompatible": False,
    "restPoseDifferenceDegrees": None,
    "willPlay": False,
    "verdict": "No. Polygon and Sidekick are different rigs; they share 0 bones.",
}


class BridgeTest(unittest.TestCase):

    def setUp(self):
        BRIDGE_ROUTES.clear()
        del BRIDGE_SEEN[:]
        self.server = http.server.HTTPServer(("127.0.0.1", 0), _StubAtlas)
        # serve_forever polls at half a second by default, and shutdown waits
        # for the next tick, which put eight seconds of nothing into the run.
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01),
            daemon=True)
        self.thread.start()
        self.temp = tempfile.mkdtemp(prefix="atlas-bridge-client")
        self.descriptor = os.path.join(self.temp, "atlas_bridge.json")
        self.write_descriptor(port=self.server.server_address[1],
                              token=BRIDGE_TOKEN)
        self.saved_path = atlas_mcp.BRIDGE_PATH
        atlas_mcp.BRIDGE_PATH = self.descriptor

    def tearDown(self):
        atlas_mcp.BRIDGE_PATH = self.saved_path
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        shutil.rmtree(self.temp, ignore_errors=True)

    def write_descriptor(self, **fields):
        with io.open(self.descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(fields))

    def route(self, path, body, status=200):
        BRIDGE_ROUTES[path] = (status, body)

    def body_of(self, result):
        return result["content"][0]["text"]


class BridgeClientTest(BridgeTest):

    def test_it_finds_the_running_app_through_the_descriptor(self):
        self.route("/health", {"version": "1.10.28", "assets": 73865})
        self.assertEqual(atlas_mcp.bridge_version(), "1.10.28")

    def test_it_carries_the_token_the_app_wrote(self):
        self.route("/health", {"version": "1.10.28"})
        atlas_mcp.bridge_version()
        self.assertEqual(BRIDGE_SEEN[-1]["token"], BRIDGE_TOKEN)

    def test_no_descriptor_means_atlas_is_not_running(self):
        os.remove(self.descriptor)
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.bridge_call("/inspect", {"path": "x"})
        self.assertIn("not running", str(caught.exception))
        self.assertIn("Open Atlas", str(caught.exception))

    def test_an_unreadable_descriptor_is_not_a_crash(self):
        with io.open(self.descriptor, "w", encoding="utf-8") as handle:
            handle.write("{half a json")
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.bridge_call("/inspect", {"path": "x"})
        self.assertIn("not running", str(caught.exception))

    def test_a_descriptor_without_a_port_is_not_a_crash(self):
        self.write_descriptor(token=BRIDGE_TOKEN)
        with self.assertRaises(atlas_mcp.AtlasError):
            atlas_mcp.bridge_call("/inspect", {"path": "x"})

    def test_a_descriptor_left_behind_by_a_crash_says_so(self):
        # Atlas killed rather than closed leaves the file pointing at a port
        # that now refuses. That has to read as "not running", not as a
        # network error the caller cannot act on.
        self.server.shutdown()
        self.server.server_close()
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.bridge_call("/inspect", {"path": "x"})
        self.assertIn("not running", str(caught.exception))

    def test_the_apps_own_sentence_reaches_the_caller(self):
        self.route("/inspect", {"error": "SM_Door_01.fbx matches 2 assets."},
                   status=400)
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.bridge_call("/inspect", {"path": "SM_Door_01.fbx"})
        self.assertEqual(str(caught.exception),
                         "SM_Door_01.fbx matches 2 assets.")

    def test_the_payload_arrives_as_the_app_expects_it(self):
        self.route("/inspect", INSPECT_REPORT)
        atlas_mcp.tool_inspect_model({"path": "SK_PolygonMech_Main_Full.fbx"})
        self.assertEqual(BRIDGE_SEEN[-1]["payload"],
                         {"path": "SK_PolygonMech_Main_Full.fbx"})

    def test_version_is_none_rather_than_an_error_when_atlas_is_closed(self):
        # catalog_stats calls this on every run and must not fail because
        # the app happens to be shut.
        os.remove(self.descriptor)
        self.assertIsNone(atlas_mcp.bridge_version())


class InspectFormattingTest(BridgeTest):

    def report(self, **overrides):
        body = dict(INSPECT_REPORT)
        body.update(overrides)
        self.route("/inspect", body)
        return self.body_of(atlas_mcp.tool_inspect_model({"path": "x"}))

    def test_it_says_which_of_the_three_shapes_the_file_is(self):
        self.assertIn("kit of interchangeable parts", self.report())
        self.assertIn("sheet of several whole models",
                      self.report(shape="sheet"))
        self.assertIn("one model", self.report(shape="model"))

    def test_it_counts_the_geometry_readably(self):
        self.assertIn("261,410 faces", self.report())

    def test_it_gives_the_authored_size_not_the_drawn_one(self):
        # The viewer fits everything into the same box, so the drawn size is
        # the same for a rivet and a cathedral. This is the number that says
        # whether a prop will arrive in a level a hundred times too big.
        self.assertIn("as the artist built it", self.report())
        self.assertIn("420", self.report())

    def test_it_names_the_material_that_did_not_resolve(self):
        body = self.report()
        self.assertIn("1 of 2 materials textured", body)
        self.assertIn("Mech_Glass", body)
        self.assertIn("none found", body)

    def test_it_reports_the_rig_and_that_it_is_skinned(self):
        self.assertIn("Polygon, 52 bones, skinned", self.report())

    def test_it_lists_the_slots_with_their_variant_counts(self):
        self.assertIn("Head x8", self.report())

    def test_it_names_the_archive_rather_than_the_scanned_root(self):
        # "pack" is the scanned root's name, which is the same unhelpful word
        # on 50,000 files here. The archive is what someone can act on.
        body = self.report()
        self.assertIn("POLYGON_Mech_SourceFiles_v2.zip", body)
        self.assertNotIn("Polygon-Mech", body.splitlines()[0])

    def test_a_loose_file_falls_back_to_its_source_name(self):
        body = self.report(archive=None)
        self.assertIn("Polygon-Mech", body.splitlines()[0])

    def test_one_recolour_is_not_described_in_the_plural(self):
        self.assertIn("1 other texture in this archive fits it", self.report())

    def test_an_attachment_with_no_known_point_is_listed_without_an_arrow(self):
        body = self.report(attachments=[{"name": "SM_Mech_Ankle_01.fbx",
                                         "path": "x", "point": None}])
        self.assertIn("SM_Mech_Ankle_01.fbx", body)
        self.assertNotIn("->", body)

    def test_it_lists_the_kit_pieces_that_fit(self):
        self.assertIn("SM_Wep_Rifle_01.fbx", self.report())
        self.assertIn("Right hand", self.report())

    def test_a_warning_is_marked_so_it_is_not_skimmed_past(self):
        self.assertIn("!", self.report())
        self.assertIn("This file is a kit", self.report())

    def test_a_long_material_list_is_cut_rather_than_dumped(self):
        many = [{"name": "M_%d" % i, "summary": "flat colour, no texture"}
                for i in range(30)]
        body = self.report(materials=many)
        self.assertIn("and 18 more", body)

    def test_a_model_with_no_rig_does_not_claim_one(self):
        body = self.report(rig={"family": "none", "label": "No rig",
                                "bones": 0, "skinned": False})
        self.assertNotIn("bones", body)

    def test_a_file_with_no_measurable_size_omits_the_line(self):
        body = self.report(authoredSize=None)
        self.assertNotIn("as the artist built it", body)


class RigCompatFormattingTest(BridgeTest):

    def test_the_verdict_comes_first(self):
        self.route("/rig_compat", RIG_REPORT)
        body = self.body_of(
            atlas_mcp.tool_rig_compatibility({"character": "a", "clip": "b"}))
        self.assertTrue(body.startswith("No. Polygon and Sidekick"), body)

    def test_it_shows_both_rigs_and_the_overlap(self):
        self.route("/rig_compat", RIG_REPORT)
        body = self.body_of(
            atlas_mcp.tool_rig_compatibility({"character": "a", "clip": "b"}))
        self.assertIn("Polygon, 52 bones", body)
        self.assertIn("Sidekick, 121 bones", body)
        self.assertIn("shared bones", body)

    def test_rest_poses_that_cannot_be_compared_say_so(self):
        # rigAxisDifference returns infinity for "no comparison possible",
        # which crosses as null rather than as a number.
        self.route("/rig_compat", RIG_REPORT)
        body = self.body_of(
            atlas_mcp.tool_rig_compatibility({"character": "a", "clip": "b"}))
        self.assertIn("not comparable", body)

    def test_a_degree_figure_is_printed_when_there_is_one(self):
        body = dict(RIG_REPORT)
        body["restPoseDifferenceDegrees"] = 37.42
        self.route("/rig_compat", body)
        text_body = self.body_of(
            atlas_mcp.tool_rig_compatibility({"character": "a", "clip": "b"}))
        self.assertIn("37.4 degrees apart", text_body)


class RenderFormattingTest(BridgeTest):

    PNG = b"\x89PNG\r\n\x1a\n" + b"pretend this is pixels"

    def render(self, **overrides):
        body = {"name": "SM_Crate_01.fbx", "path": "x", "width": 512,
                "height": 512, "drawnFaces": 1200, "totalFaces": 2400,
                "capped": False, "shape": "model",
                "png": base64.b64encode(self.PNG).decode("ascii")}
        body.update(overrides)
        self.route("/render", body)
        return atlas_mcp.tool_render_asset({"path": "x"})

    def test_it_hands_back_the_picture_as_an_image(self):
        result = self.render()
        kinds = [part["type"] for part in result["content"]]
        self.assertEqual(kinds, ["text", "image"])
        self.assertEqual(result["content"][1]["mimeType"], "image/png")
        self.assertEqual(base64.b64decode(result["content"][1]["data"]),
                         self.PNG)

    def test_the_caption_says_how_much_of_the_model_was_drawn(self):
        caption = self.render()["content"][0]["text"]
        self.assertIn("1,200 of 2,400 faces drawn", caption)

    def test_hitting_the_face_limit_is_said_plainly(self):
        caption = self.render(capped=True)["content"][0]["text"]
        self.assertIn("face limit", caption)

    def test_a_kit_says_it_was_drawn_one_variant_per_slot(self):
        caption = self.render(shape="kit")["content"][0]["text"]
        self.assertIn("one variant per slot", caption)

    def test_a_picture_too_big_to_send_is_described_instead(self):
        huge = base64.b64encode(b"\x89PNG" + b"0" * 1_600_000).decode("ascii")
        result = self.render(png=huge)
        kinds = [part["type"] for part in result["content"]]
        self.assertEqual(kinds, ["text"])
        self.assertIn("too large", result["content"][0]["text"])


class BridgeToolRegistrationTest(unittest.TestCase):

    def test_the_three_app_tools_are_registered(self):
        names = [tool["name"] for tool in atlas_mcp.TOOLS]
        for name in ("inspect_model", "rig_compatibility", "render_asset"):
            self.assertIn(name, names)

    def test_each_one_warns_that_it_needs_atlas_open(self):
        # The client reads these descriptions to decide what to call, so the
        # requirement belongs in them rather than only in a failure message.
        for tool in atlas_mcp.TOOLS:
            if tool["name"] in ("inspect_model", "rig_compatibility",
                                "render_asset"):
                self.assertIn("Atlas open", tool["description"])

    def test_every_handler_has_a_schema_and_the_other_way_round(self):
        self.assertEqual(sorted(atlas_mcp.HANDLERS),
                         sorted(tool["name"] for tool in atlas_mcp.TOOL_SCHEMAS))


def _query_fixture():
    """fixtures/search_queries.json, the grammar written down once."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fixtures", "search_queries.json")
    with io.open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _row_for(asset):
    """A catalog row whose effective_type comes out as the fixture says.

    The fixture names the type a person sees, which is the effective one; the
    catalog stores something narrower. 'texture' is an image in a textures
    folder, 'animation' is a model the probe called a clip.
    """
    stored, model_kind = asset["type"], None
    if stored == "texture":
        stored = "image"
    elif stored == "animation":
        stored, model_kind = "model", "animation"
    return {
        "name": asset["name"],
        "relative_path": asset["relative_path"],
        "tags_json": json.dumps(asset["tags"]),
        "type": stored,
        "ext": asset["ext"],
        "rig_family": asset["rig"],
        "model_kind": model_kind,
        "referenced_by_model": 0,
    }


class QueryGrammarTest(unittest.TestCase):
    """The filter grammar, against the fixture the app is also tested on.

    Two implementations of one grammar is the arrangement that always drifts,
    so neither side owns it: fixtures/search_queries.json does, and both
    suites read that same file. A case added there fails on whichever side
    has not caught up.
    """

    @classmethod
    def setUpClass(cls):
        cls.fixture = _query_fixture()

    def test_the_fixture_is_not_empty(self):
        # A fixture that silently stopped loading would pass every loop below.
        self.assertGreater(len(self.fixture["parse"]), 20)
        self.assertGreater(len(self.fixture["match"]), 20)

    def test_the_field_list_matches_the_code(self):
        # Adding a field to one side and not the other is the drift this
        # catches, and it catches it in both directions.
        self.assertEqual(tuple(self.fixture["fields"]),
                         atlas_mcp.QUERY_FIELDS)
        self.assertEqual(frozenset(self.fixture["exact_fields"]),
                         atlas_mcp.QUERY_EXACT_FIELDS)
        self.assertEqual(sorted(self.fixture["reserved_fields"]),
                         sorted(atlas_mcp.QUERY_RESERVED_FIELDS))

    def test_parse_cases(self):
        for case in self.fixture["parse"]:
            query = case["query"]
            with self.subTest(query=query, why=case["why"]):
                if "error_contains" in case:
                    with self.assertRaises(atlas_mcp.QueryError) as caught:
                        atlas_mcp.parse_asset_query(query)
                    self.assertIn(case["error_contains"].lower(),
                                  str(caught.exception).lower())
                else:
                    expected = [[tuple(term) for term in clause]
                                for clause in case["clauses"]]
                    self.assertEqual(atlas_mcp.parse_asset_query(query),
                                     expected)

    def test_match_cases(self):
        for case in self.fixture["match"]:
            asset = self.fixture["assets"][case["asset"]]
            with self.subTest(query=case["query"], asset=case["asset"],
                              why=case["why"]):
                clauses = atlas_mcp.parse_asset_query(case["query"])
                values = atlas_mcp.row_search_values(_row_for(asset))
                self.assertEqual(
                    atlas_mcp.query_matches(clauses, values), case["matches"])

    def test_the_fixture_assets_resolve_to_the_type_they_claim(self):
        # _row_for has to be right, or every type= match case is vacuous.
        for name, asset in self.fixture["assets"].items():
            with self.subTest(asset=name):
                self.assertEqual(atlas_mcp.effective_type(_row_for(asset)),
                                 asset["type"])

    def test_a_query_error_is_a_tool_error_not_a_crash(self):
        # QueryError is an AtlasError, so the server reports it to the caller
        # instead of dying mid-stream.
        self.assertTrue(issubclass(atlas_mcp.QueryError, atlas_mcp.AtlasError))

    def test_every_type_value_has_a_prefilter(self):
        for value in atlas_mcp.QUERY_TYPE_VALUES:
            self.assertIn(value, atlas_mcp._TYPE_PREFILTER)

    def test_every_field_but_type_has_sql(self):
        # type= is the one field SQL cannot settle, which is why the sieve
        # exists. Any other field missing its SQL would be a KeyError at
        # query time, on a search that had just parsed cleanly.
        for field in atlas_mcp.QUERY_FIELDS:
            if field != "type":
                self.assertIn(field, atlas_mcp._FIELD_SQL)

    def test_only_an_unresolvable_type_asks_for_the_sieve(self):
        # Whether an image is a texture turns on a regex over the path, so
        # those two have to be sieved. Every other type prefilters exactly,
        # and sieving one anyway cost 1,177 ms on type=unreal to confirm a
        # count SQL already had right.
        for query in ("tag=grungy name=door", "type=audio",
                      "type=unreal", "type=other",
                      "name=x or type=audio"):
            with self.subTest(query=query):
                self.assertFalse(atlas_mcp.query_needs_sieve(
                    atlas_mcp.parse_asset_query(query)))
        # model and animation joined the sieved set when an unprobed clip
        # became recognisable from its folder: the two overlap in SQL and
        # only effective_type can separate them.
        for query in ("type=texture", "type=image", "name=x or type=image",
                      "type=model", "type=animation"):
            with self.subTest(query=query):
                self.assertTrue(atlas_mcp.query_needs_sieve(
                    atlas_mcp.parse_asset_query(query)))

    def test_the_sieved_types_are_the_ones_effective_type_can_move(self):
        # Four values need the sieve, each for its own reason:
        #   image, texture  -- a regex over the path decides which one it is
        #   animation       -- an unprobed clip is only its folder name
        #   model           -- and must not also count as that clip
        # Every other prefilter is exact, which means guarding it against a
        # model the probe called a clip.
        self.assertEqual(
            atlas_mcp._TYPE_NEEDS_SIEVE,
            frozenset(["image", "texture", "animation", "model"]))
        for value, clause in atlas_mcp._TYPE_PREFILTER.items():
            if value in atlas_mcp._TYPE_NEEDS_SIEVE:
                continue
            with self.subTest(value=value):
                self.assertIn("model_kind", clause)

    def test_an_exact_total_is_only_asked_for_when_it_differs(self):
        self.assertFalse(atlas_mcp.needs_exact_total("all", None))
        self.assertFalse(atlas_mcp.needs_exact_total("audio", None))
        # These three the old type= argument counted from the prefilter, so
        # it overstated every one of them.
        for kind in ("texture", "animation", "model"):
            with self.subTest(kind=kind):
                self.assertTrue(atlas_mcp.needs_exact_total(kind, None))
        self.assertTrue(
            atlas_mcp.needs_exact_total("all", [[("type", "texture")]]))

    def test_a_sieve_over_fetches_so_a_page_can_still_fill(self):
        # Sieving after LIMIT hands back a short page and calls it the end.
        self.assertEqual(atlas_mcp.sieve_fetch(40, "all", None), 40)
        self.assertGreater(
            atlas_mcp.sieve_fetch(40, "all", [[("type", "model")]]), 40)
        self.assertGreater(atlas_mcp.sieve_fetch(40, "texture", None), 40)


class AnimationRuleTest(unittest.TestCase):
    """The folder rule, against the shared fixture.

    This is a guess standing in for a probe, which makes it exactly the kind
    of thing that drifts between two implementations without anyone noticing:
    the app and the MCP would quietly disagree about what is a clip. The
    fixture is the contract; the app's suite reads the same cases.
    """

    @classmethod
    def setUpClass(cls):
        cls.cases = _query_fixture()["animation_paths"]

    def test_the_fixture_has_both_answers_in_it(self):
        # All-true cases would pass for a rule that always said yes.
        answers = {case["animation"] for case in self.cases}
        self.assertEqual(answers, {True, False})

    def test_every_case(self):
        for case in self.cases:
            with self.subTest(path=case["path"], why=case["why"]):
                self.assertEqual(
                    atlas_mcp.looks_like_animation(case["path"]),
                    case["animation"])

    def test_a_probed_mesh_outranks_the_folder(self):
        # The rule is a fallback, not an override. A file the importer has
        # read and called a mesh is a mesh wherever it is filed.
        row = {"model_kind": "mesh", "type": "model",
               "relative_path": "pack/Animations/SM_Thing.fbx",
               "referenced_by_model": 0}
        self.assertEqual(atlas_mcp.effective_type(row), "model")

    def test_a_probed_clip_is_a_clip_wherever_it_sits(self):
        row = {"model_kind": "animation", "type": "model",
               "relative_path": "pack/Models/SM_Thing.fbx",
               "referenced_by_model": 0}
        self.assertEqual(atlas_mcp.effective_type(row), "animation")

    def test_an_unprobed_file_falls_back_to_the_folder(self):
        row = {"model_kind": None, "type": "model",
               "relative_path": "pack/Animations/A_Run.fbx",
               "referenced_by_model": 0}
        self.assertEqual(atlas_mcp.effective_type(row), "animation")

    def test_the_rule_only_applies_to_models(self):
        # An image in an Animations folder is still an image: the rule reads
        # model rows only, so nothing else can be dragged into 'animation'.
        row = {"model_kind": None, "type": "image",
               "relative_path": "pack/Animations/T_Thing.png",
               "referenced_by_model": 0}
        self.assertEqual(atlas_mcp.effective_type(row), "image")

    def test_model_and_animation_do_not_overlap(self):
        # Both filters are permissive in SQL and separated by the sieve. If
        # either forgot, a guessed clip would count twice and the totals
        # would exceed the library.
        for value in ("model", "animation"):
            self.assertIn(value, atlas_mcp._TYPE_NEEDS_SIEVE)
        self.assertIn("animation", atlas_mcp.SIEVED_KINDS)
        self.assertIn("model", atlas_mcp.SIEVED_KINDS)


class QueryGrammarSqlTest(CatalogTest):
    """The same grammar through SQLite, which is what actually runs.

    query_matches agreeing with the fixture settles the semantics; this
    settles that the SQL expresses them, which can be wrong on its own -- a
    LIKE pattern, a missing lower(), the tags blob.
    """

    def names_for(self, query, **extra):
        extra["query"] = query
        with atlas_mcp.open_catalog() as connection:
            rows, _total, _kind = atlas_mcp.rows_for(connection, extra, 500, 0)
            return sorted(row["name"] for row in rows)

    def every_row(self):
        with atlas_mcp.open_catalog() as connection:
            return connection.execute(
                "SELECT * FROM catalog_assets WHERE ignored = 0").fetchall()

    def test_a_scoped_name_term_ignores_the_path(self):
        # Every fixture row sits under a folder, so a path word must be
        # findable bare and unfindable through name=.
        folder = self.every_row()[0]["relative_path"].replace(
            chr(92), "/").split("/")[0].lower()
        self.assertNotEqual(self.names_for(folder), [])
        self.assertEqual(self.names_for("name=" + folder), [])

    def test_a_tag_term_finds_a_tag_and_not_the_name(self):
        for row in self.every_row():
            tags = json.loads(row["tags_json"] or "[]")
            if tags:
                self.assertIn(row["name"], self.names_for("tag=" + tags[0]))
                break
        else:
            self.fail("no row in the fixture catalog carries a tag")
        # '.fbx' is in plenty of names and is never a tag on its own.
        self.assertEqual(self.names_for("tag=.fbx"), [])

    def test_the_tags_blob_punctuation_is_not_searchable(self):
        # Matching tags_json raw let a search for the comma between two tags
        # return every multi-tag file in the library.
        self.assertEqual(self.names_for("tag=,"), [])
        self.assertEqual(self.names_for("tag=["), [])

    def test_an_ext_term_is_exact(self):
        self.assertNotEqual(self.names_for("ext=fbx"), [])
        self.assertEqual(self.names_for("ext=fb"), [])

    def test_a_type_term_matches_exactly_the_rows_of_that_type(self):
        # Against ground truth rather than the other code path: the prefilter
        # must never exclude a row the sieve would have kept.
        rows = self.every_row()
        for kind in atlas_mcp.QUERY_TYPE_VALUES:
            expected = sorted(row["name"] for row in rows
                              if atlas_mcp.effective_type(row) == kind)
            with self.subTest(kind=kind):
                self.assertEqual(self.names_for("type=" + kind), expected)

    def test_type_image_follows_the_app_and_excludes_textures(self):
        # effectiveType in the app resolves an image under Textures/ to
        # 'texture', so type=image is the images that are not textures. The
        # older type="image" argument does not draw that line; the grammar
        # follows the app, because the app is what it has to agree with.
        images = self.names_for("type=image")
        textures = self.names_for("type=texture")
        self.assertNotEqual(textures, [])
        self.assertEqual(set(images) & set(textures), set())

    def test_the_total_counts_what_matched_not_what_was_pruned(self):
        # count(*) over a prefiltered WHERE clause said 39,123 for
        # type=texture on the real library, where 4,205 match. A total that
        # overstates is worse than a slow one: it reports pages that are not
        # there.
        with atlas_mcp.open_catalog() as connection:
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE ignored = 0").fetchall()
            for kind in ("texture", "image"):
                truth = sum(1 for row in rows
                            if atlas_mcp.effective_type(row) == kind)
                with self.subTest(kind=kind):
                    _rows, total, _k = atlas_mcp.rows_for(
                        connection, {"query": "type=" + kind}, 1, 0)
                    self.assertEqual(total, truth)

    def test_the_grouped_total_is_sieved_too(self):
        # search_assets collapses duplicates by default, so the grouped total
        # is the number a caller actually reads.
        with atlas_mcp.open_catalog() as connection:
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE ignored = 0").fetchall()

            def groups(predicate):
                return {((row["name"] or "").lower(), row["size"])
                        for row in rows if predicate(row)}

            textures = groups(
                lambda row: atlas_mcp.effective_type(row) == "texture")
            images = groups(lambda row: row["type"] == "image")
            # Without an image that is not a texture, the assertion below
            # would hold for a sieve that did nothing at all.
            self.assertGreater(len(images), len(textures))

            _rows, total, _kind, _dupes = atlas_mcp.grouped_rows_for(
                connection, {"query": "type=texture"}, 1, 0)
            self.assertEqual(total, len(textures))

    def test_an_unprobed_clip_is_findable(self):
        # The hole this closed: model_kind is filled lazily and a rescan
        # empties it, so type=animation matched 0 of 34,801 FBX where 801 are
        # clips. Nothing is the worst of the available answers.
        with atlas_mcp.open_catalog() as connection:
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE ignored = 0").fetchall()
            unprobed = [row for row in rows if row["model_kind"] is None
                        and atlas_mcp.looks_like_animation(
                            row["relative_path"])]
            if not unprobed:
                self.skipTest("the fixture catalog has no unprobed clip")
            self.assertIn(unprobed[0]["name"], self.names_for("type=animation"))

    def test_the_two_model_filters_partition_the_models(self):
        with atlas_mcp.open_catalog() as connection:
            rows = connection.execute(
                "SELECT * FROM catalog_assets WHERE ignored = 0").fetchall()
            models = {row["name"] for row in rows
                      if atlas_mcp.effective_type(row) == "model"}
            clips = {row["name"] for row in rows
                     if atlas_mcp.effective_type(row) == "animation"}
        self.assertEqual(models & clips, set())
        self.assertEqual(set(self.names_for("type=model")), models)
        self.assertEqual(set(self.names_for("type=animation")), clips)

    def test_or_widens_and_a_space_narrows(self):
        fbx = self.names_for("ext=fbx")
        png = self.names_for("ext=png")
        self.assertNotEqual(fbx, [])
        self.assertNotEqual(png, [])
        self.assertEqual(self.names_for("ext=fbx or ext=png"),
                         sorted(fbx + png))
        self.assertEqual(self.names_for("ext=fbx ext=png"), [])

    def test_a_scoped_search_still_pages(self):
        body = self.call("search_assets", query="ext=fbx", limit=1)
        self.assertIn("FBX", body.upper())

    def test_a_rejected_query_reaches_the_caller_as_an_error(self):
        result = self.call_raw("search_assets", query="colour=red")
        self.assertTrue(result.get("isError"))
        self.assertIn("colour", result["content"][0]["text"])

    def test_look_says_what_it_is_waiting_for(self):
        # Not "unknown field": the field is going to exist, and the useful
        # answer names the pass it needs.
        result = self.call_raw("search_assets", query="look=grungy")
        self.assertTrue(result.get("isError"))
        self.assertIn("tagging", result["content"][0]["text"])


class TagsSqlTest(unittest.TestCase):
    """_TAGS_SQL has to agree with tags_words, which parses properly.

    The SQL is a replace chain because json_each cost 708 ms more per search,
    and a replace chain is only as good as the encodings it was written for.
    This is the check that says which those are.
    """

    ENCODINGS = (
        ("dart jsonEncode", lambda tags: json.dumps(tags, separators=(",", ":"))),
        ("python json.dumps", json.dumps),
    )

    CASES = (
        ["model", "fbx", "grungy"],
        ["model"],
        [],
        ["single"],
        ["a", "b", "c", "d", "e"],
        ["MixedCase", "UPPER"],
    )

    def setUp(self):
        self.connection = sqlite3.connect(":memory:")

    def tearDown(self):
        self.connection.close()

    def sql_words(self, blob):
        expression = atlas_mcp._TAGS_SQL.replace("tags_json", "?")
        return self.connection.execute(
            "SELECT " + expression, (blob,)).fetchone()[0]

    def test_the_sql_agrees_with_parsing_for_every_encoding(self):
        for label, encode in self.ENCODINGS:
            for tags in self.CASES:
                blob = encode(tags)
                with self.subTest(encoding=label, blob=blob):
                    self.assertEqual(self.sql_words(blob).split(),
                                     atlas_mcp.tags_words(blob).split())

    def test_a_missing_or_broken_blob_is_empty_rather_than_null(self):
        # A NULL here would propagate through the || in _SEARCH_SQL and make
        # every term fail to match, silently, for that row alone.
        for blob in (None, "", "[]"):
            with self.subTest(blob=blob):
                self.assertEqual(self.sql_words(blob), "")
                self.assertEqual(atlas_mcp.tags_words(blob), "")

    def test_a_blob_that_is_not_a_list_is_no_tags(self):
        for blob in ("{}", "null", "not json at all", '"a string"'):
            with self.subTest(blob=blob):
                self.assertEqual(atlas_mcp.tags_words(blob), "")

    def test_the_punctuation_itself_is_gone(self):
        blob = json.dumps(["model", "fbx"], separators=(",", ":"))
        words = self.sql_words(blob)
        for junk in ("[", "]", chr(34), ","):
            self.assertNotIn(junk, words)

    def test_case_is_folded_on_both_paths(self):
        blob = json.dumps(["MixedCase"])
        self.assertEqual(self.sql_words(blob).strip(), "mixedcase")
        self.assertEqual(atlas_mcp.tags_words(blob), "mixedcase")


class QueryGrammarMirrorTest(unittest.TestCase):
    """lib/main.dart has to hold the same grammar, under the same names.

    The app and the MCP are required to answer a search identically and are
    separate implementations, so the only things stopping them drifting are
    the shared fixture and this: a check that the Dart side still has the
    pieces the fixture names.
    """

    @classmethod
    def setUpClass(cls):
        here = os.path.dirname(os.path.abspath(__file__))
        dart = os.path.join(here, os.pardir, "asset_atlas_native", "lib",
                            "main.dart")
        if not os.path.exists(dart):
            raise unittest.SkipTest("lib/main.dart is not beside this checkout")
        with io.open(dart, encoding="utf-8") as handle:
            cls.dart = handle.read()
        cls.fixture = _query_fixture()

    def present(self, needle, why):
        # assertIn would print all 15,000 lines of main.dart on failure.
        self.assertTrue(needle in self.dart,
                        "lib/main.dart has no %s: %s" % (needle, why))

    def test_the_app_has_the_parser_and_the_matcher(self):
        for name in ("parseAssetQuery", "assetMatchesQuery", "AssetQuery"):
            self.present(name, "the app must parse the grammar, not just the "
                               "MCP")

    def test_the_app_lists_the_same_fields(self):
        match = re.search(r"assetQueryNamedFields\s*=\s*<String>\[([^]]*)\]",
                          self.dart)
        self.assertIsNotNone(match, "no assetQueryNamedFields in main.dart")
        found = re.findall(r"'([a-z]+)'", match.group(1))
        self.assertEqual(found, [f for f in self.fixture["fields"]
                                 if f != "any"])

    def test_the_app_knows_the_same_fields_are_exact(self):
        # A field moving between exact and substring on one side only is a
        # silent behaviour change: the box and the MCP would then disagree
        # about whether type=mod finds models.
        match = re.search(r"assetQueryExactFields\s*=\s*<String>\{([^}]*)\}",
                          self.dart)
        self.assertIsNotNone(match, "no assetQueryExactFields in main.dart")
        self.assertEqual(set(re.findall(r"'([a-z]+)'", match.group(1))),
                         set(self.fixture["exact_fields"]))

    def test_the_app_reserves_the_same_fields(self):
        for field in self.fixture["reserved_fields"]:
            self.present("'%s'" % field,
                         "a reserved field has to be reserved on both sides")

    def test_the_app_reads_the_same_fixture(self):
        # If the Dart suite stopped reading it, this file would be the only
        # thing holding the grammar and the guard above would be theatre.
        here = os.path.dirname(os.path.abspath(__file__))
        suite = os.path.join(here, os.pardir, "asset_atlas_native", "test",
                             "search_terms_test.dart")
        if not os.path.exists(suite):
            self.skipTest("the app's search test is not beside this checkout")
        with io.open(suite, encoding="utf-8") as handle:
            self.assertIn("search_queries.json", handle.read())


class ConsumerBriefTest(unittest.TestCase):
    """AI_BRIEF.md is handed to another model, so a stale name misleads it.

    The brief is the one document written for the consumer rather than the
    maintainer. Nothing else would notice if a tool were renamed under it:
    the brief would keep reading plausibly and send the model at a tool that
    no longer exists.
    """

    # Snake_case words in the brief that are deliberately not tool names.
    NOT_TOOLS = frozenset([
        "rig_family", "model_kind", "backfill_rigs", "atlas_mcp",
        "asset_atlas", "mcp_servers", "catalog_assets", "tag_assets",
        "atlas_embed", "like_path",
    ])

    @classmethod
    def setUpClass(cls):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "AI_BRIEF.md")
        with io.open(path, encoding="utf-8") as handle:
            cls.brief = handle.read()
        cls.quoted = set(re.findall(r"`([a-z][a-z_]{3,})`", cls.brief))

    def test_the_brief_exists_and_is_not_a_stub(self):
        self.assertGreater(len(self.brief), 2000)

    def test_every_tool_is_named_in_the_brief(self):
        # A consumer-facing list that silently omits a tool is a tool nobody
        # calls.
        missing = set(atlas_mcp.HANDLERS) - self.quoted
        self.assertEqual(missing, set(),
                         "AI_BRIEF.md names no %s" % sorted(missing))

    def test_every_prompt_is_named_in_the_brief(self):
        missing = set(atlas_mcp.PROMPT_BUILDERS) - self.quoted
        self.assertEqual(missing, set(),
                         "AI_BRIEF.md names no %s" % sorted(missing))

    def test_the_brief_names_nothing_that_does_not_exist(self):
        known = (set(atlas_mcp.HANDLERS) | set(atlas_mcp.PROMPT_BUILDERS)
                 | self.NOT_TOOLS)
        invented = {word for word in self.quoted
                    if "_" in word and word not in known}
        self.assertEqual(invented, set(),
                         "AI_BRIEF.md names %s, which is not a tool, a "
                         "prompt, or in NOT_TOOLS" % sorted(invented))

    def test_it_says_which_tools_need_atlas_open(self):
        # The single most common way this goes wrong for a consumer.
        for name in ("inspect_model", "rig_compatibility", "render_asset"):
            self.assertIn(name, self.quoted)
        self.assertIn("Atlas open", self.brief)

    def test_it_points_at_catalog_stats_first(self):
        # Live state -- is Atlas up, is rig_family filled -- changes what is
        # worth trying, and nothing else reports it.
        self.assertIn("catalog_stats", self.quoted)
        self.assertIn("Start here", self.brief)


class PromptTest(unittest.TestCase):
    """The prompts channel: the sequences, not the greetings."""

    def test_the_server_advertises_the_prompts_capability(self):
        # Without this a client will never call prompts/list, and the
        # sequences might as well not exist.
        result = atlas_mcp.handle_initialize({})
        self.assertIn("prompts", result["capabilities"])

    def test_prompts_list_returns_every_prompt(self):
        result = atlas_mcp.dispatch("prompts/list", None)
        names = [prompt["name"] for prompt in result["prompts"]]
        self.assertEqual(sorted(names), sorted(atlas_mcp.PROMPT_BUILDERS))

    def test_no_prompt_schema_leaks_its_builder(self):
        # The builder is a Python function; json.dumps would die on it.
        for prompt in atlas_mcp.PROMPT_SCHEMAS:
            self.assertNotIn("builder", prompt)
            json.dumps(prompt)

    def test_every_prompt_declares_the_arguments_it_interpolates(self):
        for prompt in atlas_mcp.PROMPT_SCHEMAS:
            for argument in prompt["arguments"]:
                self.assertIn("name", argument)
                self.assertIn("description", argument)

    def test_a_prompt_comes_back_as_a_user_message(self):
        result = atlas_mcp.dispatch(
            "prompts/get", {"name": "survey_the_library"})
        message, = result["messages"]
        self.assertEqual(message["role"], "user")
        self.assertEqual(message["content"]["type"], "text")
        self.assertIn("catalog_stats", message["content"]["text"])

    def test_arguments_are_interpolated_into_the_text(self):
        result = atlas_mcp.dispatch(
            "prompts/get",
            {"name": "set_up_a_level",
             "arguments": {"theme": "frozen dungeon", "engine": "5.4"}})
        body = result["messages"][0]["content"]["text"]
        self.assertIn("frozen dungeon", body)
        self.assertIn("5.4", body)

    def test_a_missing_argument_leaves_a_readable_sentence(self):
        # Every argument is optional, because a client may offer the prompt
        # with none filled in. The result has to read as English either way
        # rather than as a stray format placeholder.
        for name in atlas_mcp.PROMPT_BUILDERS:
            body = atlas_mcp.dispatch("prompts/get", {"name": name})
            text = body["messages"][0]["content"]["text"]
            self.assertNotIn("%s", text)
            self.assertNotIn("None", text)
            self.assertTrue(text.strip())

    def test_a_blank_argument_is_treated_as_absent(self):
        result = atlas_mcp.dispatch(
            "prompts/get",
            {"name": "import_a_model", "arguments": {"asset": "   "}})
        self.assertIn("not given",
                      result["messages"][0]["content"]["text"])

    def test_an_absent_argument_never_lands_inside_a_sentence(self):
        # "Get the assets for a the theme you want level" is what
        # interpolating a fallback mid-sentence produced. The parameters sit
        # on their own labelled lines so an absent one can say what to do
        # about itself instead of pretending to be a noun.
        for name, schema in zip(sorted(atlas_mcp.PROMPT_BUILDERS),
                                sorted(atlas_mcp.PROMPT_SCHEMAS,
                                       key=lambda p: p["name"])):
            if not schema["arguments"]:
                continue
            text = atlas_mcp.dispatch(
                "prompts/get", {"name": name})["messages"][0]["content"]["text"]
            for line in text.splitlines():
                if "(not " in line:
                    self.assertRegex(line, r"^\w[\w ]*: *\(not ",
                                     "%s: %r" % (name, line))

    # Snake_case words in a prompt that are deliberately not tool names.
    NOT_TOOLS = frozenset([
        "rig_family", "listchanged", "no_such_prompt",
    ])

    def test_no_prompt_names_a_tool_this_server_does_not_have(self):
        # A sequence that calls a tool that was renamed or never existed is
        # worse than no sequence: the model follows it and gets an error, and
        # nothing else in the repo would notice the drift.
        for name in atlas_mcp.PROMPT_BUILDERS:
            body = atlas_mcp.dispatch("prompts/get", {"name": name})
            text = body["messages"][0]["content"]["text"]
            tokens = set(re.findall(r"\b[a-z][a-z]+_[a-z_]+\b", text))
            unknown = tokens - set(atlas_mcp.HANDLERS) - self.NOT_TOOLS
            unknown -= set(atlas_mcp.PROMPT_BUILDERS)
            self.assertEqual(unknown, set(),
                             "%s names %s" % (name, sorted(unknown)))
            self.assertTrue(tokens & set(atlas_mcp.HANDLERS),
                            "%s names no tool at all" % name)

    def test_an_unknown_prompt_is_a_bad_request_not_a_server_fault(self):
        with self.assertRaises(atlas_mcp.JsonRpcError) as caught:
            atlas_mcp.dispatch("prompts/get", {"name": "no_such_prompt"})
        self.assertEqual(caught.exception.code, -32602)

    def test_serve_reports_that_code_rather_than_an_internal_error(self):
        request = json.dumps({"jsonrpc": "2.0", "id": 7,
                              "method": "prompts/get",
                              "params": {"name": "nope"}})
        out = io.StringIO()
        atlas_mcp.serve(stdin=io.StringIO(request + "\n"), stdout=out)
        reply = json.loads(out.getvalue())
        self.assertEqual(reply["error"]["code"], -32602)

    def test_the_instructions_point_at_the_prompts(self):
        # instructions is optional in the spec and some clients drop it, but
        # a client that does read it should know the sequences are there.
        self.assertIn("prompts", atlas_mcp.INSTRUCTIONS)


class ArgumentTypeTest(unittest.TestCase):
    """What happens when a client sends the type the *name* suggests.

    Arguments arrive as JSON from a model writing JSON, and it reaches for
    the type the name implies rather than the type the schema states. Both
    directions went wrong: `inspect=true` raised `'bool' object has no
    attribute 'lower'`, and `overwrite="false"` was read as true.
    """

    def test_text_takes_a_number_because_a_number_is_unambiguous(self):
        # A pack called 2024 is a pack.
        self.assertEqual(
            atlas_mcp.text_argument({"pack": 2024}, "pack"), "2024")

    def test_text_refuses_a_boolean_in_words_a_caller_can_act_on(self):
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.text_argument({"pack": True}, "pack")
        message = str(caught.exception)
        self.assertIn("pack", message)
        self.assertNotIn("object has no attribute", message)

    def test_text_refuses_a_list_by_saying_it_takes_one(self):
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.text_argument({"pack": ["a", "b"]}, "pack")
        self.assertIn("single piece of text", str(caught.exception))

    def test_an_absent_or_empty_argument_is_the_default(self):
        self.assertEqual(atlas_mcp.text_argument({}, "pack", "all"), "all")
        self.assertEqual(
            atlas_mcp.text_argument({"pack": ""}, "pack", "all"), "all")

    def test_a_number_may_arrive_as_text(self):
        self.assertEqual(atlas_mcp.int_argument({"limit": "20"}, "limit", 5),
                         20)

    def test_a_number_refuses_a_boolean_rather_than_counting_it_as_one(self):
        # bool is a subclass of int, so int(True) is 1: a limit of one
        # result, silently, where the caller asked for something else.
        with self.assertRaises(atlas_mcp.AtlasError):
            atlas_mcp.int_argument({"limit": True}, "limit", 5)

    def test_a_number_refuses_words(self):
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.int_argument({"limit": "twenty"}, "limit", 5)
        self.assertIn("whole number", str(caught.exception))

    def test_a_float_may_arrive_as_text(self):
        self.assertEqual(atlas_mcp.float_argument({"yaw": "0.6"}, "yaw"), 0.6)
        self.assertIsNone(atlas_mcp.float_argument({}, "yaw"))

    def test_the_word_false_means_false(self):
        # bool("false") is True. This is the one that overwrote files the
        # caller had asked to leave alone.
        for word in ("false", "FALSE", " no ", "off", "0"):
            self.assertIs(
                atlas_mcp.bool_argument({"overwrite": word}, "overwrite"),
                False, "%r should be false" % word)

    def test_the_word_true_means_true(self):
        for word in ("true", "TRUE", "yes", "on", "1"):
            self.assertIs(
                atlas_mcp.bool_argument({"overwrite": word}, "overwrite"),
                True, "%r should be true" % word)

    def test_a_real_boolean_is_taken_as_it_is(self):
        self.assertIs(
            atlas_mcp.bool_argument({"overwrite": True}, "overwrite"), True)
        self.assertIs(
            atlas_mcp.bool_argument({"overwrite": False}, "overwrite"), False)

    def test_a_default_of_true_survives_an_absent_argument(self):
        # distinct defaults to collapsing copies.
        self.assertIs(atlas_mcp.bool_argument({}, "distinct", True), True)
        self.assertIs(
            atlas_mcp.bool_argument({"distinct": False}, "distinct", True),
            False)

    def test_a_word_that_is_neither_is_refused_not_guessed(self):
        with self.assertRaises(atlas_mcp.AtlasError) as caught:
            atlas_mcp.bool_argument({"overwrite": "maybe"}, "overwrite")
        self.assertIn("true or false", str(caught.exception))


class GetAssetInspectTest(CatalogTest):
    """get_asset's `inspect`, which reads boolean and is a string enum.

    Each of these asserts the asset's own details came back, not merely that
    an error did not. Asserting the absence of a message is how a test ends
    up passing on "nothing in the catalog matches" instead of on the fix --
    the first draft of these named an asset the fixture does not have.
    """

    ASSET = "SM_Prop_Anvil_01.fbx"

    def answered_about_the_asset(self, result):
        self.assertFalse(result.get("isError"),
                         result["content"][0].get("text"))
        body = result["content"][0]["text"]
        self.assertNotIn("has no attribute", body)
        # The handler reached its report, which the AttributeError prevented.
        self.assertIn(self.ASSET, body)
        self.assertIn("path", body)
        return body

    def test_inspect_true_is_honoured_rather_than_crashing(self):
        # The reported failure: 'bool' object has no attribute 'lower'.
        self.answered_about_the_asset(
            self.call_raw("get_asset", path=self.ASSET, inspect=True))

    def test_inspect_false_is_honoured_too(self):
        self.answered_about_the_asset(
            self.call_raw("get_asset", path=self.ASSET, inspect=False))

    def test_the_documented_words_still_work(self):
        for word in ("none", "summary", "full"):
            self.answered_about_the_asset(
                self.call_raw("get_asset", path=self.ASSET, inspect=word))

    def test_the_text_true_still_works_as_it_did(self):
        # What the user fell back to when the boolean failed.
        self.answered_about_the_asset(
            self.call_raw("get_asset", path=self.ASSET, inspect="true"))

    def test_absent_means_summary_as_before(self):
        self.answered_about_the_asset(
            self.call_raw("get_asset", path=self.ASSET))

    def test_a_value_that_means_nothing_is_explained(self):
        result = self.call_raw("get_asset", path=self.ASSET,
                               inspect="sideways")
        self.assertTrue(result.get("isError"))
        body = result["content"][0]["text"]
        self.assertIn("none", body)
        self.assertIn("summary", body)
        self.assertIn("full", body)
        self.assertNotIn("has no attribute", body)


if __name__ == "__main__":
    unittest.main()
