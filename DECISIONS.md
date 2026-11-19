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

