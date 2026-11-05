"""Tests for the Atlas MCP server.

Two kinds. The protocol and formatting tests build a catalog of their own in a
temporary file and need nothing else. The mirror test reads lib/main.dart and
fails if the attachment keywords here have drifted from the ones the app
actually uses -- the hazard of restating a table in a second language.

Run: python -m unittest discover -s work/atlas_mcp
"""

import io
import json
import os
import re
import sqlite3
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
