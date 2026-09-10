# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Shape

This git repository is rooted at `woul/` (the parent `2026-07-08/` folder is not a repo). The only active code is the Flutter Windows desktop app **AssetAtlas** at `work/asset_atlas_native/`. Run all Flutter/Dart commands from that directory.

- `work/asset_atlas_native/` — the app (all Dart code lives in a single `lib/main.dart`, ~4.7k lines)
- `work/ROADMAP.md`, `work/AI_HANDOFF_LATEST.md` — plan and session handoff; the handoff is the intended first read each session and is expected to be updated at the end of a work session (git status/log snapshot, next steps, files touched, validation run)
- `docs/TECH_SPEC_*.md` — architecture, rendering/FBX, build/release specs
- `USER_MANUAL.md` — end-user behavior reference; useful for confirming intended UX before changing it
- `work/asset-atlas/`, `work/asset-atlas-desktop/` — dead web/Electron prototypes, removed from git history; ignore them
- `outputs/` — staged build artifacts

## Commands

From `work/asset_atlas_native/`:

```bash
flutter pub get
flutter run -d windows
flutter analyze
flutter test
```

Run a single test file or a single test by name:

```bash
flutter test test/scan_fixture_test.dart
```

```bash
flutter test --plain-name "FBX importer JSON pipeline decodes UVs and texture image"
```

`flutter analyze` + `flutter test` is the standing validation gate before any commit or handoff update.

Packaging, installer, and version bump (PowerShell, from `work/asset_atlas_native/`):

```bash
pwsh -File .\scripts\package_windows.ps1
```

```bash
pwsh -File .\scripts\create_windows_installer.ps1
```

```bash
pwsh -File .\scripts\bump_version.ps1
```

`bump_version.ps1` rewrites **both** `pubspec.yaml` `version:` and the `const appVersion` literal in `lib/main.dart`, and throws if either pattern is missing — do not edit those by hand or reformat those lines. Repo convention is to bump the version whenever code changes. `create_windows_installer.ps1` needs Inno Setup 6 (`ISCC.exe`); output lands in `dist/installers/`.

## Architecture

### Two-process FBX pipeline

FBX is never parsed in Dart. `windows/runner/mesh_importer.cpp` builds a **second executable**, `asset_atlas_mesh_importer.exe`, from the vendored `ufbx` (`windows/runner/third_party/ufbx/`). It is a separate `add_executable` target in `windows/runner/CMakeLists.txt` and is installed next to the app binary by `windows/CMakeLists.txt`. Dart shells out to it and consumes JSON on stdout:

- `asset_atlas_mesh_importer <model.fbx>` — parse from disk
- `asset_atlas_mesh_importer --stdin <label>` — parse bytes piped on stdin (this is how FBX entries inside ZIP archives are previewed without extracting)

`meshImporterPath()` in `lib/main.dart` looks for the helper as a sibling of the running executable first, then falls back to `build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe` — that fallback exists because `flutter test` runs under the SDK's `flutter_tester.exe`. Consequence: **`test/native_fbx_importer_test.dart` self-skips unless a Windows Release build exists.** Build Windows before trusting a green native test run.

Changes to the JSON contract must be made on both sides at once: the emitter in `mesh_importer.cpp` and `meshModelFromImporterJson()` in `lib/main.dart`. Fields include `vertices`, `faces` (indices + material index + inline UVs), `uvSets` (named, per-face), `materials`, `textureFiles`, `sceneTextures`, `vertexColors`.

### Rendering

Software rendering only. **Filled modes go through `rasterizeMesh`**, a depth-buffered rasteriser producing an RGBA buffer that `RasterModelView` shows; `MeshPainter` (canvas, per-face depth sort) is now used only for wireframe. Per-face sorting could not resolve interpenetrating or coplanar faces, which showed up as notches and slivers on low-poly models — `test/raster_depth_test.dart` pins the difference. The rasteriser is pure, so it runs on the UI isolate at half resolution while the camera moves and on a worker isolate (`rasterizeSceneInIsolate`) for the sharp frame once it settles. That needs the mesh flattened into typed arrays first: `RasterScene.fromMesh` does it, and `RasterModelView` caches one scene per mesh rather than rebuilding it per frame. Faces beyond `maxRenderedFaces` are capped by depth priority and the overlay says so; backface culling is user-toggleable and its sign convention is pinned by `test/renderer_geometry_test.dart`. FBX imports go through `MeshLoadCache`, not `loadMesh` directly, so the preview and the diagnostics panel share one importer run. `RenderMode` is textured/solid/wireframe; `LightingMode` is corner/top/unlit. Texturing is perspective-correct across a triangle. Three channels are now sampled per pixel — base colour, normal map (tangent frame from position/UV derivatives), and emissive map (added, so an emissive surface does not go dark where the light misses it) — plus a Blinn-Phong specular lobe driven by `specularFactor` and `roughness`; the camera and light are both fixed, so the half vector is constant per face. Specular is skipped in `LightingMode.unlit`. Each channel — base texture, normal map, emissive, specular — has its own switch on `RasterRequest` and its own toggle in the preview toolbar (`ShadingChannelPanel`), shown only when the model carries that channel; the switches are part of `RasterModelView`'s frame cache key. The remaining channels (metalness, the flat emissive colour) are still approximate colour modifiers in `faceDiffuse`, not a PBR model. Don't push further toward engine parity without an explicit ask — see `docs/TECH_SPEC_RENDERING_FBX.md` non-goals. `test/raster_shading_test.dart` pins the emissive and specular behaviour; a specular test needs a face whose normal sits on the half vector, because a tight lobe misses everything else.

**Palette faces.** Synty-style models pin all three UV corners of a face to a
single texel; roughly half the faces of a typical model do this. Such a UV
triangle has no invertible transform, so the per-triangle texture path cannot
draw it — it used to bail out and leave the untextured base colour showing,
which made half of every model render flat white. `isDegenerateUvTriangle`
detects them and the painter fills them with the sampled texel instead
(`MeshMaterial.sampleTexture`, which needs the CPU-side `texturePixels`
readback). Runs of these are batched into one `drawVertices` call, which also
removes the antialiasing seams that per-face `drawPath` left between triangles.
If a model renders as flat untextured colour, check this path first.

Texture resolution order: absolute path → relative to model dir → deterministic relink within the model's own container → deterministic relink *across* containers → fallback lookup → checker fallback. The cross-container pass is deliberately strict (`canRelinkAcrossContainers`): the basename must match exactly and the reference must name the other pack, which `texturePackHints` extracts while ignoring generic folder names (textures, materials, sourcefiles, …). Without both, a name like `Wall_01.png` would bind to whichever pack was scanned first.

Within one container the scoring also falls back to shared *words*: `stripTextureNameNoise` removes an exporter prefix (`T_`, `TX_`), a duplicate-copy suffix (` 1`, ` (2)`, `_copy` — never a bare trailing `_01`, which is part of the name), and `textureNameTokens` drops single characters and the word "texture". A shared distinctive word scores; a shared number alone deliberately does not, or every `_01` in a pack would match. This is what connects `PolygonApocalypse_Texture_01_A 1.png` to the `T_PolygonApocalypse_01.png` its own archive ships.

A material that named textures and resolved none is reported as such (`MeshMaterial.texturesMissing`, `materialSummaryLine`) rather than as "flat colour" — the two look identical on screen and mean opposite things. When nothing resolves at all, `TexturePickerButton` lets the user apply any scanned nearby texture by hand; `applyChosenTexture` puts it on every material and is deliberately *not* cached, since it is the user's choice rather than anything the file said.

**Vertex colours.** They multiply the shaded surface, so a set that is entirely black — or entirely transparent — renders the whole mesh black however well its textures resolved. That is what an exporter writes for a colour layer nothing filled in: `PolygonSyntyCharacter.fbx` ships 14,688 vertex colours of `(0,0,0,0)`. `vertexColorSetIsUnusable` discards such a set at import. Deliberately all-or-nothing — black *parts* of a model are real art.

**OBJ.** `parseObjMesh` keeps `vt` (flipping V — OBJ counts up, the sampler counts down), the `v/vt/vn` corner references, `usemtl` (which splits faces between materials) and `mtllib`. It used to keep none of that, so an OBJ could never be textured whatever else resolved. A corner with no texture coordinate makes the whole triangle untextured rather than half-textured. OBJ is in `_previewableModelExts`, so it reaches the texture discovery panel too.

### Animation

An FBX with a skeleton and no geometry is `FbxContentKind.animation`. The importer emits a `skeleton` object alongside the counts: the bone hierarchy once (`name` + `parent`, resolved to an index, `-1` for a root) and then the **world position of every bone at each sampled frame**, at 30fps capped to 120 frames. Positions rather than transforms because that is all a stick-figure preview draws; `ufbx_evaluate_scene` composes the hierarchy, so no curve evaluation or parent composition happens in Dart. `SkeletonAnimation.fromJson` reads it, `SkeletonPlayer` plays it, `SkeletonPainter` draws a line from each bone to its parent. Bounds come from the whole clip, not the current frame, or the figure breathes as it plays.

A frame is `bones * 12` floats — a column-major 3x4 world matrix per bone, whose last column is the position. Positions alone were enough for the stick figure but skinning needs the rotation.

**Skinning.** A skinned mesh also emits a `skin` object (bone names, a `bindInverse` 3x4 per bone, four `(bone, weight)` pairs per skinned vertex, and a per-emitted-vertex index into that table) plus its own rest pose as a one-frame `skeleton`. `bindInverse` is `geometry_to_bone` composed with the inverse of the mesh's `geometry_to_world`, because the emitted vertices are already in world space — without that second term a posed character lands in the wrong place. `poseSkinnedVertices` blends `clipBoneWorld * bindInverse` per vertex.

The join between a clip and a character is the **bone name**: the Synty rig is `Root / Hips / Spine_01..03 / Clavicle_L,R / Hand_L,R / IndexFinger_01..04 / Thumb_01..` and the character files use the same names, so no mapping table is needed. A bone the clip lacks contributes nothing and the vertex keeps its bind position rather than collapsing to the origin.

**The framing transform is part of the skin contract.** The importer recentres and rescales every mesh into a unit box so the viewer can frame it (`normalizeCenter` / `normalizeScale`), and that happens *after* the bind matrices are built. The importer folds the inverse into `bindInverse`, and the consumer must apply the forward transform again after blending. Skipping it leaves a character's mesh 0.89m from its own skeleton, which tears it apart — and it looks exactly like a bad rig, so it was blamed on retargeting for a long time. `test/skinning_test.dart` pins it.

Two checks that matter, in order:
1. **Identity test** — posing a character with its own rest skeleton must reproduce its vertices (7e-6 here). This validates the matrix conventions and units.
2. **Extent test** — a posed character must be the same height as its bind pose. The identity test passes even when the framing transform is missing; only the extent test catches that. If a posed character is *taller* than its bind, suspect the framing, not the rig.

**Bone matching** is by path from the root, normalised through `normalizeBonePath`. These rigs give both hands the same bone names (`IndexFinger_01` under `Hand_L` and `Hand_R`) and ufbx renames whichever it meets second to `IndexFinger_01_1` — and node order differs between files, so one file's `Hand_R/IndexFinger_01_1` is another's `Hand_R/IndexFinger_01`. Only a single trailing digit is stripped, so Synty's own two-digit numbering (`Spine_01`) survives. Matching on the bare name silently binds a right hand to a left one, so it remains only as a last resort.

**Retargeting.** Two Synty rigs can share every bone name, parent and path and still be incompatible: the newer character packs re-oriented the joint axes, so `Hand_L` points 169 degrees away from where the animation rig puts it. `rigAxisDifference` measures the median; the older character rig sits at ~19 degrees and poses directly, the newer at ~89 and tears apart. Above `maxDirectPoseAngle` (40) the clip's transforms are not applied directly — `RetargetPlan` takes two things from the clip and nothing else. **Orientation**, in world space: `characterWorldRotation(t) = clipWorldRotation(t) * transpose(referenceWorldRotation) * characterBindWorldRotation`. World space is the one frame two rigs with different joint axes agree on. **Displacement**, as a delta: `clipLocalTranslation(t) - referenceLocalTranslation`, carried into the character's parent frame and added to the character's own bind offset, scaled by the height ratio. For every bone but the hips that delta is zero, so the character keeps its own bone lengths exactly.

**Never compose a clip's local transforms onto another rig.** The obvious formulation — `characterLocal(t) = clipLocal(t) * inverse(referenceLocal) * characterBindLocal` — looks right and is not: a bone's local translation then becomes `clipRotation * inverse(referenceRotation) * (bindOffset - referenceOffset) + clipOffset`, which is the character's bone length only when the clip is not rotating that bone. `SM_Chr_Captain_Male_01` came out with one shoulder at 0.53x its length and fingers at 1.48x, while its overall height stayed within 1% — which is why the height check missed it for so long. It was invisible in testing because the *reference* character poses perfectly under that formula: when character and reference are the same rig the correction collapses to the identity. Any other character is mangled. `test/skinning_test.dart` pins the synthetic case (a turning parent must not change a child's bone length) and `test/corpus_skinning_test.dart` measures every bone of a real character.

The reference pose matters and is easy to get wrong. A clip's *own* rest is wherever the animator left the rig — for a locomotion pack, a standing idle — so using it makes the correction cancel and the character stays in its bind: safe, never mangled, but never posed either. What is needed is the clip rig in the same *physical* pose the character is bound in, i.e. both T-posed. Animation packs ship a character on their own rig for this, so `findClipReferenceCharacters` looks for one in the same container as the clip and the caller measures each against the clip by bone overlap. No reference found means the character shows its bind pose and the UI says so.

### The skeletons

Three rigs appear across this library, and they are told apart by their bones — never by a file name, a folder name, or a filename prefix.

| Family | Root chain | Bones | Case | Marker bones | Where it shows up |
| --- | --- | --- | --- | --- | --- |
| `polygon` | `Root / Hips / Spine_01 / UpperLeg_R` | 50 on a character, 52 on a clip | Capitalised | `Hips`, `UpperLeg_R`, `Clavicle_L`, `Spine_01` | Synty's own rig. Most character packs, and the `Animations/Polygon` clips. |
| `sidekick` | `root / pelvis / spine_01 / thigh_l`, plus attachment and IK bones | 88 on a character, 121 on a clip | lowercase | `hipAttachFront`, `hipAttach_l`, `ik_hand_gun`, `ik_hand_root` | Synty's Sidekick characters and the `Animations/Sidekick` clips. |
| `unreal` | `root / pelvis / spine_01 / thigh_l` | mannequin | lowercase | `pelvis`, `thigh_l`, `clavicle_l`, `spine_01` | The plain Unreal mannequin. Supported, but see below. |
| `none` | — | 0 | — | — | Props, collision hulls, anything with no skeleton. |

**No file in this library actually classifies as `unreal`.** The Unreal builds of these packs ship `.uasset` and `.umap` only — zero FBX across every `*Unreal*.zip` checked — and the app indexes neither, so those archives contribute no models at all. The family exists so that a plain mannequin is not mistaken for Sidekick if one ever turns up; it is not exercised by anything here. (`Unreal_PolygonPirates` is 636 `.uasset` and 2 `.umap`. Those now index as type `unreal` with their own sidebar filter and icon -- listed so a pack that ships nothing else is not mistaken for an empty folder -- but they carry no geometry anything here can read, so they are never previewed.)

Two things make this harder than it looks:

- **Sidekick is a superset of Unreal.** It carries every mannequin bone plus attachment and IK bones, so testing for the mannequin first swallows it. `rigFamilyFromMarkers` checks Sidekick first, and the order is load-bearing.
- **Polygon and Unreal differ only in case.** Both have a `spine_01`/`Spine_01`. The importer's marker comparison is exact and case-sensitive for exactly this reason.

Polygon and Sidekick share **no bone names at all**, so a clip from one cannot drive a character from the other. `rigBoneOverlap` is what tells them apart, and `rigAxisDifference` returns `double.infinity` below `minimumRigOverlap` shared bones — returning 0 there made an unrelated rig look like a flawless reference and win the selection, which is why a reference is chosen by overlap rather than by angle.

Same family does not mean same joint orientation. `SM_Chr_Captain_Male_01` and `PolygonSyntyCharacter` are both `polygon`, share all 50 bones and have identical bone lengths, and still sit 90 degrees apart: the Captain's bone axes are the reference's cycled x→y→z. Family decides *whether* a clip can drive a character; `rigAxisDifference` decides whether it needs retargeting to do it.

### Attachments

Every character pack ships kit -- helmets, beards, hair, capes, pauldrons -- and the files say nothing about where any of it goes. An attachment FBX is a bare mesh with no skeleton, no socket and no metadata; `SM_Chr_Attach_Helmet_01.fbx` is 524 triangles sitting at the origin. So this is the one rig question that *is* answered by the name, and the guessing is gathered in a single table, `attachPoints`, rather than spread through the code pretending to be inference.

Each entry maps a set of words to a bone per rig family. Sidekick names its own sockets and so answers outright -- `headAttach`, `faceAttach`, `backAttach`, `shoulderAttach_l/r`, `elbowAttach_l/r`, `kneeAttach_l/r`, `hipAttachFront/Back/_l/_r`, `prop_l/r`. Polygon has none of those, so the anatomical bone is used instead (`Head`, `Jaw`, `Spine_03`, `Hand_R`). The first bone in the list that the character actually has wins, and a rig with none of them wears nothing rather than wearing it in the wrong place.

**Match whole words, never substrings.** `cape` contains `cap`, which sent every cloak in the library onto a head; `prop` is the name of a bone and also the name of half of every pack's scenery, so as a filename keyword it claimed every `SM_Prop_*` barrel and crate. Names here are underscore-separated, so splitting on punctuation recovers the words the artist wrote. A trailing number is stripped as well, so `Helmet01` still reads as a helmet. Both bugs were caught by the tests in `test/attachment_test.dart` rather than by reading the table, which is the argument for having the table.

**Placement is not guesswork.** The artist builds a helmet at the head joint's origin at the character's own scale -- confirmed by `ASSET_ATLAS_DEBUG_SPACES=1`, which shows the helmet's raw mesh at y -0.063..0.268 rather than at head height. So three steps put it back: undo the attachment's framing to recover the coordinates it was authored in, carry those through the bone's rest transform, and apply the character's framing so it lands in the same box the character is drawn in. Nothing is scaled to fit. `attachToCharacter` returns null rather than placing a piece badly when a step is missing.

That needed the importer to emit `framingCenter` / `framingScale` for **every** mesh, not just skinned ones. The values were already there for skinned meshes, carried on the `skin` object, because posing needs them; a helmet has no skin to carry them on, and without them its size and origin are gone for good. `framingOf` prefers the direct field so a character and its hat are read the same way.

Attachments are found by `findAttachmentCandidates`: models in the character's own container, not already known to have a rig of their own (that is another character, not a hat), whose folder or name says `attach` or whose name contains a word from the table.

**Stacked-variant files.** Some packs ship a character sheet rather than a character. `Characters.fbx` in Dungeon Realms holds eleven whole bodies standing in the same place, one material each; `SimplePeople3.fbx` does the same with twelve. Drawn together they interpenetrate and read as z-fighting. `materialsAreStackedVariants` detects it spatially rather than by name -- a material covering the model's full width *and* height is not a part of it, it is another copy of it, and three or more such materials is a stack -- and the variant grid opens in per-material mode for those files. Parts fail the test, so an ordinary multi-material model is left alone.

**The variant grid has two modes** because there are two questions. By texture: one cell per palette swap of the atlas a material asks for, which is what a Synty character needs since it has one material and several colourways. By material: one cell per material, for the stacked files. A model with both gets a switch and starts on textures unless it is a stack.

### Nothing here reads a name

Every rig question is answered from file contents — with the single, declared exception of an attachment's attach point above, which no file records at all. This is not fastidiousness — the naming conventions in this library actively lie:

- `SK_` is Unreal's *skeletal mesh* prefix, and Synty puts it on Polygon-rigged characters. It does not mean Sidekick.
- `SM_` is Unreal's *static mesh* prefix, and `SM_Chr_Captain_Male_01.fbx` is fully skinned.
- Sidekick characters are also `SK_*`, so the prefix separates nothing.
- A pack's `Characters/` folder holds attachments too, and its clips can sit under `Export/Polygon/` or `Animations/Polygon/` depending on the pack's vintage.

So the inputs are:

| Question | Answered by | From |
| --- | --- | --- |
| Does this file have geometry or is it a clip? | `modelKind` (`mesh` / `animation`) | importer `--probe` |
| Which skeleton is it on? | `rigFamily` | marker bones, `--probe` |
| Which skeleton is a *loaded* clip on? | `rigFamilyOfSkeleton` | the bone names already in memory |
| Is it a character rather than a prop? | `assetIsCharacterModel` | `rigFamily != none` |
| Can this clip drive this character? | `rigFamiliesCompatible`, `rigBoneOverlap` | bone names on both sides |
| Does it need retargeting? | `rigAxisDifference` vs `maxDirectPoseAngle` | bind and rest matrices |
| Which container is it in? | `assetContainerKey` | the zip path, or the pack folder under a source root |

The one exception is `assetContainerKey`, which is *about* location by definition: two files are in the same container when they came from the same zip, or the same top-level folder under a scanned source root. That is a fact about where a file lives, not a claim about what it is.

`findClipReferenceCharacters` used to require `/character` in the path, which is a habit of two packs rather than a fact about files. It now scopes by container and filters by `modelKind` and `rigFamily`, both permissive when unknown — a file nothing has probed is offered rather than hidden. On a cold catalog a known rigged character shuts out the unprobed files entirely; without that, an animation pack's seven hundred unclassified clips would fill the candidate list before the alphabet reached its two characters. The caller then rejects anything that imports without skin, because a clip would otherwise score a perfect bone overlap and win with a rest pose that is just an idle. `test/rig_reference_test.dart` pins all of it.

**How classification runs.** `--probe` walks the FBX node graph and reports which of `kRigMarkerBones` (in `mesh_importer.cpp`) it saw; `rigFamilyFromMarkers` turns that list into a family. Adding a rig means adding its marker bones there and a case to that function — those two lists are the whole rule set. The answer rides home from the classification isolate encoded by `FbxClassification` (`kind#rig` in one string) and lands in the `rig_family` column.

Classification is lazy and persisted, which has bitten once: the scheduler skipped any FBX that already had a `modelKind`, so files classified before the `rig_family` column existed kept a kind, never got a rig, and were invisible to the character filter forever. It now probes when *either* fact is missing.

`assetPassesRigFilter` drives the sidebar's skeleton filter, including "works with my character", which keeps only files sharing the chosen animation character's family. A file nothing has probed yet is never hidden — that would assert something the catalog does not know.

Each FBX also records its authoring path in `Original|FileName` (`U:\Synty\Animation\BaseLocomotion\...\Export\Polygon\...` for a clip, `E:\Individual_Characters\...` for a newer character). It is a useful forensic hint about which pipeline a file came from, but it is not used for matching — measuring the rigs is more reliable than parsing someone else's folder names.

There is no standalone skeleton asset in these packs. Every `SK_Chr_*.fbx` (1,551 of them across the library) embeds its own copy of the rig and its own skin weights, so a character is matched to a clip directly with no shared avatar in between.

Diagnostics: set `ASSET_ATLAS_DEBUG_SPACES=1` and the importer prints each mesh's raw extent and geometry-to-world on stderr. That is what finally showed the mesh standing at y 0..1.79 while the emitted vertices sat at ±0.88.

`AnimationCharacter` (settings key `animation.character.path`, schema v6 `settings` table) holds the model clips play on; `AnimationCharacterButton` sets it, and only appears for a mesh that actually has skin weights.

### Catalog and persistence

`AssetAtlasDatabase` is a singleton over `sqflite_common_ffi`, DB file in the app support dir (or `initialize(databasePath:)` in tests), schema `version: 7` with tables `catalog_assets`, `catalog_sources`, `projects`, `project_assets`. `onUpgrade` exists and is tested — add a migration step there and mirror any DDL in `onCreate`, since `test/database_test.dart` asserts the two paths converge. Asset ids come from `buildAssetId()` (source root + relative path, content-independent); never build one inline.

Assets inside `.zip` archives are indexed as virtual paths shaped `zip:<container>::<entry>`. Any code that touches a path must handle this: `isZipVirtualPath()` gates reads through `readZipVirtualAssetBytesByPath()` and an LRU-ish archive cache. ZIP entries are searchable, previewable (images, audio, OBJ and FBX), and copyable — the copy flow writes them out under their archive-relative path. Introspection is capped by `maxZipIntrospectionBytes` / `maxZipEntriesToInspect`.

Type classification is driven by the top-level `const` sets in `lib/main.dart` (`imageExts`, `textureExts`, `audioExts`, `modelExts`, `archiveExts`, `unrealExts`) and `ignoredFolderNames` (`.git`, `.vs`, `Intermediate`, `Saved`, …). These are the authoritative rule set — changing them changes fixture test expectations in `test/fixtures/expected_results.json`.

### Known structural constraints

`lib/main.dart` is a deliberate monolith: UI widgets, scanning, ZIP handling, mesh import, renderer, and the database layer all live there. Prefer adding to the existing structure over speculative refactors unless the task is the refactor.

Two things now run on worker isolates, and both follow the same rule: **the
entry point and the launcher must be top-level**. A closure built inside a
`State` method captures `this`, drags the widget tree into the isolate message,
and fails with "object is unsendable" — see `runFbxClassifyChunk` and
`scanWorkerEntry`. Folder scanning goes through `startFolderScan`, which
returns a `ScanHandle` carrying progress and `cancel()`; FBX classification
goes through `buildFbxClassifyChunks` + `runFbxClassifyChunk`. Model previews
and thumbnails still import on the UI isolate, cached by `MeshLoadCache`.

## Testing

Tests are fixture-driven, under `test/`:

- `scan_fixture_test.dart` — scan counts/classification against `test/fixtures/corpus` and `expected_results.json`
- `copy_fixture_test.dart` — copy flow into temp dirs
- `zip_introspection_test.dart` — ZIP virtual-path indexing
- `fbx_texture_pipeline_test.dart` — importer-JSON → mesh → texture decode, using synthetic JSON (no native helper needed)
- `native_fbx_importer_test.dart` — real `ufbx` helper against `test/fixtures/fbx/transformed_uv_embedded.fbx` (ASCII FBX with embedded PNG, transformed instances, two named UV sets); skips without a Windows build

Tests import app code as `package:asset_atlas_native/main.dart`, so anything they exercise must be a top-level (non-private) declaration in `main.dart`.

## Windows platform gotchas

**Never put a `Tooltip` directly inside `ToggleButtons`.** It corrupts the
Windows accessibility tree (`Failed to update ui::AXTree` on stderr at startup)
and the app then hard-crashes inside `flutter_windows.dll` — exception
`0xC000041D` — the next time the window is resized or maximised. Bisected and
confirmed against this exact combination; `ToggleButtons` alone and
`DropdownButton` alone are both fine, and `IconButton(tooltip: ...)` is safe and
is what the toolbar uses instead.

More generally: AX errors on stderr are not cosmetic here. A clean run prints
none, so treat any `accessibility_bridge.cc` line as a crash waiting for a
resize, and bisect the widget tree until it is silent.

## Diagnostics

FBX pipeline logging is on via `const enableFbxLogs = true` and writes to `work/asset_atlas_native/logs/asset_atlas_fbx.log` — importer launch/exit, JSON field counts, texture relink decisions, mesh/vertex-color summary. Read this log first when a model previews blank or untextured.
