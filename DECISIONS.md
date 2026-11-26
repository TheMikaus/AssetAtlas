# Architecture Decision Log

Record significant **approved** decisions; do not confuse proposals with implemented choices.

## Decision template
- ID / date:
- Status: Proposed | Accepted | Superseded | Rejected
- Context and verified evidence:
- Options considered (including external tools and alternate languages):
- Decision and rationale:
- Tradeoffs / risks:
- Affected components and source references:
- Validation and revisit trigger:

---

## EMB-001 — Embedding vectors live in a flat file beside the catalog, not in it

- **ID / date:** EMB-001 / 2026-11-14
- **Status:** Accepted (user approval, 2026-11-14)
- **Context and verified evidence:** Visual auto-tagging needs one float32 vector
  per asset so a text query ("grungy") can be matched by similarity. Verified
  catalog inventory: 73,865 rows, 27,652 FBX (99.5% inside zips), **13,933
  distinct FBX by name+size**, 2,143 PNG. At 768 dimensions that is 42.8 MB of
  vectors. The hot path is a full scan, because a similarity search dots the
  query against every vector; a single-row lookup is not a search operation.
- **Options considered:**
  - A. BLOB column added to `catalog_assets` (schema v7 → v8).
  - B. BLOBs in a separate SQLite file.
  - C. Flat fixed-stride binary file + small SQLite index. **Chosen.**
  - D. Vector database (FAISS, sqlite-vss, Chroma). Rejected without
    benchmarking: brute force at this scale is sub-second in native code, so an
    ANN index would add a dependency and buy nothing.
- **Measured comparison** (42.8 MB payload, same machine, one run):

  | Operation | A catalog | B separate | C flat |
  | --- | --- | --- | --- |
  | bulk write | 1492 ms | 1642 ms | 173 ms |
  | load all → array | 157 ms | 121 ms | 60 ms |
  | load all → fast form | 111 ms | 122 ms | 0.3 ms (mmap, warm) |
  | single read | 0.1 ms | 0.2 ms | 0.2 ms |
  | append 500 | 36 ms | 29 ms | 23 ms |
  | on disk | 60.3 MB | 60.3 MB | 46.6 MB |

  Overhead on the payload: SQLite +41%, flat +9%.
- **Decision and rationale:**
  1. Memory-mapping a fixed-stride file exposes all 42.8 MB as floats in 16 ms
     cold and 0 ms warm. SQLite's best full scan is 111 ms and cannot be
     mapped — blobs are stored per row, so a scan pays a copy per row.
  2. SQLite's only win, the 0.1 ms indexed single read, is on an operation the
     search never performs, and the flat file ties it at 0.2 ms via `seek`.
  3. Embeddings are a **derived cache**, regenerable from the assets. Putting
     43 MB of cache inside the user's library file, behind a schema migration
     whose `onCreate`/`onUpgrade` convergence `test/database_test.dart`
     asserts, buys nothing and risks the catalog.
  4. Metadata (`asset_id → row`, `source`, `computed_ms`) stays in SQLite,
     where indexing and transactions earn their place.
- **Tradeoffs / risks:**
  - A flat file plus a separate index can disagree after a crash, where a
    single SQLite transaction could not. Mitigated by a fixed write order —
    vectors, then the header count, then the index — so a crash leaves either
    unpublished bytes (ignored) or unindexed rows (wasted, harmless). The
    reverse order would leave index rows naming vectors that do not exist,
    which is a wrong answer rather than a missing one. Four tests cover these
    windows directly.
  - `model_id` sits in the header because a different embedding model
    invalidates every vector. A mismatch reports zero usable rows rather than
    comparing across two embedding spaces.
- **Affected components and source references:**
  - `work/atlas_mcp/embedding_store.py` — implemented.
  - `work/atlas_mcp/test_embedding_store.py` — 32 tests, passing.
  - No change to `catalog_assets`; schema stays at v7.
- **Validation and revisit trigger:** Validated at full scale through the
  module: 13,933 × 768 appended in 579 ms, `matrix()` 16 ms cold / 0 ms warm,
  `row_of` 0.1 ms, append-500 26 ms, 44.3 MB on disk. Revisit above ~200,000
  vectors, where an ANN index may start to pay for itself.

## EMB-002 — Similarity search runs in a native helper, not in the MCP server

- **ID / date:** EMB-002 / 2026-11-14
- **Status:** Accepted in principle (user approval, 2026-11-14); **not
  implemented** — blocked on approval for onnxruntime and model weights.
- **Context and verified evidence:** `work/atlas_mcp` is deliberately standard
  library only, so that the MCP server cannot fail to start because a pip
  install went stale. Verified: numpy 1.26.4 is present in the default
  interpreter but absent under `python -I` (which implies `-s`, excluding the
  user site-packages where it lives). Verified: a pure-stdlib brute-force dot
  product over 13,933 × 768 takes **1,234 ms**, and scales linearly — about
  3.5 s at 40,000 assets. That is a compute problem; no storage choice fixes it.
- **Options considered:** accept 1.2 s per query; add numpy to the MCP
  (breaks the stdlib-only rule); run the search in the Atlas bridge so Dart
  does it; run it in a native helper. **Chosen:** native helper.
- **Decision and rationale:** `asset_atlas_tagger.exe` text-encodes the query,
  maps the vector file, dots, and returns top-N asset ids. The MCP shells out
  to it exactly as it already shells out to `asset_atlas_mesh_importer.exe`, so
  the stdlib-only rule holds. This also reinforces EMB-001: mapping a
  fixed-stride file from C++ is a few lines, where reading BLOBs would need
  sqlite3 linkage and row iteration.
- **Tradeoffs / risks:** the installer must carry onnxruntime and SigLIP 2
  weights. Size is **Unknown** pending a quantised ONNX export; order
  100–400 MB. That is a material change to `create_windows_installer.ps1`
  output and needs separate approval.
- **Affected components and source references:** proposed
  `windows/runner/` target alongside `mesh_importer.cpp`; consumer in
  `work/atlas_mcp/atlas_mcp.py`.
- **Validation and revisit trigger:** must beat 50 ms at 13,933 vectors.
  Revisit if the model choice changes the embedding dimension.

## EMB-003 — The texture-to-model link comes from Atlas, never from the FBX references

- **ID / date:** EMB-003 / 2026-11-14
- **Status:** Accepted on evidence (validation spike, kill criterion met)
- **Context:** Style words barely separate on a render — measured, two Atlas
  renders: "grungy and weathered" scored +0.0610 against a bin and +0.0528
  against a mech, where content captions separated by 2.5x. A render carries
  shape; style lives in the texture. So a style tag has to be computed on the
  texture and propagated to the models that use it, which needs a
  texture-to-model link.
- **What was tried:** harvest each FBX's `textureFiles` with the importer's
  `--summary` (verified cheap: 1,819 models across three packs in 4.1 s
  total) and join those references to catalog image rows in Python.
- **Verified result — the kill criterion fired.** Over 1,819 models in
  POLYGON_AncientEmpire, POLYGON_Nightclubs and POLYGON_Nature:

  | Join stage | Models | Share |
  | --- | --- | --- |
  | exact name, same pack | 475 | 26.1% |
  | stem only, same pack (`.psd` → `.png`) | 50 | 2.7% |
  | stem, another pack | 4 | 0.2% |
  | **no match at all** | **1,196** | **65.8%** |
  | named no texture | 94 | 5.2% |

  29.1% joinable by name, against a 70% threshold.
- **Why, verified:** the references are the artist's authoring-time paths. The
  commonest are `.psd` files — `polygonancientworlds_texture_01.psd` appears
  442 times — and the catalog holds **2** `.psd` rows in total. A search of
  **all 187 archives** for the five commonest unmatched basenames returned
  **zero hits**: those files are not in the library at all. The packs ship
  differently-named exported atlases.
- **Decision:** do not reconstruct the link in Python. Atlas already resolves
  it correctly during import — `material.resolvedTextures`
  (`lib/main.dart:11813`) is the output of the six-stage cascade documented in
  `CLAUDE.old.md`, including the within-container word-token relink that is
  what actually connects these references to the shipped atlases. The tagging
  pass harvests that set.
- **Already in hand and thrown away:** `_recordTexturesUsedBy`
  (`lib/main.dart:1298`) builds exactly this set on every model preview and
  discards it after setting the `referenced_by_model` boolean — which is why
  that column is 4 of 73,865 rows and says *that* an image is used, not by
  what.
- **Tradeoffs / risks:** the link can only be harvested where Atlas imports
  the model, so it is bound to the in-Atlas tagging queue rather than being a
  standalone script. That is the same conclusion the bridge reached for
  `inspect_model`, for the same reason: a second implementation of
  load-bearing logic drifts.
- **Validation and revisit trigger:** revisit only if the importer starts
  emitting resolved rather than raw texture paths.

## EMB-005 — Atlas and the MCP call the same executable, including for ranking

- **ID / date:** EMB-005 / 2026-11-14
- **Status:** Accepted (user directive, 2026-11-14: "the two should use the
  same algorithm. If that means having dart call the same exe then do that")
- **Context:** EMB-002 put query embedding and ranking in a native helper that
  the MCP calls. The app needs the same search. Reading the vector file from
  Dart is trivial — it is fixed-stride, so `Float32List.view` over the bytes —
  which made "Dart ranks it itself" the obvious shortcut. That shortcut is two
  implementations of one algorithm, which is the drift the `attachPoints`
  guard test exists to catch, and it would drift silently: a ranking is
  plausible whether or not it is right.
- **Decision:** `asset_atlas_tagger.exe` is the only implementation. Atlas
  shells out to it exactly as it shells out to `asset_atlas_mesh_importer.exe`.
  Neither caller ranks, neither caller tokenises, neither caller normalises
  pixels. The search mode takes the query and the store and returns ordered
  asset ids, so there is nothing left for a caller to get differently.
- **Three drift sources, and how each is removed:**
  1. *Ranking* — lives only in the tagger's `--search` mode. A caller that
     wanted to rank would have to ask for vectors, and nothing exposes them.
  2. *Tokenisation and text normalisation* — only in the tagger. Verified
     fiddly and unspecified by the model files: `tokenizer_config.json` gives
     `GemmaTokenizer` and `do_lower_case` but says nothing about `<bos>`,
     `<eos>` or padding width, and a wrong choice returns a plausible vector
     rather than an error.
  3. *Image preprocessing* — **removed rather than centralised.** Atlas
     renders at exactly 224x224, which the existing render path already allows
     (`bridgeRender` clamps to 64..2048, `lib/main.dart:15364`), so there is
     no resize for two implementations to disagree about. A bicubic resize in
     Dart and one in C++ differ in the low bits, and those bits reach the
     vector. Only the normalisation `(x / 255 - 0.5) / 0.5` remains, in the
     tagger.
- **Tradeoffs / risks:**
  - A process launch per image would pay the model load every time — measured
    199 ms load against 74 ms per image, so 13,933 single-image launches would
    cost about an hour against 17 minutes. The embed mode therefore takes a
    *chunk* on stdin and returns a chunk on stdout, amortising the load the
    way `buildFbxClassifyChunks` already amortises archive opening.
  - SentencePiece must be vendored as C++ for the text side. **Measured
    2026-11-14**, and the risk is not where it was expected.

    *Runtime footprint is a non-issue.* The compiled library is 1.72 MB
    (`_sentencepiece.cp312-win_amd64.pyd`), and the whole installed package is
    2.88 MB including 0.98 MB of NFKC normalisation tables. Against 345 MB of
    model weights this does not register.

    *Build cost is the real objection.* `SPM_PROTOBUF_PROVIDER` defaults to
    `"module"`, which fetches **protobuf v36.2** as a FetchContent subproject
    at configure time — so configuring needs network access and builds
    protobuf. It also sets `CMAKE_CXX_STANDARD 20`, where Atlas's
    `apply_standard_settings` sets `cxx_std_17`
    (`windows/CMakeLists.txt:41`); a separate `add_executable` can override
    that, but it diverges from the pattern `asset_atlas_mesh_importer`
    follows. `SPM_ENABLE_SHARED` defaults OFF on Windows, which is what is
    wanted; `SPM_ENABLE_TCMALLOC` defaults ON and would want turning off for
    a hermetic build. For scale: the only other vendored dependency here,
    ufbx, is **1.4 MB in two files**.

    (An earlier note in this log referred to `SPM_USE_BUILTIN_PROTOBUF`. That
    option is not in the current CMakeLists; the control is
    `SPM_PROTOBUF_PROVIDER`.)

    *Three ways out, unresolved:*
    - **A. Vendor it as upstream intends.** Exactly correct, no
      reimplementation. Costs a protobuf subproject, a C++20 override and
      configure-time network.
    - **B. `SPM_PROTOBUF_PROVIDER=package`** against a prebuilt protobuf.
      Trades FetchContent for a system dependency; worse for a repeatable
      build.
    - **C. Convert the vocabulary offline, encode in the tagger.** Emit a
      flat `(piece, id, score)` table once using the Python package already
      installed, then implement unigram Viterbi in the tagger — on the order
      of 200 lines, no dependencies, no protobuf, no C++20. Pinned by a guard
      test whose fixture is a corpus of queries whose ids must match the
      Python reference exactly, the same shape as the `attachPoints` guard.

    C is the recommendation, with one caveat: SigLIP canonicalisation already
    lowercases and strips punctuation, so for ASCII queries the NFKC path
    those 0.98 MB of tables implement is largely bypassed. That is
    **unverified for non-ASCII input**, and if multilingual queries matter,
    A is the honest choice instead. C also reimplements tokenisation, which
    sits awkwardly beside this decision's own rule — the defence is that it
    would still be the *only* implementation in shipped code, with Python
    used offline to build the table and the fixture, and the guard test is
    what makes that safe rather than merely hoped for.
- **Affected components:** new `windows/runner/tagger.cpp` plus an
  `add_executable` target following the `asset_atlas_mesh_importer` pattern
  (`windows/runner/CMakeLists.txt:42`); consumers in `lib/main.dart` and
  `work/atlas_mcp/atlas_mcp.py`.
- **Validation and revisit trigger:** a fixture test in which the same query
  over the same store returns the same ordered ids whether invoked from Dart
  or from Python — the same shape as the `attachPoints` guard. Revisit only if
  one caller needs vectors rather than rankings.

## EMB-004 — Average texture colour is already computed and only needs persisting

- **ID / date:** EMB-004 / 2026-11-14
- **Status:** Proposed (not approved, not implemented)
- **Context and verified evidence:** "find UI elements that are gray" needs a
  per-image colour. Verified: there is no colour anywhere in the catalog, and
  `tags_json` is only the file name split into words. Verified: `gray` matches
  0 of 73,865 names and `grey` matches 35, all of them beards, bricks and a
  blank material. But `averageImageColor` (`lib/main.dart:9262`) and
  `firstTextureAverageColor` (`lib/main.dart:9207`) already exist and already
  run on every model preview; the result is used for display and dropped.
- **Decision (proposed):** persist it rather than add a model for it. A
  colour filter needs no embeddings and no onnxruntime.
- **Affected components:** `lib/main.dart`, and a column or sidecar for the
  value. Data change — needs approval.


## RIG-001 — One rig rule, owned by a fixture, with a family for rigs we cannot name

- **ID / date:** RIG-001 / 2026-11-24
- **Status:** Accepted (user approval, 2026-11-24, after a read-only
  investigation he asked for and a plan he approved:
  `docs/tasks/PLAN-2026-11-24-rigs-twins-formats-tagging.md`, WP3 and WP4)
- **Context and verified evidence:** Animation mapping did not work. Four
  measured causes, over the real library:
  - **Case.** `SkeletonAnimation.indexOfBone` compared bone names with `==`,
    and Synty writes mixed case inside one skeleton:
    `SK_Chr_BR_War_Robot_01.fbx` has `Pelvis`, `Thigh_L`, `Foot_L`,
    `UpperArm_L`, `Hand_L` beside `spine_01` and `calf_l`, while the Sidekick
    clips write all of them lower-case. Nine joints differed by case alone --
    hips, legs, feet, arms, hands. Over 800 rigged characters, the share of a
    character's bones its best clip rig names: median 0.91 either way, but
    p10 0.36 exact against 0.56 folded, and 486 of 800 characters above half
    exact against 786 folded.
  - **Two classifiers, one column.** Dart's `rigFamilyFromMarkers` tested a
    marker the importer never reports and ignored six it does; Python's
    tested all twelve. `backfill_rigs.py` wrote the column with one rule and
    Atlas's lazy pass with the other. Graded against which clip rig actually
    names each character's bones: Python right 786 of 800, Dart 480 -- it
    called 303 rigged characters rigless. On 180 probed files they disagreed
    about 49, every one a character mesh.
  - **No `unreal` clips exist.** The library's 796 clips are 359 polygon, 346
    sidekick, 91 unnamed. `rigFamiliesCompatible` required equal family
    names, so "only animations for my character" passed **0 of 796** clips
    for the 348 characters stored `unreal`.
  - **`none` meant two things.** "No skeleton" and "a skeleton we have no
    name for". 91 clips were `none` with real skeletons; the Dogs pack's mesh
    and its 88 clips share one 82-bone rig exactly and were refused each
    other. Of 400 meshes stored `none`, 399 genuinely have zero bones.
- **Options considered:**
  - A. Fold case inside `normalizeBonePath`, so every comparison folds.
    Rejected: it would change the answer of lookups that already succeed, and
    the "do not lose what works" condition was explicit.
  - B. Fold case as a fallback after every exact form has failed. **Chosen.**
  - C. Keep the count guard (`minimumRigOverlap = 4`) as the only match rule.
    Rejected on measurement: folded, a character shares a median 27% of its
    bones with the *wrong* family's rig, which is well over four bones.
  - D. Make Dart's classifier the shared one. Rejected: it is the less correct
    of the two by 306 characters.
  - E. A bone-name signature per rig instead of family names. Deferred to WP5;
    it is the real answer and needs a schema change.
- **Decision and rationale:**
  1. `indexOfBone` keeps its three exact steps unchanged and first, then folds
     case for paths and names. A folded key two differently-spelled bones
     share matches nothing.
  2. `rigMatch` is the only place "may this clip drive this character" is
     decided: the old exact count **or** `minimumRigMatchFraction` (0.5) of
     the character's bones matched folded. At 0.5, 786 of 800 characters match
     their right rig and 6 a wrong one; at 0.4, 786 and 8.
  3. One classifier rule, written down in
     `work/atlas_mcp/fixtures/rig_families.json` and read by both suites --
     the arrangement already used for the search grammar. No bones is `none`;
     a Sidekick attachment or IK bone is `sidekick`, tested first; two or more
     Polygon markers is `polygon`; two or more mannequin markers is `unreal`;
     anything else with bones is `other`. Two markers rather than one because
     Kenney's 58-bone rig shares exactly `Hips` with Polygon and 13 clips were
     labelled from that one name.
  4. `other` is a new `RigFamily`. Two `other` rigs are compatible only when
     they came out of the same container.
  5. `unreal` and `sidekick` drive each other, because the Sidekick rig is the
     Unreal mannequin with bones added.
- **Tradeoffs / risks:**
  - Names matching is necessary, not sufficient. With the legs matched,
    `rigAxisDifference` sees more bones and its median angle can cross
    `maxDirectPoseAngle = 40.0`, which switches a character between posing
    directly and retargeting. **Not yet checked by eye in the built app** --
    the plan's WP3 acceptance check is still open.
  - The container test for `other` is a stopgap standing in for evidence about
    bones. WP5 replaces it.
  - The stored `rig_family` column had to be rewritten for the new rule
    (`backfill_rigs.py --all`), and the chosen character's cached family had
    to be refreshed from the catalog on load.
- **Affected components and source references:** `lib/main.dart`
  (`indexOfBone`, `rigMatch`, `rigBoneMatches`, `rigFamilyFromMarkers`,
  `rigFamiliesCompatible`, `assetPassesRigFilter`,
  `findClipReferenceCharacters`, `AnimationCharacter.refreshRigFrom`),
  `work/atlas_mcp/atlas_mcp.py` (`rig_family_from_markers`,
  `families_compatible`, `tool_find_animations`),
  `work/atlas_mcp/backfill_rigs.py`,
  `work/atlas_mcp/fixtures/rig_families.json`,
  `test/fixtures/rig_bone_names.json`. The importer did not change: it already
  reports all twelve markers and the bone count.
- **Validation and revisit trigger:** both suites read the shared fixture, so a
  case added there fails on whichever language has not caught up; the nine-joint
  War Robot regression is built from bone lists read out of the real files. The
  five skinning and reference suites the plan names pass with one assertion
  changed, which is the one that encoded the old meaning of `none`. Revisit when
  WP5 stores a bone signature per rig: `other`'s container test and the
  `unreal`/`sidekick` special case both become consequences of the bones
  instead of rules of their own.

## FMT-001 — cgltf for GLB and glTF, and no COLLADA reader at all

- **ID / date:** FMT-001 / 2026-11-24
- **Status:** Accepted (user approval, 2026-11-24: "vendor cgltf — yes", "DAE —
  skip")
- **Context and verified evidence:** Atlas drew FBX, OBJ and STL. The library
  also holds 3,035 GLB, 3,045 DAE and 316 glTF. Measured against the catalog:
  every DAE and every glTF has a same-name FBX or OBJ in its own pack, and so
  do 2,843 of the GLB. The files with no other copy are **192 GLB**, all in
  `KayKit Dungeon Pack 1.0`. So reading GLB adds 192 models nobody can see
  today, and reading DAE adds none.
- **Options considered:**
  - A. `cgltf` — one MIT header, no dependencies, vendored in-tree. **Chosen**
    for GLB and glTF.
  - B. Assimp — reads DAE and much else, and would several-fold the importer's
    size and build time. Rejected.
  - C. A hand-written COLLADA subset reader over an XML library. Rejected: it
    would add no model that cannot already be drawn through a twin.
  - D. Nothing. Rejected for GLB because of the 192, accepted for DAE.
- **Decision and rationale:** vendor cgltf 1.15 at
  `windows/runner/third_party/cgltf/cgltf.h`, beside ufbx, and read GLB and
  glTF in `windows/runner/gltf_reader.cpp`, printing the JSON the FBX path
  already prints so the Dart decoder is unchanged. Do not write or vendor a
  COLLADA reader.
- **Tradeoffs / risks:**
  - Version 1 reads node transforms, positions, indices, the first UV set and
    each material's base colour factor and texture. It does not read skins,
    animations, morph targets, cameras or lights, so a GLB reports no rig
    rather than a wrong one.
  - Draco and meshopt compression are refused with a message rather than
    drawn wrong.
  - A `.gltf` keeps its geometry in a separate `.bin`. A loose one on disk
    reads; one inside a zip cannot, because the reader is handed bytes and no
    folder. Those fall back to the twin, which all 316 have.
  - cgltf uses `fopen`, `strcpy` and `strncpy`, which MSVC deprecates and this
    build treats as errors. Suppressed around the vendored header only.
- **Affected components and source references:**
  `windows/runner/gltf_reader.cpp`, `windows/runner/gltf_reader.h`,
  `windows/runner/third_party/cgltf/cgltf.h`, `windows/runner/CMakeLists.txt`,
  `windows/runner/mesh_importer.cpp` (the dispatch), and in `lib/main.dart`
  `previewableModelExts`, `inArchiveModelExts`, `previewKindFor` and `loadMesh`.
- **Validation and revisit trigger:** `test/gltf_reader_test.dart` reads a real
  KayKit GLB through the importer, decodes it, and rasterises it, asserting the
  model covers a visible part of the frame. Revisit DAE only if a DAE arrives
  with no FBX or OBJ twin, which WP7's twin index makes visible.

## TEX-001 — The texture a model gets when it names none comes from the pack's own Unity build

- **ID / date:** TEX-001 / 2026-11-24
- **Status:** Accepted (user approval, 2026-11-24, after he doubted the pack
  shipped the War Robot with no colouring in mind — he was right)
- **Context and verified evidence:** 14% of FBX meshes here name no texture at
  all. `SK_Chr_BR_War_Robot_01.fbx` has one material, `SciFiSpaceBase4`, and
  zero texture references; the material name does not encode the atlas either.
  The pack's Unity build does: prefab → material GUID → `.mat` → `_MainTex`
  GUID → `PolygonSciFiSpace_Texture_01_A.png`, which 42 of the pack's 43
  character prefabs resolve to and 544 of its 662 prefabs overall.
- **Options considered:**
  - A. Rank file names in a textures folder. This was the first draft.
    Rejected as the primary rule: validated against the authored answer over
    seven packs it agreed on five, and one of its misses
    (`PolygonNature_01.png`) was caused by its own "must contain the word
    texture" filter.
  - B. Read the authored chain where it exists, and keep the filename rule as
    a last tier with a dominance guard. **Chosen.**
  - C. Read inside the FBX for a material-name convention. Rejected on
    evidence: the robot's material is `SciFiSpaceBase4` and its atlas is
    `Material_01_A`.
- **Decision and rationale:** four tiers, first answer wins — the model's own
  prefab, the pack's dominant assignment, a filename rule, nothing — and the
  UI says which tier answered, because a guess and an authored answer look
  identical once applied. Both container formats are read: the 10 Unity zips
  through their `.meta` files, and the 83 `.unitypackage` files as sidecars on
  disk, where the GUID is the directory name and `pathname` is the path.
- **Tradeoffs / risks:**
  - A wrong texture is worse than none, because the tagging queue embeds the
    picture Atlas draws. Hence the four preconditions (UVs, no texture named,
    none embedded, none hand-picked), the dominance guards, and "None (flat
    colour)" in the picker.
  - Two guards came out of looking at real packs rather than reasoning: a pack
    default needs half the prefabs that resolve anything **and** a fifth of all
    prefabs **and** at least eight of them. Without the second, Dungeon Realms
    2022 called an FX circle its atlas on the strength of 17 prefabs of 1,529.
  - The newer Synty packs do not use `_MainTex`: the 2022 builds fill
    `_Albedo_Map`, and 56 of that pack's 73 materials reference a texture while
    only 5 do it through `_MainTex`. Five slot names are read in order.
  - Models that drew flat grey and now draw textured have stale embeddings.
    Re-embedding needs a `--force` flag that does not exist, and a run that is
    held.
- **Affected components and source references:** `lib/main.dart` --
  `findInferredTexture`, `readUnityTextureChain`, `guessTextureByName`,
  `meshWantsInferredTexture`, `unityPackageSidecarsFor`, `loadMesh`,
  `TexturePickerButton`, `materialSummaryLine`; the dead
  `findModelFallbackTexture` was deleted with it.
- **Validation and revisit trigger:** `test/inferred_texture_test.dart`, with a
  hand-built Unity zip fixture and corpus-gated tests that resolve the real War
  Robot through tier 1 and a PolygonTown model through the `.unitypackage`
  sidecar. Revisit when a pack is found whose authored answer the reader gets
  wrong -- the survey script in the plan's appendix prints the list.

## LIST-001 — One row per model, not one per file (Accepted, 2026-11-25)

- **Context:** `war_robot_01` is seven files in this library: the source FBX in
  `POLYGON_SciFiSpace_SourceFiles.zip` and six `.uasset` builds for Unreal 4.19
  through 5.4. Searching for it gave seven rows of the same robot, and the
  count beside the list counted files.
- **Decision and rationale:** collapse by [twinKeyFor] -- the product key of
  the container plus the file stem -- which is the key WP7 already uses for
  "same model", so one rule serves pairing and the list. Mike chose the
  strongest of the three groupings offered (same pack and same name, across
  formats and engine versions) and chose it on by default. The row shown is
  the one that can be drawn, so the row with a picture represents the group.
- **Tradeoffs / risks:**
  - Collapsing happens after filtering, never before: a filter still sees every
    file, so "characters with no texture" still means the files.
  - The badge counts the rows the list would have shown without collapsing,
    not every copy in the catalog, so turning the switch off accounts for
    exactly what the badge claimed.
  - With the collapse on, ticking a row and copying copies the one file shown
    rather than all seven. The switch is the way to the other behaviour.
  - The key never reaches across packs, so two `pipe_end` files in different
    kits stay two rows -- the weaker "possibly the same model" tier in
    `TwinIndex` is deliberately not used here.
- **Affected components and source references:** `lib/main.dart` --
  `collapseAssetVersions`, `CollapsedAssets`, `VersionCountBadge`,
  `AssetItem.twinKey`, `_assetsMatching`, `collapseVersionsKey`, `AssetList`,
  `AssetGrid`.
- **Validation and revisit trigger:** `test/collapse_versions_test.dart`, nine
  tests over the real war-robot shape. Over the whole catalog: 480,826 files in
  360,814 rows, 29,930 standing for more than one. Revisit if a pack is found
  whose builds differ in content rather than only in engine version, where one
  row would hide a real difference.

## PERF-001 — No per-asset pattern construction, and the sort keys computed once (Accepted, 2026-11-25)

- **Context:** the window froze for 30-60 s on selecting a `.uasset` and then
  switching the type filter. Measured against the real catalog:
  `twinIndexFor` 4,706 ms, `findInferredTexture` 4,204 ms, `sortAssets`
  6,726 ms, a filter pass 627 ms -- all on the UI thread.
- **Decision and rationale:** three rules, each from a measurement.
  1. A `RegExp` is never constructed inside a function that runs per asset.
     `twinProductKey`, `_packNameWords` and `containerDisplayName` each did,
     and the last also searched for a path separator with
     `lastIndexOf(RegExp)`, which walks the string from the front for every
     position it tries: 2.6 s of the 4.3 s those two index builds spent. The
     patterns are hoisted and the separator search is a backwards scan over
     code units (`lastPathSeparator`).
  2. A key derived from a container name is memoised per container name:
     a few hundred names against 480,826 assets.
  3. Sort keys are computed before the sort, not inside the comparator, and
     the lower-cased path is held on the asset.
- **Tradeoffs / risks:**
  - `_twinProductKeyCache` and `AssetItem.sortPathKey`/`twinKey` are caches
    with no invalidation, which is correct only because nothing they read
    changes while Atlas is open. A rescan replaces the `AssetItem`s.
  - The sorted list no longer carries `_listEpoch` except in `type` mode. If a
    future sort mode reads something a classification fills in, it must be
    added to that condition or the order will go stale.
- **Affected components and source references:** `lib/main.dart` --
  `sortAssets`, `_SortKey`, `sortedAssets`, `lastPathSeparator`,
  `twinProductKey`, `_versionRunPattern`, `_twinProductKeyCache`,
  `containerDisplayName`, `_textureIndexOf`.
- **Validation and revisit trigger:**
  `test/select_and_switch_cost_test.dart` (benchmark, needs `ATLAS_BENCH=1`
  and a catalog copy) measures each stage; after this, 728 / 1,562 / 1,734 /
  423 ms. Revisit when any single stage there passes a second again.

## PERF-002 — The UI isolate never waits on a subprocess pipe (Accepted, 2026-11-25)

- **Context:** selecting a model left the window pegged on one core and the
  model never appeared. Measured on the running app (1.10.51, pid 118440):
  the importer child was alive for 12 minutes having used 0.25 s of CPU --
  blocked, not working -- while the window's own thread took 557 CPU-seconds.
  The same file, same binary, with its stdout drained, imports in **0.31 s**
  and prints **5,306,239 bytes** of JSON. Five `/health` calls on the bridge
  took 6,637 / 3,967 / 3,297 / 3,705 / 7,480 ms, which is the gap between
  turns of the event loop.
- **Decision and rationale:** the drain for a full import runs on a worker
  isolate (`runMeshImporterOffThread`, `Isolate.run`). A Windows pipe holds
  about 64 KB, so an asynchronous drain on the UI isolate needs one turn of
  the event loop per buffer: measured at **more than 60 turns** for this one
  model. Multiply by a turn that takes seconds and a 0.31 s import becomes
  minutes. Nothing about how busy the window is can stall a worker's pipe.
  The bytes are also collected as whole reads (`BytesBuilder`) rather than
  through `expand`, which turned each 64 KB read into 64 thousand stream
  events.
- **Tradeoffs / risks:**
  - One isolate per import. It is tens of milliseconds against a subprocess
    and a parse, and the classification queue has done this since it existed.
  - Probes stay on the caller's isolate: they print tens of bytes, one buffer
    holds that, and they already run inside a classify isolate.
  - `jsonDecode` of the result is still synchronous on the UI isolate -- one
    block of a few hundred milliseconds for a large model, counted as
    `importer json` by the watchdog (OBS-001). Moving it would mean sending a
    decoded map between isolates, which is its own copy.
- **Affected components and source references:** `lib/main.dart` --
  `runMeshImporter`, `runMeshImporterOffThread`, `importFbxWithUfbx`.
- **Validation and revisit trigger:**
  `test/importer_off_thread_test.dart` blocks the calling isolate in 200 ms
  slices and counts the turns the import needs: 60+ before (the test's cap),
  under 10 after. Corpus-gated. Revisit if a model load is ever reported slow
  again while the window is responsive -- that would be a different cause.

## PERF-003 — One pose per clip frame, not one per display frame (Accepted, 2026-11-25)

- **Context:** the animation player's ticker called `setState` on every vsync.
  Each rebuild skins every vertex of the character (`poseSkinnedPositions`)
  and rasterises the whole pane, both on the UI isolate -- animated frames
  deliberately bypass the render worker, because the geometry changes every
  frame and there is no stable scene for the worker to hold.
- **Decision and rationale:** the ticker advances its clock always and
  rebuilds only when the clip's frame index changes. A 30 fps clip on a 60 Hz
  display was paying for every frame twice; on a 144 Hz display, nearly five
  times. Redrawing the same frame cannot change a pixel, so nothing is lost.
- **Tradeoffs / risks:** `_elapsed` is now assigned outside `setState` on the
  ticks that change nothing. That is only correct while the frame index is the
  only thing on screen derived from it -- a readout of elapsed seconds would
  have to move inside the guard.
- **Affected components and source references:** `lib/main.dart` --
  `animationFrameAt`, `_SkeletonPlayerState._frameAt`, its ticker.
- **Validation and revisit trigger:**
  `test/animation_frame_rate_test.dart`, including the count of ticks in one
  second of 144 Hz that change the frame (30 of 144). Revisit by moving
  animated rasterising to the render worker -- send the posed positions, not
  the geometry -- which is the real fix for playback cost and is not done.

## OBS-001 — The app names the stage that froze it (Accepted, 2026-11-25)

- **Context:** a 30-60 s stall was diagnosed by measuring stages against a
  copy of the catalog, and a 12-minute one could only be narrowed by
  elimination from outside the process -- thread CPU, child processes, bridge
  latency. Nothing in the app could say what was running.
- **Decision and rationale:** a 250 ms periodic timer on the UI isolate whose
  own lateness is the measurement: a blocked isolate cannot run the reporter
  either, so the lateness of a tick is the block. When a gap passes 750 ms it
  logs the gap and a tally of the stages that ran -- `sort`, `filter`,
  `collapse`, the three index builds, `raster`, `scene flatten`, `skinning`,
  `thumbnail`, `importer json` -- busiest first. One count per call, not per
  asset.
- **Tradeoffs / risks:**
  - It names stages, it does not time them. The line says what ran during a
    block, not which part of it was slow; the benchmark test is still what
    measures a stage.
  - A block in code with no counter in it reports "nothing instrumented ran",
    which is itself the answer: instrument that next.
  - The counters are plain globals, so a worker isolate's own rasterising
    lands in that worker's copy and never in the window's tally.
- **Affected components and source references:** `lib/main.dart` --
  `UiStallWatchdog`, `uiStallReport`, `describeUiStages`, `countUiStage`,
  `uiStageCounts`; started beside the bridge, stopped in `dispose`.
- **Validation and revisit trigger:** `test/ui_stall_watchdog_test.dart` (the
  decision is a pure function; the timer measures real lateness and cannot be
  faked). Revisit if a stall is reported and the log names nothing.

## TAG-002 — The strip reports the store, not this process (Accepted, 2026-11-25)

- **Context:** Mike read "Visual tagging has not been started" in the window
  and concluded the library had never been tagged. It had: 48,137 distinct
  models selected, 48,131 embedded, 0 to do (`tag_assets.py --dry-run`), over
  a store of 138,747 vectors. The strip's idle text meant "no run has
  happened in this process", which is true of every ordinary launch.
- **Decision and rationale:** the idle strip reads one table beside the
  catalog -- `select source, count(*) from embedding_index group by source` --
  and says how many models and textures have vectors. Reading is enough:
  starting the embedder to answer it would load 325 MB of model to print a
  number, and recomputing what is *outstanding* would restate in Dart the
  selection logic that `tagging.py` owns (EMB-001).
- **Tradeoffs / risks:**
  - It reports what is there, not completeness. "48,148 models and 90,599
    textures are tagged" does not claim the library is finished, because
    Atlas cannot know that without Python's selection rules.
  - A store it cannot read falls back to the old sentence. Nothing read and
    nothing tagged are different claims, but the strip has nothing better to
    say and must not invent a number.
- **Affected components and source references:** `lib/main.dart` --
  `TaggedCounts`, `readTaggedCounts`, `VisualTaggingStrip.idleMessage`,
  `_loadTaggedCounts`.
- **Validation and revisit trigger:** `test/tagged_counts_test.dart` (the
  read, including the empty, absent and unreadable cases) and the new group in
  `test/visual_tagging_strip_test.dart`. Revisit if the store grows a third
  `source` that is not a model render.

## PERF-004 — One list refresh per sweep of verdicts, not one per file (Accepted, 2026-11-25)

- **Context:** with the texture filter on anything but `all`, the window
  burned one core continuously -- 557 CPU-seconds when first sampled, 2,754
  fifty minutes later, with no model import in flight for most of it -- and
  turns of its event loop were 3,297-7,480 ms apart. The mechanism is in
  source: the filter pass itself queues every model it has no texture verdict
  for (`_assetsMatching`, the `hasValid == null` branch), and
  `_validateModelTexture` then called `setState` with `_invalidateAssetViews()`
  **per file**. Each of those re-runs both filter passes and both collapses
  over 480,826 assets, about 1.3 s, and in `type` sort mode a 1,734 ms
  re-sort as well. There are about 48,000 models to get verdicts for, and a
  verdict for a non-FBX model is instant -- no subprocess, which is why the
  thread stayed busy with no importer process to show for it. The classify
  queue had already learned this lesson: `_applyModelKinds` folds a chunk of
  400 in at a time, and its comment says why.
- **Decision and rationale:** the verdict lands in `modelHasValidTextures`
  immediately; the redraw it implies goes through `ListRefreshCoalescer`,
  which refreshes once per 1,500 ms burst. The window is deliberately longer
  than a refresh costs, so a sweep cannot spend more of the thread redrawing
  the list than validating files. Nothing about the verdicts changes.
- **Tradeoffs / risks:**
  - A row can take up to 1.5 s to appear or disappear while a sweep runs.
    That is a background sweep over tens of thousands of files; the
    alternative was a window that could not draw at all.
  - The verdict map is now written outside `setState`. Correct because the
    pending refresh is what rebuilds, but a future reader of that map must
    not assume a rebuild has already happened.
  - It caps the refresh rate, not the cost of one refresh. A refresh is still
    1.3 s of UI thread; incremental filtering is the real answer and is not
    done. See the Problems list.
  - Validating a filter over the whole library still means importing every
    FBX model in it, three at a time. That is inherent to the filter, and
    since PERF-002 it is off the UI isolate.
- **Affected components and source references:** `lib/main.dart` --
  `ListRefreshCoalescer`, `listRefreshWindowMs`, `_listRefresh`,
  `_validateModelTexture`, `_processModelValidationQueue`.
- **Validation and revisit trigger:**
  `test/list_refresh_coalescer_test.dart` (5 tests, on the fake clock):
  50 verdicts in a burst cost one refresh, 50 over five seconds cost at most
  ten, a verdict after a quiet spell still redraws, and cancelling drops the
  pending one. Revisit when `UiStallWatchdog` reports a block whose tally is
  dominated by `filter` and `collapse` again.
