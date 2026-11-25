# Workspace State

Last updated: 2026-11-24
Project / engine: Not applicable — Flutter Windows desktop app (AssetAtlas).
  User directive 2026-11-14: no engine rule applies here; generic contract only.
Engine version: N/A
Playdate framework: N/A

## Progress
- 2026-11-24, rig correctness, on `fix/stage-1-correctness`. One plan document
  covering ten requested items (`docs/tasks/PLAN-2026-11-24-rigs-twins-formats-tagging.md`,
  committed `d7de2a6`), then four of its work packages:
  `82a175c` v1.10.45 `.uasset` no longer reaches the audio player;
  `0f1d356` v1.10.46 the search text survives a type change;
  `6097144` v1.10.47 bone lookup folds case after every exact form fails,
  plus `rigMatch` as the single match rule;
  v1.10.48 one rig classifier owned by `work/atlas_mcp/fixtures/rig_families.json`,
  a new `other` family, and unreal/sidekick compatibility. See DECISIONS.md
  RIG-001. 736 Dart tests, 407 Python tests, analyze clean.
- 2026-11-24, the rest of the plan, on `fix/stage-1-correctness`:
  `6f796f9` v1.10.49 WP5 rig signatures (schema v8: `rig_signature` and a
  `rig_bones` table), the model/animation lists and audition, and WP7 twins --
  a `.uasset` now draws its FBX twin;
  `f8051b7` v1.10.50 WP6 the authored texture (both Unity container formats),
  WP8 GLB and glTF through cgltf with DAE declined, and WP9 tagging modes plus
  the instrumentation that says whether a run is render-bound or embed-bound.
  852 Dart tests, 422 Python tests, analyze clean. DECISIONS.md RIG-001,
  FMT-001, TEX-001.
- 2026-11-24 the catalog was backfilled a second time for the signatures
  (backup `asset_atlas_native.db.before-rig-signatures`): 44,458 FBX read,
  2,355 of them rigged, **129 distinct rigs**, 12 of which cover all 796 clips.
- Verified in the running app at 1.10.50, through the bridge: the War Robot
  reports "1 of 1 materials textured, SciFiSpaceBase4 textured 2048x2048" and
  draws as a dark robot with blue panels. It read `flat colour, no texture`
  before.
- 2026-11-24 `6c4a940` find_animations answers from the `rig_family` column
  instead of re-reading files. It was returning nothing for every question --
  "None of the 9 clips looked at are on the sidekick rig" with 346 in the
  library -- because its prefilter pulls in never-read model rows. Measured
  after: 346 clips for the War Robot, 88 for the dog (all in its own pack),
  no file reads. WP5's MCP step brought forward; signatures still to come.
- 2026-11-24 Atlas rebuilt at 1.10.48 and left running. Before that the built
  exe was 1.10.44, which predates `other` and would have read those 244 files
  as "No rig". Verified through the bridge: inspect_model reports the robot as
  Unreal/48 bones, and rig_compatibility calls a Sidekick walk playable over
  28 shared bones while refusing a Polygon clip at 14.
- 2026-11-24 the `rig_family` column was re-filled under the new rule
  (`backfill_rigs.py --all`, authorised by the user that day, Atlas closed,
  catalog backed up to `asset_atlas_native.db.before-rig-rules-2`). 44,458 of
  44,463 FBX read in about 7 minutes; the 5 skipped are the rows already
  marked unreadable. Families now: none 42,103, sidekick 1,257, polygon 509,
  unreal 345, other 244. No clip is `none` any more -- the 91 that were, and
  13 mislabelled `polygon`, are the 104 `other` clips.
- `460af7a` Six MCP prompts for the common Unreal sequences (survey_the_library,
  set_up_a_level, import_a_model, animate_a_character, dress_a_character,
  choose_a_build). 13 tests. Verified over stdio.
- `e1b6e9c` Probe/classification fix: concurrent pipe drain in
  `runMeshImporter`, guarded `stdin.close()`, and `classifyFbxChunk` no longer
  records our own failure as `'unreadable'` in the catalog. 414 Dart tests,
  analyze clean. Version 1.10.29.
- `a1b37b8` Adopted the new behaviour contract, `.claude/` agents/skills/rules,
  and continuity documents. Previous instructions kept as `CLAUDE.old.md`.
- Embedding store implemented: `work/atlas_mcp/embedding_store.py`, 32 tests
  passing. Validated at full scale (13,933 × 768): append 579 ms, `matrix()`
  16 ms cold / 0 ms warm, 44.3 MB on disk. **Uncommitted.**

## Plans
- Approved: storage design EMB-001 (flat file + SQLite index, outside the
  catalog); search in a native helper EMB-002.
- Blocked, needs approval: onnxruntime + SigLIP 2 weights for
  `asset_atlas_tagger.exe`, and the installer size change that implies.
- **Next, and now evidence-backed as the only workable route:** the in-Atlas
  tagging queue (`startAssetTagging`). EMB-003 established that the
  texture-to-model link can only come from Atlas, so the queue is not merely
  the convenient place for tagging, it is the only place the link exists.
  Design not yet proposed in detail; needs approval before building.
- Proposed, unapproved: EMB-004, persist the average texture colour that
  `averageImageColor` already computes, which answers colour queries with no
  model at all.
- Open from earlier: library rescan (catalog on rules v2, app on v3);
  PR #3 awaiting merge. Both backfills are done -- see Progress.
- The plan's nine work packages are all implemented. WP9 step 1 and the
  re-embedding are now done too (2026-11-25, below). What it still leaves
  open, by its own text: grid collapsing of twins, and reading inside a
  `.uasset` for its class.
- 2026-11-25, with the machine free: the four modes were timed, the two
  stages behind them measured, and the models whose picture WP6 changed were
  re-embedded. `9e78d17` added `--force`, `3fd8b1a` and `aac137f` removed
  three per-model walks of the 480,826-row catalog and a per-model 2048x2048
  PNG decode that my own WP6 work had introduced. Measured on this machine:
  bridge render 372 ms, embed 478/263/154/132 ms at 1/2/6/10 threads, warm
  pack end to end 760 ms a model, library order about 4 s a model. The thread
  count is the dial; lanes alone change nothing because four lanes queue
  behind one worker.
- The re-embed: `find_changed_models.py` probed all 43,662 mesh FBX and found
  **7,148 (16%)** whose own file names no texture -- exactly the models WP6
  now draws with the pack's atlas. `tag_assets.py --force --threads 10
  --ids-file` took that list: **6,335 embedded in 68 min (645 ms each), 0
  failed**. The 813 ids it did not take are duplicate-group siblings that
  `candidates()` never offers -- it returns `min(id)` per `(lower(name),
  size)` group -- and 795 of the 796 without a vector have a sibling that
  carries one. The one real gap was `glass.fbx` (Kenney Food Kit), now fixed
  and embedded -- see below.
- 2026-11-25, v1.10.51 on `fix/stage-1-correctness`, three things:
  - `88f13df` the importer no longer prints bare `nan` into its JSON. JSON has
    no NaN, so a model carrying one was unreadable rather than slightly wrong.
    Every float in both readers goes through `json_double` (shared header
    `windows/runner/json_number.h`). glass.fbx reads now; its three recorded
    failures were cleared and it embedded, so **48,131 models have a vector**
    and six given-up models remain, all genuinely unreadable.
  - `b5b5a65` the 30-to-60 second stall Mike hit (All + `war_robot_01`,
    select, switch to Character). Measured, not guessed, against the real
    catalog: `twinIndexFor` 4,706 ms, `findInferredTexture` 4,204 ms,
    `sortAssets` 6,726 ms, a filter pass 627 ms -- now 728 / 1,562 / 1,734 /
    423 ms. Causes: a `RegExp` constructed per asset in three functions, a
    `lastIndexOf(RegExp)` separator search worth 2.6 s on its own, sort keys
    built inside the comparator, and a sorted list keyed on an epoch that
    three unrelated things bump. See DECISIONS.md PERF-001.
  - `b5b5a65` also collapses a model's versions into one row: 480,826 files
    in 360,814 rows, 29,930 of them standing for more than one. Mike chose
    the grouping (same pack and same name, across formats and engine
    versions) and chose it on by default. See DECISIONS.md LIST-001.
  - **The Windows binary is not rebuilt**: Atlas 1.10.50 was running and
    holds `asset_atlas_native.exe`, so `flutter build windows` fails to link.
    The importer exe *is* rebuilt. Mike has to close Atlas for the app build.
- WP3's by-eye acceptance was done offline rather than in the app: the robot
  posed by a Sidekick idle and a forward walk, rendered through Atlas's own
  pose-and-rasterise path, with the controls unchanged. Watching it in the
  window itself is the one check nobody has run.

## Problems
- The stall fix leaves three stages still above a second on the UI thread:
  `sortAssets` 1,734 ms (once per catalog and sort mode), the Unity and
  texture index builds behind `findInferredTexture` 1,562 ms (once per
  catalog, paid by whoever clicks first), and `collapseAssetVersions` 222 ms
  per filter pass once its keys are cached. Nothing here is a freeze any
  more, but none of it is off the UI thread either.
- `embeddings.f32` is append-only, so a forced re-embed leaves the old rows
  behind: 145,442 rows in the file against 138,746 in the index, about 20 MB
  of 447 MB now dead. Harmless but it will only grow with each forced pass;
  there is no compaction.
- PR #3 now carries `a1b37b8`, which is workflow configuration unrelated to
  that PR's subject. Not moved to its own branch — awaiting the user's call.
- Standing Flutter gate (`flutter analyze` + `flutter test`) conflicts with
  the new contract: `CLAUDE.old.md` makes it mandatory before every commit,
  the contract requires approval before commands that write output. Unresolved.
- `CLAUDE.old.md` holds Atlas-specific knowledge that is no longer on the
  automatically loaded path. See ARCHITECTURE.md "Known discrepancies".
- Installer size for the tagger's dependencies is **Unknown**; order
  100–400 MB, unmeasured.

## User Directives
- 2026-11-25: collapse the versions of one asset into one row in the list.
  Mike chose the grouping -- same pack and same name, across formats and
  engine versions -- and chose it on by default, with a toggle.
- 2026-11-25: "the machine is free, run the tagging" -- lifts the 11-24 hold
  for that run only. The hold stands again by default.
- 2026-11-24: no full tagging or embedding run while the user is working on
  this machine. Small scoped tests are fine; ask before anything long.
- 2026-11-24: the catalog rig backfill may be run once the code is right,
  with Atlas closed and the user told afterwards.
- 2026-11-24: read `.unitypackage` for the authored texture chain (approved);
  vendor `cgltf` for GLB and glTF (approved); do not write a DAE reader
  (declined -- every DAE has a twin that already draws).
- 2026-11-24: `none` and `other` are different rig answers, and a clip may
  drive a character across the unreal/sidekick pair. Existing tests that
  encoded the old meaning were changed with explicit approval.
- Approve a bounded design before anything new is built.
- Confirm architecture or data changes before anything is checked in.
- No engine rule for this repository; generic rules apply.
- Asset tagging must be runnable from inside Atlas on a newly added folder,
  queued on a thread, leaving CPU for other work on the machine.
- Texture-derived tags are supplemental; renders of the geometry are primary.
- Cache embeddings after the first pass.
- Atlas and the MCP must use the same algorithm; Dart calls the same exe
  rather than reimplementing ranking.

## Decisions
- EMB-001 Accepted — embeddings in a flat file beside the catalog, not in it.
- EMB-002 Accepted in principle — similarity search in a native helper.
- EMB-003 Accepted on evidence — the texture-to-model link comes from
  Atlas; the Python-side join was killed at 29.1% against a 70% bar.
- EMB-005 Accepted — Atlas and the MCP call the same executable, ranking
  included; no caller ranks, tokenises, or resizes.
- EMB-004 Proposed — persist the average texture colour already computed.
- Rejected: vector database (FAISS/sqlite-vss/Chroma) at this scale.

## Automation Opportunities
| Repeated task | Frequency/evidence | Proposed script/skill/test | Benefit | Status |
|---|---|---|---|---|
| Measuring storage/throughput options before a design choice | Twice this session (storage benchmark, importer timing) | Reusable micro-benchmark harness under `work/atlas_mcp/` | Keeps "supported measurements" cheap to produce | Not proposed — twice is not yet a pattern |

## References
- Catalog (read-only): `%APPDATA%/com.example/asset_atlas_native/asset_atlas_native.db`
- Verified inventory: 73,865 rows; 27,652 FBX (99.5% zipped); 13,933 distinct
  FBX by name+size; 19,134 OBJ; 2,143 PNG; 24,894 uasset/umap.
- Verified per-asset cost, zipped FBX via `--stdin`: inflate 1 ms median,
  `--summary` 18 ms, full import 18 ms median / 42 ms max.
- PR: https://github.com/TheMikaus/AssetAtlas/pull/3 (open, branch
  `fix/stage-1-correctness`)
- Prior instructions: `CLAUDE.old.md`
