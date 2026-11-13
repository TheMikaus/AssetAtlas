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
        source = io.open(dart, encoding="utf-8").read()
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
        source = io.open(dart, encoding="utf-8").read()
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


if __name__ == "__main__":
    unittest.main()
