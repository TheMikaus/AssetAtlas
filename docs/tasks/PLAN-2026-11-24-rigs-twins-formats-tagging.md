# PLAN — Rigs, animation lists, twins, formats, tagging speed

**Written 2026-11-24 · against commit `bd8e9a2`, Atlas 1.10.44 · branch `fix/stage-1-correctness`**

One document, nine work packages (WP1–WP9), covering all ten of Mike's requests.
Nothing in this plan has been implemented. No source file was changed to write it.

Every number below was measured on Mike's library on 2026-11-24 unless it says
otherwise. Claims are marked **Verified** (measured or read in the code),
**Inferred** (follows from something verified, not itself checked) or **Unknown**.

Line numbers are for `work/asset_atlas_native/lib/main.dart` at `bd8e9a2` unless a
path is given. They will drift. **The function name is the reliable anchor** —
search for the name, not the line.

---

## 0. Read this first

### 0.1 The request, mapped to work packages

| Mike's item | What he asked | Work package |
|---|---|---|
| 1 | Fix the bone lookup *and* the labels, without losing any match that works today | WP3 + WP4 |
| 2 | Use whichever rig classifier is more correct | WP4 (the Python one — see 0.3) |
| 3 | Should "no rig" split in two? Asked for a suggestion | WP4 (yes — see 0.3) |
| 4 | Search text must not reset when the type filter changes | WP2 |
| 5 | Treat a `.uasset` and its FBX/OBJ as one model; show that on the panel | WP7 |
| 6 | `.uasset` files show the audio player when selected | WP1 |
| 7 | Add the other formats (GLB, glTF, DAE) | WP8 — GLB and glTF; DAE **skipped** on Mike's decision, see 0.3 |
| 8 | Keep model↔animation lists; show and audition them from either side | WP5 |
| 9 | Make tagging faster; how many threads now; offer modes | WP9 |
| 10 | Auto texture does not work on the War Robot | WP6 — he was right, the pack *does* assign one; see 0.3 |

### 0.2 Order of work

Do them in this order. Each one ships on its own (own branch, own version bump).

| Order | WP | What | Size | Depends on |
|---|---|---|---|---|
| 1 | WP1 | `.uasset` must not get the audio player | XS | — |
| 2 | WP2 | Keep the search text across type changes | XS | — |
| 3 | WP3 | Bone lookup: case-folded fallback | M | — |
| 4 | WP4 | One rig classifier, plus an "other rig" family | M | — |
| 5 | WP5 | Rig signatures, model↔animation lists, audition | L | WP3, WP4 |
| 6 | WP7 | Twins: same model in several formats | M–L | WP1 |
| 7 | WP6 | The texture the pack's author assigned (Phase A `.zip`, Phase B `.unitypackage`) | M + M | WP7 (for the product key) |
| 8 | WP8 | GLB / glTF (DAE skipped) | L | WP7 |
| 9 | WP9 | Tagging speed: measure, then modes | M | WP7 helps; **held — see 0.6** |

Sizes: XS ≈ under an hour · S ≈ half a day · M ≈ 1–2 days · L ≈ 3–5 days.

WP6 and WP7 swapped places from the first draft of this plan: WP6 now matches a
model to its pack's Unity build, and WP7's product key is exactly the "same pack,
different zip" test that needs. WP6 can still ship first with a cruder
same-pack-name match if WP7 is delayed.

### 0.3 Decisions already made (do not reopen without new evidence)

**Item 2 — the Python classifier is the more correct one.** Verified on 800 rigged
characters, graded against which clip rig actually names each character's bones:

| Rule | Where | Right |
|---|---|---|
| Python `rig_family_from_markers` | `work/atlas_mcp/atlas_mcp.py:1035` | **786 of 800** |
| Dart `rigFamilyFromMarkers` | `main.dart:7977` | 480 of 800 |

The Dart rule's main error: it calls 303 of those 800 characters "no rig" when they
have 48–57 bones. So WP4 makes the Dart rule match the Python rule, not the reverse.

**Item 3 — suggestion: yes, split it, into three values not two.**

- `none` — the file has **zero bones**. A prop. Never animatable.
- `other` — the file **has bones**, but they are not Polygon, Sidekick or Unreal
  names. A real rig Atlas has no name for (the Dogs pack, Kenney characters).
- (unchanged) `polygon`, `sidekick`, `unreal`.

Why: today `none` means both things and the code treats both as "prop". Verified
consequences: 91 of the 796 animation clips are `none` and every one has a real
skeleton; the Dogs pack's 88 clips and its dog mesh share one 82-bone rig exactly,
and Atlas refuses to pair them. For meshes the split costs nothing: of 400 meshes
stored as `none`, 399 genuinely have zero bones.

**Item 1 — "both, if it doesn't cause us to no longer match the ones we do."**
Honoured by construction: WP3 only adds a *fallback* that runs after every lookup
that exists today has failed, so any bone that is found today is found the same
way and at the same index tomorrow. The existing skinning tests must pass
**unedited** — that is the proof.

**Item 10 — Mike's doubt was correct, and it changed the design.** He said he
doubted Synty shipped the War Robot with no colouring in mind. They did not: the
pack's own Unity build assigns it `PolygonSciFiSpace_Texture_01_A.png`, through a
prefab → material → texture chain that is in the library and readable (Verified —
the full chain is in WP6, the file formats in Appendix B). The first draft of this
plan proposed guessing from file names. WP6 now **reads the authored answer where
it exists** and keeps a filename rule only as the last tier, with a dominance
guard so it declines rather than guesses on packs with no single base atlas. The
validation that turned this from opinion into evidence: across 7 Unity packs the
authored answer and the filename rule agree on 5, and both disagreements made the
rule better (one filter dropped, one guard added).

**Mike's answers, 2026-11-24, to the four questions this plan raised.**

| Question | Answer | Effect on this plan |
|---|---|---|
| Commit this plan file? | **Yes** | Committed on `fix/stage-1-correctness`. |
| Read `.unitypackage`, to widen the authored texture chain from 7 packs to ~90? | **Yes** | WP6 **Phase B**, approved work, not a follow-on. |
| Vendor `cgltf` for GLB/glTF? | **Yes** | WP8 Phase A is unblocked; no further dependency approval needed for `cgltf` specifically. |
| DAE? | **Skip** | WP8 Phase B is closed, not deferred. Do not write a COLLADA reader. Revisit only if a DAE with no twin enters the library. |
| Who runs the catalog rewrites? | **Claude runs them once the code is right — tell Mike** | No approval needed per run; a backup first, and say so afterwards. |

**The catalog rewrites, now authorised.** WP4 and WP5 each finish with a
`backfill_rigs.py --all` pass over the FBX rows. Mike's instruction, 2026-11-24:
*once you have fixed the code to do what is necessary you can run the backfill,
just let me know.* So run it, under these conditions, each of which exists
because of something that has gone wrong before:

1. **The code first.** The rule it writes has to be the final one, with its tests
   passing. A backfill run on a half-right rule has to be run again.
2. **Atlas must not be running** — the script's own docstring says so, and the
   Python suite's `database is locked` failures come from exactly this. Mike's app
   is his; ask him to close it rather than killing the process.
3. **Back up first**, to `asset_atlas_native.db.before-<change>`, beside the two
   earlier backups. This is a write over the whole catalog.
4. **`--dry-run` first**, read the counts, and only then the real pass.
5. **Say what it did afterwards**: rows changed, the family histogram before and
   after, and how long it took.
6. **Not a licence for the tagging run.** §0.6 still holds: the backfill is about
   a minute of twelve workers, the tagging run is hours of GPU-less inference.
   They are different asks and only the first is authorised.

### 0.4 Rules of the repo (they have each caused real damage when ignored)

1. **Write the failing test first.** Each WP lists its tests. Run them and see them
   fail before you change the code.
2. **Never weaken or delete a test to get green.** A few existing tests encode
   behaviour Mike has now asked to change; those are listed by name in the WP that
   changes them. Change only those, and say so in the commit message.
3. **Version bumps:** run `work/asset_atlas_native/scripts/bump_version.ps1`. It
   rewrites `pubspec.yaml` and `const appVersion` together. Never edit either by hand.
4. **Close Atlas before building.** The build fails while the exe is running.
5. **The gate**, run after your *last* edit (a clean run followed by one more edit
   proves nothing):
   - from `work/asset_atlas_native`: `flutter analyze` then `flutter test`
   - from `work/atlas_mcp` (not the repo root — the root finds 0 tests):
     `python -m unittest discover -p "test_*.py"`
   - Baseline at `bd8e9a2`: 678 Dart passed / 25 skipped; 401 Python OK / 2 skipped.
6. **`lib/main.dart` is a deliberate monolith** (17,624 lines). Do not split it as
   part of this work.
7. **Never compute anything over the whole catalog inside a widget's `build()`.**
   The catalog is ~480,000 rows. A walk per frame is what made the viewer unusable
   (fixed in `64dc287`). Build an index once per catalog revision and look things up.
8. **Never put a `Tooltip` directly inside `ToggleButtons`.**
9. **The catalog database belongs to Atlas.** Anything else opens it read-only.
   `backfill_rigs.py` is the one script that writes, and only with Atlas closed.
10. **Where the same rule must exist in Dart and Python, test both against one
    shared JSON fixture.** The repo already does this for the search grammar
    (`work/atlas_mcp/fixtures/search_queries.json`). Two copies of a rule with no
    shared test is exactly how the rig classifier drifted.
11. When a WP changes design, update `ARCHITECTURE.md` and add a `DECISIONS.md`
    entry in the same commit.
12. If you use an AI agent with a Bash tool on Mike's machine: heredocs strip
    backslashes there. Write scripts to a file, then run the file.

### 0.5 Terms

- **Importer** — `asset_atlas_mesh_importer.exe`, built from
  `work/asset_atlas_native/windows/runner/mesh_importer.cpp`. Reads FBX/OBJ with
  the `ufbx` library and prints JSON. `--probe` prints a few facts; `--summary`
  prints counts and names (including `boneNames`); no flag prints the whole mesh.
- **Probe** — one `--probe` run. Fills `model_kind` and `rig_family` in the catalog.
- **Clip** — an FBX with a skeleton and motion but no mesh (`model_kind='animation'`).
- **Character** — a mesh with skin weights.
- **Container** — the zip, or the top-level folder under a scanned source root, a
  file came from. `assetContainerKey`, `main.dart:14835`.
- **Animation character** — the one model Mike has chosen to play clips on.
  Class `AnimationCharacter`, `main.dart:14481`. Stored in the `settings` table.

### 0.6 Standing hold: no full tagging or embedding run

**Mike's instruction, 2026-11-24: he is using this machine for other work. A full
tagging run would get in the way. Hold it. Small tests are fine.**

What that means in practice:

- **Do not** press ✨ with the whole library in scope, run `tag_assets.py` over the
  library, or start any re-embedding pass — including the one WP6 creates the need
  for by changing what ~14% of FBX models look like.
- **Do** run small, scoped passes: a single pack, or a few hundred models, in
  `Quiet` mode. That is enough for every measurement WP9 asks for.
- WP9's measuring step (§WP9 step 1) is written against **200 models per mode**,
  not the whole library, for exactly this reason. Even that is four short runs —
  schedule them when Mike says the machine is free.
- The full run stays on the list as work Mike starts when it suits him. It is
  resumable by design: the queue is "whatever has no vector yet", so stopping and
  restarting loses at most the batch in flight.
- Ask before any run longer than a few minutes. Do not infer permission from this
  paragraph — it is a hold, not a budget.

---

## WP1 — `.uasset` must not get the audio player (item 6) · XS

### Problem (Verified)

`_PreviewPanelState._previewFor` (`main.dart:3445`) has a branch for
`type == 'image'`, a branch for `type == 'model'`, and then **everything else falls
through to `AudioPreview`** (`main.dart:3519`). Files of type `unreal` (`.uasset`,
`.umap`, `.uexp`, `.ubulk`) and type `other` therefore show a play button.

It is worse than a wrong picture. `looksLikePlayableAudio` (`main.dart:3553`) ends
with `return true` for any extension it does not know. Its own comment says the
Windows audio plugin "dies with an access violation on malformed input — a native
crash Dart cannot catch". So pressing Play on a `.uasset` hands raw Unreal bytes to
that plugin. **Inferred:** this can take the whole app down. Do not test it by
pressing the button on a build you care about.

### Required behaviour

- `audio` → the audio player (unchanged).
- `unreal` → a plain panel: the Unreal icon (`Icons.videogame_asset_outlined`, the
  one the type list already uses at `main.dart:2793`), the file name, and the text
  "Unreal asset. It can only be opened in Unreal Engine." No play button.
- `other` → a plain panel: "No preview for .EXT files."
- `looksLikePlayableAudio` returns `false` for an extension it does not know.

### Steps

1. In `_previewFor`, replace the final fall-through with an explicit
   `if (item.type == 'audio')` branch, then an `unreal` branch, then a default.
2. Make a small `StatelessWidget` for the two plain panels (one widget, two
   messages). Copy the box styling from `_unsupportedZipModelPreview`
   (`main.dart:3523`) so it looks like the rest.
3. Change the last line of `looksLikePlayableAudio` from `return true` to
   `return false`.

### Tests (`test/audio_safety_test.dart`, `test/browse_ui_test.dart`)

- `looksLikePlayableAudio(bytes, 'uasset')` is `false` for any bytes. **Fails today.**
- Widget test: pump `PreviewPanel` with an asset whose `ext` is `uasset`; expect
  `find.byType(AudioPreview)` finds nothing. **Fails today.**
- Widget test: an asset with `ext: 'wav'` still finds one `AudioPreview`.

### Out of scope

Showing the FBX twin in place of the plain panel — that is WP7.

---

## WP2 — Keep the search text across type changes (item 4) · XS

### Problem (Verified)

`onTypeChanged` in the main state's `build` (`main.dart:1660`) does this on purpose:

```dart
typeFilter = value;
// A query typed against one type almost never means
// anything against the next, and leaving it set makes
// the new type look empty.
searchController.clear();
_onSearchChanged('');
```

Mike wants the opposite. The comment's worry (the new type looks empty) is real, so
answer it a different way.

### Required behaviour

- Changing the type filter changes only the type filter. The text box and the
  active query are untouched.
- The "Only animations for my character" chip (`main.dart:2492`) calls the same
  `onTypeChanged`, so it gets the same fix for free. Check it.
- When the visible list is empty **and** a query is active, the summary line says
  so: `0 of N — still searching for "door"` with a **Clear search** button. This
  goes in `SearchAndSummary` (`main.dart:2644`), which already receives
  `visibleCount` and the controller.

### Steps

1. Delete the comment and the two lines that clear the search.
2. Add the empty-state line and button to `SearchAndSummary`. The button calls
   `controller.clear()` and `onChanged('')`.

### Tests (`test/browse_ui_test.dart`)

- Type `door`, select type `model`: the text field still reads `door` and the list
  is still filtered by it. **Fails today.**
- With a query that matches nothing in the new type, the "still searching" line and
  the Clear button appear; pressing Clear empties the box and restores the list.

---

## WP3 — Bone lookup: a case-folded fallback (item 1, first half) · M

### Problem (Verified)

`SkeletonAnimation.indexOfBone` (`main.dart:15564`) finds a bone three ways, in
order: exact path, path with duplicate suffixes stripped (`normalizeBonePath`,
`main.dart:15465`), exact name. All three use `==`. Nothing folds case.

Synty's exporter writes mixed case **inside one skeleton**. Mike's chosen animation
character, `SK_Chr_BR_War_Robot_01.fbx`, has `Pelvis`, `Thigh_L`, `Foot_L`,
`Hand_L`, `UpperArm_L` next to `spine_01`, `calf_l`, `clavicle_l`. The Sidekick
locomotion clips name the same joints all lower-case. Nine bones fail on case alone:

| Character | Clip |
|---|---|
| `Pelvis` | `pelvis` |
| `Thigh_L`, `Thigh_R` | `thigh_l`, `thigh_r` |
| `Foot_L`, `Foot_R` | `foot_l`, `foot_r` |
| `UpperArm_L`, `UpperArm_R` | `upperarm_l`, `upperarm_r` |
| `Hand_L`, `Hand_R` | `hand_l`, `hand_r` |

Those are the hips, legs, feet, arms and hands. A walk clip moves the spine and
leaves the legs in the bind pose.

Across 800 characters, the share of each character's bones that its best clip rig
names:

| | p10 | median | characters at ≥ 50% |
|---|---|---|---|
| Exact (today) | 0.36 | 0.91 | 486 of 800 |
| Case folded | 0.56 | 0.91 | **786 of 800** |

**Folding is safe inside a skeleton (Verified):** in 1,024 skeletons, folding case
never merged two distinct bone names.

**Folding is not safe across rig families unless guarded (Verified):** today a
Polygon rig and a Sidekick rig share **zero** names. Folded, a character shares a
median 27% (p90 34%) of its bones with the *wrong* family's rig — `Spine_01` and
`spine_01`, `Head` and `head`. The code's guard today is a count, `minimumRigOverlap
= 4` (`main.dart:15261`). Four is no longer enough once folding is on.

### Required behaviour

1. `indexOfBone` keeps its three existing steps **in the same order**, then adds:
   4. path match with case folded (after `normalizeBonePath`),
   5. name match with case folded.
   Because 4 and 5 run only when 1–3 found nothing, every lookup that succeeds
   today returns the same index as today.
2. If two bones in one skeleton fold to the same key, that key matches nothing
   (ambiguous — never guess). This has not been seen in the library; handle it anyway.
3. A new rule decides whether a clip may drive a character at all. Call it
   `rigMatch(character, clip)` and make it the **only** place this is decided:
   - `exactShared` = bones matched by steps 1–3; `foldedShared` = matched by 1–5.
   - Compatible if `exactShared >= minimumRigOverlap` (this is today's rule, kept
     so nothing that pairs today stops pairing),
   - **or** if `foldedShared / character.bones.length >= minimumRigMatchFraction`,
     a new constant, `0.5`.
   - Measured: at 0.5, 786 of 800 characters pass against their right rig and 6
     against a wrong one; at 0.4 it is 786 and 8. Use 0.5.
4. Replace both raw uses of `minimumRigOverlap` with `rigMatch`:
   - in `rigAxisDifference` (`main.dart:15222`): `if (angles.length <
     minimumRigOverlap) return double.infinity;`
   - in the reference search inside `_SkeletonPlayerState` (`main.dart:4787`):
     `if (bestOverlap < minimumRigOverlap)`.

### Steps

1. Folded lookups must not allocate per call — `indexOfBone` is called per bone in
   loops, and `rigAxisDifference` calls it for every bone. `SkeletonAnimation` has
   a `const` constructor, so it cannot hold a lazily built map. Use a top-level
   `Expando<Map<String, int>>` keyed on the skeleton object, built on first use.
   There is a worked example of exactly this pattern: `_sceneNames`,
   `main.dart:6243`. One map for folded names, one for folded normalised paths.
2. Add steps 4 and 5 to `indexOfBone`.
3. Add `minimumRigMatchFraction` and `rigMatch` next to `rigBoneOverlap`
   (`main.dart:15268`). Give it a doc comment carrying the measurements above.
4. Swap the two guards for `rigMatch`.

### Tests

**Must pass without being edited** — this is the "do not lose what works" proof:
`skinning_test.dart`, `corpus_skinning_test.dart`, `skeleton_test.dart`,
`rig_reference_test.dart`, `animation_fbx_test.dart`. If one fails, the change is
wrong; do not touch the test.

New, in `test/skeleton_test.dart`:

- `indexOfBone('pelvis')` on a skeleton whose bone is `Pelvis` finds it.
  **Fails today.**
- A skeleton holding both `Hips` and `hips`: `indexOfBone('HIPS')` is `-1`
  (ambiguous); `indexOfBone('Hips')` and `indexOfBone('hips')` each find their own.
- Exact wins over folded: with bones `['hand_l', 'Hand_L']` at indices 0 and 1,
  `indexOfBone('Hand_L')` is 1.
- **War Robot regression.** Build two skeletons from the real name lists (the 48
  character bones and the 121 clip bones — get them with
  `asset_atlas_mesh_importer.exe --summary <file>` and read `boneNames`; the files
  are named in the appendix). Assert the character's `Pelvis`, `Thigh_L`,
  `Thigh_R`, `Foot_L`, `Foot_R`, `UpperArm_L`, `UpperArm_R`, `Hand_L`, `Hand_R`
  each resolve in the clip. **All nine fail today.**
- `rigMatch`: a Polygon-named skeleton against a Sidekick-named one is **not**
  compatible (use the real name lists; folded overlap is about 27%).
- `rigMatch`: two skeletons sharing 5 bones exactly out of 60 **are** compatible
  (the old count rule is preserved).

### What is still Unknown — check by eye before calling it done

Names matching is necessary, not proven sufficient. Once the hips and legs match,
`rigAxisDifference` sees more bones, and its median angle can cross
`maxDirectPoseAngle = 40.0` (`main.dart:15215`), switching a character between
"pose directly" and "retarget through a reference". Nobody has looked at the
result. Before shipping, in the built app:

1. Choose the War Robot as animation character, play
   `A_MOD_BL_Idle_Standing_Femn.fbx` and a walk clip. The legs must move and the
   mesh must not tear.
2. Play a **Polygon** clip on `PolygonSyntyCharacter.fbx` and a **Sidekick** clip on
   `SidekickSyntyCharacter.fbx` (all in `ANIMATION_Base_Locomotion_SourceFiles_v3.zip`).
   These work today. They must look identical after the change.
3. If the War Robot tears, stop and report with a screenshot. Do not tune
   `maxDirectPoseAngle` to hide it.

---

## WP4 — One rig classifier, and an "other rig" family (items 1, 2, 3) · M

### Problem (Verified)

Two functions turn the importer's marker bones into a family, and they disagree:

| | Dart `rigFamilyFromMarkers` (`main.dart:7977`) | Python `rig_family_from_markers` (`atlas_mcp.py:1035`) |
|---|---|---|
| Sidekick if any of | `hipAttachFront`, `hipAttach_l`, `hipAttach_r` | `hipAttachFront`, `hipAttach_l`, `ik_hand_gun`, `ik_hand_root` |
| then | Unreal if `pelvis` or `thigh_l` | Polygon if `Hips`, `UpperLeg_R`, `Clavicle_L` or `Spine_01` |
| then | Polygon if `Hips` or `UpperLeg_R` | Unreal if `pelvis`, `thigh_l`, `clavicle_l` or `spine_01` |

The importer reports twelve markers (`kRigMarkerBones`, `mesh_importer.cpp:257`).
The Dart rule ignores six of them and tests one (`hipAttach_r`) the importer never
reports.

**Both write the same column.** `backfill_rigs.py` writes `rig_family` with the
Python rule. Atlas's lazy pass, `classifyFbxChunk` (`main.dart:12790`, the write is
near line 12850), writes it with the Dart rule. The column is a mixture.

Three more defects sit on top:

1. **No clip is `unreal`.** The 796 clips are 359 `polygon`, 346 `sidekick`, 91
   `none`. `rigFamiliesCompatible` (`main.dart:8005`) requires equal names. So for
   any character stored as `unreal` (348 of them, including Mike's War Robot),
   "Only animations for my character" passes **0 of 796**. Yet Sidekick clips are
   exactly what drives those characters — the Sidekick rig *is* the Unreal
   mannequin with extra bones (the `RigFamily` doc comment says so itself).
2. **`none` means two things** — see 0.3.
3. **One generic bone decides a family.** Kenney's `idle.fbx` has a 58-bone
   Blender-style rig sharing three names with the Polygon rig. It is stored as
   `polygon` because it has a bone called `Hips`. 13 clips (9 Kenney, 4 Unity
   samples) are mislabelled this way.

### Required behaviour — the one rule

Input: the marker list, and the bone count. Both languages implement exactly this:

1. `bones == 0` → `none`.
2. Any of `hipAttachFront`, `hipAttach_l`, `ik_hand_gun`, `ik_hand_root` → `sidekick`.
3. **Two or more** of `Hips`, `UpperLeg_R`, `Clavicle_L`, `Spine_01` → `polygon`.
4. **Two or more** of `pelvis`, `thigh_l`, `clavicle_l`, `spine_01` → `unreal`.
5. Otherwise → `other`.

The "two or more" is new in both languages and is what stops a lone `Hips` from
naming a family. Real marker sets seen in the library, which the fixture must cover:

| Markers the probe reports | Seen (of 300) | Family |
|---|---|---|
| `pelvis`, `thigh_l`, `clavicle_l`, `spine_01`, `ik_hand_gun`, `ik_hand_root` | 103 | sidekick |
| `clavicle_l`, `spine_01`, `ik_hand_gun`, `ik_hand_root` | 81 | sidekick |
| `clavicle_l`, `spine_01` | 40 | unreal |
| `Hips`, `UpperLeg_R`, `Clavicle_L`, `Spine_01` | 39 | polygon |
| `pelvis`, `thigh_l`, `clavicle_l`, `spine_01` | 30 | unreal |
| `Hips` alone, 58 bones (Kenney) | — | **other** |
| none, 82 bones (Dogs pack) | — | **other** |
| none, 0 bones (a prop) | — | none |

Compatibility, in `rigFamiliesCompatible`:

- `none` drives nothing and is driven by nothing (unchanged).
- Same family → compatible (unchanged).
- **`unreal` and `sidekick` are compatible with each other** (new).
- `other` with `other` → compatible **only if both files are in the same
  container**. WP5 replaces this stopgap with a real bone comparison.

### Steps

1. **Shared fixture.** Create `work/atlas_mcp/fixtures/rig_families.json`: a list
   of `{ "markers": [...], "bones": N, "family": "..." }` covering every row of the
   table above plus each rule's edge (exactly one Polygon marker; exactly two).
2. **Dart.** Add `other` to `enum RigFamily` (`main.dart:7950`) with label
   `Other rig`. Change `none`'s doc comment to "no bones at all". Rewrite
   `rigFamilyFromMarkers` to take the bone count and follow the rule. Every
   `switch` over `RigFamily` will stop compiling until it handles `other` — that is
   the compiler finding the call sites for you. For `AttachPoint.bonesFor`
   (`main.dart:12001`) return an empty list for `other`.
3. **The two Dart call sites.**
   - `classifyFbxChunk`: pass `(json['bones'] as num?)?.toInt() ?? 0`. The probe
     already prints `"bones"` in both of its branches (`mesh_importer.cpp:570` and
     `:583`), so **the importer does not change in this WP**.
   - `rigFamilyOfSkeleton` (`main.dart:7998`): pass `skeleton.bones.length`.
4. **Python.** Change `rig_family_from_markers` to take `bones` and follow the same
   rule. Update its callers (`atlas_mcp.py` near lines 1389, 1563, 1590) and
   `backfill_rigs.py` (pass `result.get("bones")`). The character filter at
   `atlas_mcp.py:699` already reads `rig_family != 'none'`, which now correctly
   lets `other` count as a character — check it, do not change it.
5. **`rigFamiliesCompatible`**: implement the four bullets above. It needs the two
   assets' containers for the `other` case; give it optional container arguments
   rather than a second function.
6. **`_referenceRank`** (`main.dart:14864`): `other` ranks 0 (a known rig), `none`
   stays 2. This is what lets a dog clip find the dog mesh as its reference.
7. **Stale stored rig.** `AnimationCharacter` keeps its own copy of the family in
   the setting `animation.character.rig` (written from `widget.asset.rigFamily` at
   `main.dart:4150`). After a backfill that copy is stale. Wherever the catalog
   finishes loading, if the chosen character's path matches an asset, overwrite
   `AnimationCharacter.instance.rigFamily` with that asset's current `rigFamily`.
8. **Re-fill the column** (authorised 2026-11-24 — Claude runs it and reports;
   the conditions are in §0.3):
   1. Ask Mike to close Atlas, and confirm it is closed.
   2. Copy `%APPDATA%\com.example\asset_atlas_native\asset_atlas_native.db` to
      `asset_atlas_native.db.before-rig-rules-2` (two earlier backups beside it
      follow this naming).
   3. `python -I work/atlas_mcp/backfill_rigs.py --all --dry-run` and read the
      counts it prints. Expect `other` to appear and `unreal` not to vanish.
   4. The same command without `--dry-run`. About a minute for 27,000+ files.

### Tests

Both suites read the shared fixture and assert every row:
`test/rig_family_test.dart` and `work/atlas_mcp/test_atlas_mcp.py` (next to the
existing marker tests near line 299).

**Existing tests that encode the old behaviour and must be changed — these, and
only these.** Say in the commit message that Mike approved the change on 2026-11-24.

- `rig_family_test.dart`, "families never drive each other" → still true for every
  pair **except** unreal/sidekick, which must now be asserted compatible.
- `rig_family_test.dart`, "an unrecognised skeleton is not forced into a family" →
  now asserts `other` when bones > 0 and `none` when bones == 0.
- `rig_family_test.dart`, "a prop with no bones has no rig" and "a rigless prop is
  compatible with nothing, including itself" → keep the assertions, add the bone
  count argument.
- `rig_family_test.dart`, "each family has one for the filter menu" → add `other`.
- `test_atlas_mcp.py` lines ~299–308 → add the bone count argument.

New:

- `rig_filter_test.dart`: with `characterRig: 'unreal'`, an asset with
  `rigFamily: 'sidekick'` passes the `compatible` filter. **Fails today** — this is
  the 0-of-796 bug.
- `rig_reference_test.dart`: `findClipReferenceCharacters` for a clip in a
  container whose only mesh has `rigFamily: 'other'` returns that mesh.
  **Fails today.**

### Acceptance check after the backfill

Open the catalog **read-only** and run:

```sql
SELECT model_kind, rig_family, count(*) FROM catalog_assets
WHERE ext = 'fbx' GROUP BY 1, 2 ORDER BY 3 DESC;
```

Expect: no `animation` row with `none` unless it truly has zero bones; the Dogs
pack clips under `other`; the 9 Kenney clips under `other`.

---

## WP5 — Rig signatures, model↔animation lists, audition (item 8) · L

**Depends on WP3 and WP4.**

### What Mike asked for

Keep, as stored metadata, which animations work on which model and which models an
animation works on. Selecting a model lists its animations and lets him audition
one. Selecting an animation lists its models and lets him audition one.

### Design

**Store facts, not verdicts.** The fact is each file's bone names. Whether a clip
drives a character is a rule applied to two facts — the same `rigMatch` rule from
WP3. Storing the verdict for every pair would be about 1.7 million rows
(2,147 characters × 796 clips) that must all be rewritten whenever the rule
changes. Storing the facts is tiny, because rigs repeat:

- 224 clips sampled → **12** distinct rigs.
- 800 characters sampled → **42** distinct rigs.

So: every rigged file gets a **rig signature** (a short hash of its bone names).
The bone names are stored once per signature. Compatibility is computed between
*signatures* — a few hundred pairs for the whole library — and cached in memory.

### Storage (schema 7 → 8)

In `AssetAtlasDatabase` (`schemaVersion` at `main.dart:16308`; migrations in the
`onUpgrade` block at `main.dart:16355` — copy the shape of the `oldVersion < 7`
step):

```sql
ALTER TABLE catalog_assets ADD COLUMN rig_signature TEXT;
CREATE TABLE rig_bones (
  signature  TEXT PRIMARY KEY,
  bone_count INTEGER NOT NULL,
  bones_json TEXT NOT NULL      -- the names exactly as the file spells them
);
```

`rig_signature` is null for a file with no bones or not yet probed.

**Signature definition — identical in Dart and Python:** lower-case every bone
name, sort, join with `\n`, SHA-1, first 12 hex characters. Lower-cased so two
exports of one rig that differ only in case share a signature. Add
`work/atlas_mcp/fixtures/rig_signatures.json` (`{ "bones": [...], "signature":
"..." }`) and test both languages against it.

### Importer change

`--probe` does not print bone names today; `--summary` does
(`mesh_importer.cpp:384–393`, the `boneNames` loop inside `print_summary`).

1. Move that loop into its own function, `print_bone_names(scene)`.
2. Call it from `print_summary` (output unchanged) and from **both** branches of
   the `--probe` block (`mesh_importer.cpp:554–588`), after `print_rig_markers`.
3. Rebuild (Atlas closed). `test/native_fbx_importer_test.dart` is where importer
   output is tested — add a probe test that expects `boneNames`.

### Writing the signature

Both writers, same as WP4:

- `classifyFbxChunk` returns kind and family packed in one string
  (`FbxClassification.encode`, `main.dart:7940`: `kind#rig`). Extend it to carry
  the signature and the bone list. Keep `decode` reading the older two forms — a
  test in `rig_filter_test.dart` already covers "an older value with no rig still
  decodes"; add the three-part case beside it.
- `backfill_rigs.py`: compute the signature, write `rig_signature`, and
  `INSERT OR IGNORE` into `rig_bones`. Then re-run it with `--all` as in WP4 step 8
  (new backup name: `.before-rig-signatures`).

### The index (never in `build()`)

One object, rebuilt only when the catalog revision changes:

- `Map<String, List<AssetItem>> clipsBySignature`
- `Map<String, List<AssetItem>> charactersBySignature`
- a cache `Map<String, bool>` keyed `charSig|clipSig` → the `rigMatch` answer,
  filled on demand from `rig_bones`.

Then:

- **animations for a model** = for each clip signature compatible with the model's
  signature, all clips in `clipsBySignature`. Sort: same container first, then path.
- **models for an animation** = the mirror, over `charactersBySignature`. Only
  meshes with `model_kind = 'mesh'` and a signature.

Load `rig_bones` once at catalog open (a few dozen rows).

### UI — the lists

In `AssetDetailsPanel` (`main.dart:7315`), below the tags, above
`ModelTextureDiagnostics`:

- On a rigged mesh: **"Animations for this model (N)"**.
- On a clip: **"Models this clip drives (N)"**.
- On a file with no signature: nothing. No empty header.

The panel is already a `ListView`, so the new list cannot be a second unbounded
list inside it. Put a `ListView.builder` in a `SizedBox` of fixed height (about
240 px). Use the builder — the Sidekick list is 346 rows.

Each row: file name, pack name in grey, and a play button. Clicking the name
selects that asset (`onActivateAsset`, which the panel already has).

### UI — audition

"Audition" means: play that pairing in the big preview now, **without** changing
Mike's saved animation character.

The preview and the details panel are both children of `_PreviewPanelState`
(`main.dart:3379`). Hold the audition there:

- State: `AssetItem? audition`. Clear it in `didUpdateWidget` when `widget.asset`
  changes. Pass a setter to `AssetDetailsPanel` and the value to the preview.
- **A model is selected, a clip is auditioned.** Load the clip with
  `MeshLoadCache.load(clip, allAssets: ...)`, take its `.skeleton`, and show
  `SkeletonPlayer(skeleton: clipSkeleton, characterPath: model.path, allAssets:
  ..., clipPath: clip.path)` in place of the still model view. `SkeletonPlayer`
  (`main.dart:4618`) already takes all four. Show a **Stop** button that clears the
  audition and returns to the still view.
- **A clip is selected, a model is auditioned.** `AnimationClipPreview`
  (`main.dart:4983`) reads the character from `AnimationCharacter.instance.path`
  (`main.dart:5012`). Give it an optional `auditionCharacterPath`; when set, pass
  that to `SkeletonPlayer` instead. **Do not call `AnimationCharacter.instance.set`** —
  that would silently change his saved choice.
- Show what is playing: "Auditioning *clip* on *model*".
- The existing "Use for animations" button (`AnimationCharacterButton`,
  `main.dart:8619`) stays as it is. Audition is the temporary one; that button is
  the permanent one.

### The filter

`assetPassesRigFilter` (`main.dart:7890`), mode `compatible`: when the chosen
character and the asset both have signatures, answer with `rigMatch` through the
cache. Otherwise fall back to the WP4 family rule. Keep "an unclassified file is
never hidden".

This removes the WP4 stopgap for `other` (same container only): two `other` rigs
are now compatible exactly when their bones match.

### MCP

`atlas_mcp.py` matches rigs by family near lines 1563–1590 (`find_animations`).
Switch it to signatures with the same `rigMatch` rule, mirrored in Python and
tested against a shared fixture `work/atlas_mcp/fixtures/rig_match.json`
(`{ "character": [...], "clip": [...], "compatible": true|false }`). Include the
War Robot/Sidekick pair (true), a Polygon/Sidekick pair (false), and the dog pair
(true).

### Tests

- Shared signature fixture, both languages.
- Shared `rig_match` fixture, both languages.
- Index: three clips and two characters over two signatures → the right lists,
  same container first, and the same answer when the input list is shuffled.
- Widget: a rigged mesh shows "Animations for this model (2)"; a prop shows no such
  header.
- Widget: pressing a row's play button puts a `SkeletonPlayer` in the preview and
  leaves `AnimationCharacter.instance.path.value` unchanged.
- Widget: selecting a different asset clears the audition.
- Performance, env-gated like `test/drag_frame_cost_test.dart` (`@Tags(['benchmark'])`,
  skipped unless `ATLAS_CATALOG_DB` is set): building the index over the real
  catalog. Print the time. If it is over ~100 ms, build it off the UI isolate.

### Acceptance, by eye

1. Select the War Robot → the list shows the Sidekick locomotion clips. Audition a
   walk: the legs move.
2. Select a Sidekick clip → the list includes the War Robot and
   `SidekickSyntyCharacter`.
3. Select `Unity_SK_Animals_Dog_01.fbx` → the dog clips are listed and play.
4. Select a Polygon clip → the War Robot is **not** listed.

---

## WP6 — The texture the pack's author assigned (item 10) · M + M

### Mike was right: Synty did ship the robot with a texture in mind

He said he doubted the pack shipped the War Robot with no colouring intended. It
did not. The intended texture is **`PolygonSciFiSpace_Texture_01_A.png`**, and that
is not a guess — it is Synty's own assignment, read out of the pack (Verified).

The FBX genuinely names nothing (Verified):

- `SK_Chr_BR_War_Robot_01.fbx`: one material, `SciFiSpaceBase4`, **zero texture
  references**. The material name does not encode the atlas either — the atlas it
  is actually assigned is `Material_01_A`, not anything with a `4` in it.
- **32 of the 33** FBX in that pack's `_SourceFiles/Characters/` are the same.
- Library-wide: in a sample of 400 FBX meshes, **55 (14%)** have materials and no
  texture reference. 22 of those 55 are Kenney models.

But the pack carries the answer elsewhere. Unity stores an authored chain — a
`.prefab` names a material by GUID, the `.mat` names its `_MainTex` by GUID, and
every `.meta` maps a GUID to a path. Resolved for the robot:

```
PolygonSciFiSpace/Prefabs/Characters/SM_Chr_BR_War_Robot_01.prefab
  → guid 4cee7a5983b187943adc589b9cb1f084
  → PolygonSciFiSpace/Materials/PolygonScifiSpace_Material_01_A.mat
      _MainTex      → PolygonSciFiSpace/Textures/PolygonSciFiSpace_Texture_01_A.png
      _EmissionMap  → PolygonSciFiSpace/Textures/PolygonSciFiSpace_Emissive_01.png
```

That zip, `PolygonSciFiSpace_Unity_2017_4.zip`, is **already in the catalog**. The
same chain says the pack has 43 character prefabs, 42 of them resolve a `_MainTex`,
and **all 42 resolve to that one atlas** — the 43rd is a glass helmet with no base
texture. Across the whole pack it is **544 of 662 prefabs**. It also independently
confirms the weaker evidence noted earlier: the one sibling FBX that does name a
texture names this same file.

So this WP is not "invent a plausible texture". It is **read the answer the author
left, and fall back to a heuristic only where no author left one.**

### What the evidence supports (all Verified unless marked)

**The authored chain is reliable where it exists.** Per pack, the texture assigned
to the most prefabs, against what a filename heuristic picks:

| Unity pack | authored (prefabs using it) | filename heuristic | agree |
|---|---|---|---|
| PolygonSciFiSpace | `PolygonSciFiSpace_Texture_01_A.png` (544/662) | same | ✓ |
| PolygonMini_Fantasy | `PolygonMinis_Texture_01.png` (449/461) | same | ✓ |
| PolygonSnow | `PolygonSnow_Texture_01_A.png` (68/74) | same | ✓ |
| PolygonSpy | `PolygonSpy_Texture_01_A.png` (33/35) | same | ✓ |
| POLYGON_FantasyRivals | `FantasyRivals_Texture_01_A.png` (59/76) | same | ✓ |
| POLYGON_Nature | `PolygonNature_01.png` (191/225) | `Fern_Texture.png` | ✗ |
| POLYGON_SciFiCity | `Signs.png` (31/647) | *(none)* | ✗ |

5 of 7. Both misses are informative and both are fixed below:

- **Nature** — the heuristic required the word `texture`/`atlas`/`palette` in the
  name, so it could not even see `PolygonNature_01.png`. That filter is wrong and
  is dropped.
- **SciFiCity** — there is no base atlas. The best-used texture covers 31 of 647
  prefabs, and the pack really does spread across `Signs`, `NeonSigns`,
  `Billboards` and `Road`. The heuristic answering *nothing* is the **correct**
  outcome, and the rule below makes that explicit rather than accidental.

**Linking a model to its prefab works by stem.** The prefabs use `SM_`, the
skinned FBX uses `SK_`; strip a leading `SM_`/`SK_` and lower-case, and **614 of
667** FBX in the SourceFiles zip match a prefab. Characters are weaker, **20 of
33** — the unmatched ones are variants with no prefab (`SK_Chr_SpaceSoldier_Female.fbx`,
`..._old.fbx`). For those, the pack-dominant atlas from the same chain is the
fallback.

**Coverage is the real limit (Verified).** Of 231 zips under `Z:\Assets\Synty`,
only **10** are Unity builds, and 7 of those yield a chain. The other **83** Unity
builds are `.unitypackage` files, which Atlas does not index at all
(`archiveExts = {'zip'}`, `main.dart:107`). So tiers 1 and 2 below cover 7 packs
from `.zip` alone. **Mike approved reading `.unitypackage` on 2026-11-24**, which
widens them to roughly 90 — that is Phase B of this WP, and the chain is already
proven to resolve in that format (measurements in Phase B).

**Palette variants are interchangeable.** `PolygonSciFiSpace_Texture_01_A..F` are
all 2048×2048 and within 10% of one another in size; the `Signs` set is 1024×1024.
**Inferred:** A..F are palette swaps over one UV layout, so any of them lands
correctly on the model and picking the wrong *letter* is a colour difference, not a
scramble. Getting the atlas *family* right is what matters, and the existing
`TextureVariantGrid` already lets Mike flip between the variants.

### Why this still needs care

A wrong texture is worse than no texture. The tagging queue embeds the picture
Atlas draws, so a wrong atlas bakes a wrong picture into search for every affected
model. The repo has been bitten by exactly this — `test/black_render_diagnosis_test.dart`
records a turret that drew black because it resolved another pack's sign atlas.
Be conservative, be deterministic, and always say on screen that it was inferred.

A function meant for this case already exists and is **never called**:
`findModelFallbackTexture` (`main.dart:13906`) has zero callers. Read it, reuse what
fits, then delete it — do not leave two functions with one job, one of them dead.

### Required behaviour

Apply an inferred texture only when **all** of these hold (unchanged from the
earlier draft — these are the safety conditions):

1. The mesh has UVs.
2. **No** material names any texture reference at all. A model that names a texture
   which then fails to resolve is "missing", not "unnamed" — leave it alone; the
   diagnostics already report it, and `allowFallbackLookup: false` there is deliberate.
3. No material has an embedded texture.
4. Mike has not picked a texture by hand for this model.

Then resolve in tiers, stopping at the first that answers. One new function,
`findInferredTexture(model, allAssets)`, returning the path **and which tier
answered** so the UI can say.

**Tier 1 — the model's own prefab (authored, per model).**
In any container whose product key matches the model's (the twin key from WP7 —
this is why WP7 is worth doing first, though WP6 can ship with a simpler
same-product-name match), find a `.prefab` whose stem matches the model's stem with
a leading `SM_`/`SK_` stripped. Resolve prefab → `.mat` → `_MainTex` through the
`.meta` GUID map.

A prefab often names several materials, so it can resolve **more than one** base
texture — measured: 11 of 696 prefabs in PolygonTown (1.6%) and 109 of 765 in
PolygonAncientEmpire (14%). Atlas draws a model with **one** texture, so tier 1
has to choose, and counting material references cannot break the tie (each
material is referenced once; measured: 0 of those 120 prefabs had a dominant
reference count). The rule: **if exactly one of the prefab's textures is the
pack's dominant texture from tier 2, take it; otherwise take nothing from tier 1
and let tier 2 answer.** Verified on PolygonTown: all 11 two-texture prefabs
include `PolygonTown_Texture_01_A.png`, the pack dominant (691 of 696), so they
resolve correctly.

**Tier 2 — the pack's dominant assignment (authored, per pack).**
From the same Unity container, count across **all** its prefabs how many are
assigned each texture. Take the winner only if it is assigned to **at least 50% of
the prefabs that resolve to any texture**. That threshold is what makes SciFiCity
(31 of 647 = 5%) correctly answer nothing while SciFiSpace (82%) answers.

**Tier 3 — filename heuristic (a guess, clearly labelled).**
Only when no Unity data exists for the pack. Candidates: image assets in the
model's own container (`assetContainerKey`) whose path has a folder named `textures`
or `_textures` (any case).

- **Drop** if any folder below that one is `alts`, `alt`, `fx`, `fx_textures`,
  `emissive`, `normals`, `masks`, `skybox`, `ui`, `particles`. **Known blind
  spot:** PolygonAncientEmpire ships its authored base atlas *inside*
  `Textures/Alts/`, so this rule would reject the right answer there. That pack
  has a Unity build, so tiers 1 and 2 answer first and tier 3 never runs — which
  is the argument for Phase B, not for loosening this filter.
- **Drop** if `textureChannelWord(name)` (`main.dart:9909`) is non-empty, or the
  name contains `mask`, `emissive`, `skybox`, `flare`, `dirt`, `gradient`, `glow`,
  `trail`, `normal`, `roughness`, `metallic`, `specular`.
- **Do not** require the word `texture` in the name — that is the Nature miss.
  Instead **require** at least one name token shared with the container's product
  name (`textureNameTokens`, `main.dart:9873`), unless exactly one candidate
  survives the filters.
- **Rank**, each step breaking ties in the one before:
  1. fewest folders between the `textures` folder and the file;
  2. most name tokens shared with the container's product name;
  3. fewest name tokens overall (so `PolygonSciFiSpace_Texture_01_A` beats
     `PolygonSciFiSpace_Signs_Texture_01_A`);
  4. name ends `_01_a`, then `_01`, then `_a`;
  5. path, alphabetical. **Not optional** — without a total order the winner
     depends on scan order (see `docs/tasks/TASK-04`).
- **Dominance guard:** if the top two survivors tie on steps 1–3, answer nothing.
  Two equally good base atlases means the pack has no single default.

**Tier 4 — nothing.** Flat colour, exactly as today.

Honesty in the UI — the wording differs by tier, because the confidence does:

- Tier 1: `Texture: from the pack's prefab — NAME`
- Tier 2: `Texture: pack default — NAME`
- Tier 3: `Texture: guessed — NAME`
- `TexturePickerButton` (`main.dart:8541`) shows that in place of `Texture: auto`.
- The material summary that today reads `flat colour, no texture`
  (`main.dart:8532`) carries the same sentence.
- Picking by hand, or "Auto", behaves as today. Add one menu item, **"None (flat
  colour)"**, so a wrong inference can be switched off per model.

### Phase A — steps for the 7 `.zip` Unity builds

1. **A reader for the Unity chain.** New top-level function, given a container:
   build `guid → path` from every `.meta` in it, and a `materialPath → texturePath`
   map from every `.mat`. Cache it per container — it is a few hundred small file
   reads, and both tiers 1 and 2 need it. The three regexes needed are in
   Appendix B. Prefabs and `.mat`/`.meta` files are plain YAML text; they are type
   `other` in the catalog but they are inside archives Atlas already reads, so
   `readZipVirtualAssetBytesByPath` reaches them.
2. **Look before wiring it in.** Extend the throwaway script in Appendix B to print,
   for 20 packs, each model, its tier and the texture chosen. Read the list. **Show
   Mike the list before going further** — if more than one or two look wrong, fix
   the rule, not the list.
3. Write `findInferredTexture` with the four tiers. Delete `findModelFallbackTexture`.
4. Call it at the end of the FBX material build (the block starting near
   `main.dart:13505`, after the per-material resolution loop) and at the end of the
   OBJ path (`withResolvedObjTextures`, `main.dart:13141`), guarded by the four
   conditions. Apply with the existing `applyChosenTexture` (`main.dart:13048`), and
   record the tier on the mesh (a new field on `MeshModel`, default "none").
5. Update the UI strings and add the "None" menu item.
6. `renderAsset` (`main.dart:17528`) goes through `loadMesh`, so the bridge and the
   tagging queue pick this up with no further change. **Consequence:** models that
   were embedded as flat grey now draw textured, so their stored vectors are stale.
   Same re-embed problem already open for ~4,900 OBJ files; it needs the `--force`
   flag that does not exist. Record it, do not build it here. **And note the hold in
   §0.6 — do not start a re-embedding run.**

### Phase B — read `.unitypackage` (approved 2026-11-24) · M

This is what takes tiers 1 and 2 from 7 packs to roughly 90. Do it **after**
Phase A works on the 7 `.zip` packs, so the chain reader is already proven.

**The format (Verified by streaming two of them).** A `.unitypackage` is a
**gzipped tar**. Each asset is one directory *named by its GUID*, holding:

- `asset` — the file's own bytes;
- `asset.meta` — Unity's import settings;
- `pathname` — a one-line text file with the path the file had in the project,
  e.g. `Assets/PolygonTown/Models/Props/SM_Prop_Streetlamp_02.fbx`.

Two consequences, and they decide the design:

1. **The GUID → path map is free.** In the `.zip` builds it has to be parsed out
   of every `.meta`; here the directory name *is* the GUID and `pathname` is the
   path. The chain reader needs no `.meta` parsing at all in this format.
2. **Entry names carry no file names.** A `.unitypackage` entry is
   `001714447b764f24b9bd5b22a78b0c63/asset`. `extensionOf` on that yields nothing,
   so `typeForExt` returns `other` and `scanZipAssetEntries` (`main.dart:11030`)
   would skip every single entry. **Adding `unitypackage` to `archiveExts` alone
   accomplishes nothing.**

**Measured (two packs, read-only, nothing extracted):**

| | PolygonTown (26 MB) | PolygonAncientEmpire (120 MB) |
|---|---|---|
| one sequential pass | **0.7 s** | **1.5 s** |
| GUIDs mapped | 2,209 | 2,323 |
| materials / prefabs | 25 / 696 | 131 / 765 |
| prefabs resolving a base texture | **696 of 696** | **760 of 765** |
| character prefabs resolving | **9 of 9** | **39 of 39** |
| pack dominant | `PolygonTown_Texture_01_A.png` (691) | `PolygonAncientEmpire_Texture_01_A.png` (558) |

All 83 `.unitypackage` files total **4.98 GB**; at the measured ~36 MB/s of
compressed input that is **about 140 s of single-threaded streaming** for the whole
library, once, cached afterwards.

**Evidence that this beats the filename rule:** AncientEmpire's authored base atlas
lives in `Textures/Alts/`, which tier 3 explicitly **drops** as a variant folder.
Tier 3 would get that pack wrong; tier 1 gets it right.

**Steps.**

1. **Do not index the contents.** Resist adding `unitypackage` to `archiveExts`:
   that path indexes every entry as a catalog row, and here the rows would be
   GUID-named and useless, 2,000+ per pack. Instead treat a `.unitypackage` as a
   **sidecar the texture resolver reads on demand**, exactly like a `.zip` Unity
   build but with its own reader. If Mike later wants the Unity builds browsable as
   assets, that is a separate scanning task with its own decision: it would need
   each entry's name taken from `pathname`, not from the tar entry.
2. **Write the reader next to the existing one.** One function that, given an
   archive path, returns the pack's `{guid: pathname}` map and the bytes of its
   `.mat` and `.prefab` entries. Two implementations behind one signature: the
   `.zip` one (seekable, `.meta` parsing) and the `.unitypackage` one (sequential).
3. **Sequential, single pass, bounded memory.** A gzipped tar is **not seekable** —
   there is no central directory, so random access is impossible; you must walk it
   front to back. Collect only what the chain needs: the map, plus `.mat` and
   `.prefab` bytes (both tiny — 131 materials and 765 prefabs of a few KB each).
   Never hold `asset` bytes for models or textures. A `pathname` can arrive
   *after* its sibling `asset` in the tar, so hold small unknown `asset` bytes
   (cap each at a few MB) until the `pathname` names them, then drop or keep.
   Dart: the `archive` package already in `pubspec.yaml` reads gzip and tar
   (`GZipDecoder`, `TarDecoder`), so **no new dependency** — but check whether it
   can stream rather than materialise the whole 364 MB package in memory; if it
   cannot, do this work in the C++ importer or a Python helper instead, and say
   which in the commit message.
4. **Cache the answer, not the archive.** Per Unity container, persist the
   resolved `{model stem: texture path}` map and the pack dominant. 140 s once is
   fine; 140 s per app start is not. Key the cache on the archive's path, size and
   mtime, in the same table WP6 Phase A uses.
5. **Match the pack to the model.** The Unity build and the FBX build are separate
   files (`POLYGONTown_Unity_2019_4_28.unitypackage` next to the FBX zip), so this
   needs WP7's product key — the same dependency Phase A has.
6. **The texture bytes are in there too.** 23 `.png` in PolygonTown. Prefer the
   texture from the model's own FBX container when it exists; fall back to the one
   inside the `.unitypackage` only if it does not, and note in the UI that it came
   from the Unity build.

**Tests.** A committed fixture `.unitypackage` built by hand — a gzipped tar with
three GUID directories (one prefab, one material, one texture), a few hundred
bytes. Assert: the map is read from directory names and `pathname`; the chain
resolves; an `asset` seen before its `pathname` still resolves; a package with no
prefabs answers nothing rather than throwing.

**Acceptance, by eye.** A PolygonTown character (`Character_Father_01`) and an
AncientEmpire character draw textured through tier 1, and the panel says
*from the pack's prefab*. Neither pack has a `.zip` Unity build, so before Phase B
both draw flat.

### Tests (new `test/inferred_texture_test.dart`)

Tier 3, with a fake catalog shaped like a real pack — `Textures/Pack_Texture_01_A.png`,
`Textures/Alts/Pack_Texture_01_B.png`, `Textures/Pack_Emissive_01.png`,
`Textures/Pack_Signs_Texture_01_A.png`, `Textures/FX_Textures/Explosion.png`:

- picks `Pack_Texture_01_A.png`; same answer with the list reversed and shuffled.
- A pack whose only atlas is `PolygonNature_01.png` (no `texture` in the name) still
  resolves it. **This is the Nature miss — it must fail before the fix.**
- A pack with `Signs.png`, `NeonSigns.png`, `Billboards.png` and no name sharing the
  product name answers **nothing**.
- A model that names a texture which does not resolve gets nothing.
- A mesh with no UVs gets nothing.
- A model in container A never receives a texture from container B.
- A hand-picked texture wins; "None" gives flat colour.

Tiers 1 and 2, with committed fixtures — a tiny `.prefab`, `.mat` and two `.meta`
files under `test/fixtures/` (they are small text files; write them by hand from the
shapes in Appendix B):

- The prefab's material resolves to its `_MainTex` and that wins over tier 3.
- A prefab naming a material with no `_MainTex` falls through to tier 2.
- Tier 2 with one texture on 9 of 10 prefabs answers it; on 1 of 10, answers nothing.
- Stem matching: `SM_Chr_X_01.prefab` matches `SK_Chr_X_01.fbx`.

Widget: the picker reads `Texture: from the pack's prefab — …` for tier 1 and
`Texture: guessed — …` for tier 3.

### Acceptance, by eye

1. The War Robot draws with `PolygonSciFiSpace_Texture_01_A.png` via **tier 1**, and
   looks like a robot rather than a scramble of colour.
2. The other 19 matched characters in that pack also draw textured.
3. `SK_Chr_SpaceSoldier_Female.fbx` (no prefab) draws via **tier 2**, same atlas.
4. Three Kenney models that were flat-colour before look the same or better.
5. A SciFiCity prop still draws flat — tier 2 and tier 3 both decline, by design.
   If it picks `Signs.png`, the dominance guard is wrong; fix it.

---

## WP7 — Twins: one model in several formats (item 5) · M–L

### What the library looks like (Verified)

| | Count |
|---|---|
| `.uasset` files | 120,481 (48,282 distinct names) |
| `.uasset` names that also exist as an FBX or OBJ | 15,928 |
| `.uasset` files those names cover | **67,999 (56%)** |
| …of those names, model and uasset in the same *product* | 14,586 |
| Names that exist as both FBX and OBJ | 15,877 |
| DAE files with a same-name FBX/OBJ in the same pack | 3,045 of 3,045 |
| glTF files, likewise | 316 of 316 |
| GLB files, likewise | 2,843 of 3,035 (the other 192 are KayKit Dungeon) |

The remaining uassets are textures (`T_`, 13,965), materials (`MI_`, `M_`),
blueprints (`BP_`), physics assets and skeletons. They are not models and will
never pair with one. That is correct, not a failure.

### Design

A **twin key** per asset: `productKey + '|' + stem`.

- **stem** — the file name without its extension, lower-cased.
- **productKey** — the container's name reduced to the words that identify the
  product, so the FBX zip and the seven Unreal zips of one pack agree. Take the
  container name (the zip's file name, or the top folder — the last segment of
  `assetContainerKey`), lower-case it, and remove: a `.zip` ending; the words
  `sourcefiles`, `source_files`, `source`, `unreal`, `unity`, `ue4`, `ue5`,
  `project`; version runs such as `v4`, `_4_19`, `5_0_v1_14_0`, `(1)`; four-digit
  years. Then drop everything that is not a letter.

These must all reduce to `polygonscifispace` — put them in the test:

- `POLYGON_SciFiSpace_SourceFiles.zip`
- `POLYGON_SciFiSpace_Unreal_4_19.zip`
- `POLYGON_SciFi_Space_Unreal_4_25_v1_13.zip`
- `POLYGON_SciFi_Space_Unreal_5_4_v1_14_0.zip`

Two strengths of match, shown differently and never mixed:

- **Same model** — equal twin key.
- **Possibly the same model** — equal stem, different product key, **and** the stem
  occurs under exactly one product on the model side, **and** the stem is at least
  8 characters and contains an underscore. (Guards against `pipe_end` in a Kenney
  kit matching an unrelated `pipe_end.uasset`. Real example of what this tier is
  for: `Polygon_Dungeons_Realms_SourceFiles` and an Unreal zip spelled
  `DungeonRealms` — same pack, product keys differ by one letter.)

Never pair:

- uassets whose stem ends `_physicsasset` or `_skeleton`;
- uassets whose stem starts `t_`, `m_`, `mi_`, `mat_`, `mf_`, `bp_`;
- across types: only `model` and `unreal` assets take part.

### The index

`Map<String twinKey, List<AssetItem>>`, built once per catalog revision — same
rule as everywhere: not in `build()`. It is ~480,000 rows, so measure the build
(env-gated benchmark, as in WP5). The stem and product key need string work per
asset; do it once and keep it, do not redo it per lookup.

### The panel

In `AssetDetailsPanel` (`main.dart:7315`), a section **"Same model, other
formats"**, shown only when there is at least one twin:

- One line per format: `FBX`, `OBJ`, `GLB`, `DAE`, `UASSET ×7`.
- One file in a format: the line is a link that selects it (`onActivateAsset`).
- Several (the seven Unreal versions): the line expands to list them by container
  name, each a link.
- Below it, when present: **"Possibly the same model"**, same layout, in grey.

### The preview

When the selected asset cannot be drawn but a twin can, draw the twin:

- Applies to `unreal` assets (replacing WP1's plain panel when a twin exists) and
  to model formats the importer cannot read (DAE, glTF, GLB until WP8).
- Preference: FBX, then OBJ, then STL. FBX first on purpose — the comment at
  `main.dart:12213` records that these packs' OBJ twins are in centimetres with
  nothing in the file to say so.
- Only "same model" twins. Never preview from a "possibly" twin.
- A banner across the top, always visible: `Showing the FBX twin: NAME. .uasset
  files can only be opened in Unreal Engine.`
- The details panel keeps describing the file that is actually selected — its own
  path, size and type. Only the picture is borrowed.

### Out of scope here (note them, do not build them)

- Collapsing twins into one row in the grid. It hides files and changes every
  count on screen. Propose it separately as a toggle.
- Reading inside a `.uasset` to learn its class. Names carry enough for now.
- Twins for textures (`T_Name.uasset` ↔ `Name.png`).
- Letting a twin inherit its sibling's tags or embedding — see WP9, where it is the
  most promising speed-up.

### Tests (new `test/twin_key_test.dart`)

- The four container names above share a product key.
- Two different packs do **not** share one (`POLYGON_SciFiSpace…` vs
  `POLYGON_SciFi_Horror…`).
- `SM_Prop_Crate_01.fbx`, `.obj` and `.uasset` in one product → one group of three.
- `SK_Chr_X_01_PhysicsAsset.uasset` and `T_Crate_01.uasset` join no group.
- The "possibly" tier: a unique long stem across two product keys → possible; a
  short stem (`pipe`) → nothing; a stem under two model-side products → nothing.
- The same groups when the input list is shuffled.
- Widget: selecting the `.uasset` shows the FBX's `ModelPreview` and the banner;
  the details panel still shows the `.uasset` path.
- Widget: a `.uasset` with no twin shows WP1's plain panel.

---

## WP8 — GLB and glTF; DAE skipped (item 7) · L

**`cgltf` approved by Mike on 2026-11-24.** Phase A may proceed without a further
dependency discussion. Two things the repo's contract still requires, and they are
part of this WP's scope: record the choice in `DECISIONS.md` (accepted: `cgltf`,
one MIT C header, no dependencies; rejected: Assimp, for size and build time —
see Phase B), and keep it vendored in-tree rather than fetched at build time.

### What reading these formats would actually add (Verified)

Every DAE (3,045) and every glTF (316) in the library has a same-name FBX or OBJ in
the same pack. So do 2,843 of the 3,035 GLB. After WP7 all of those already show a
picture through their twin. The files with **no** other copy are **192 GLB**, all
in `KayKit Dungeon Pack 1.0/Models`. The 2 `.blend` files need Blender and are out
of scope.

So the order below is by what it buys, not by file count.

### Phase A — GLB and glTF (approved — `cgltf` signed off 2026-11-24)

- **Library:** `cgltf` — one C header, MIT licence, no dependencies. Vendor it at
  `work/asset_atlas_native/windows/runner/third_party/cgltf/`, beside `ufbx`, and
  add it to the `asset_atlas_mesh_importer` target in
  `windows/runner/CMakeLists.txt` (line 42 onward shows how `ufbx` is wired).
- **Where the code goes:** `mesh_importer.cpp`. Choose the reader by the input's
  extension (the label passed with `--stdin`, or the file argument). **Print the
  same JSON the FBX path prints** — same keys, same shapes — so the Dart side needs
  no new decoder. Read the Dart decoder first to learn the exact shape; do not
  guess it from the C++.
- **Version 1 reads:** node transforms, positions, indices, normals, the first UV
  set, materials (`baseColorFactor`; `baseColorTexture`). A texture embedded in a
  GLB goes out through the same embedded-texture field the FBX path already uses
  (the Dart side handles `embeddedTextureBase64` near `main.dart:13565`).
- **Version 1 does not read:** skins, animations, morph targets, cameras, lights,
  Draco or meshopt compression. Print `"bones"` so the rig family is right
  (`none`/`other`), and fail with a clear message on a compressed file rather than
  drawing garbage.
- **A limit to state plainly:** a `.gltf` keeps its geometry in a separate `.bin`.
  Assets inside a zip reach the importer as bytes on stdin, with no folder to look
  in. So: `.glb` works everywhere; loose `.gltf` files on disk work (pass the path,
  let cgltf load the buffers); **`.gltf` inside a zip is not supported in version
  1** and keeps showing its twin.
- **Dart side — find every place that lists formats:**
  - `previewableModelExts` (`main.dart:8348`);
  - the zip guard in `_previewFor` (`main.dart:3500`), which names `obj`, `stl`,
    `fbx` explicitly;
  - the dispatch in `loadMesh` (`main.dart:13185`);
  - every `asset.ext == 'fbx'` in the classification path (`main.dart:644`, `:656`
    and inside `classifyFbxChunk`) and `ext = 'fbx'` in `backfill_rigs.py` — decide
    for each whether GLB should be included, and say which in the commit message.
- **Tests:** a small committed GLB fixture (a textured cube, a few KB) under
  `test/fixtures/`; importer test for the JSON; a render test that the cube draws
  with its texture; a test that a Draco file fails with the message.
- **Acceptance:** the 192 KayKit GLB files draw.

### Phase B — DAE: closed. Mike's decision, 2026-11-24: skip it

There is no small, sound COLLADA reader. The choices are Assimp (large — it would
several-fold the importer's size and build time — but reads DAE and much else) or a
hand-written reader over an XML library for the subset these kits use.

**Decided: not building it.** All 3,045 DAE files have a twin that already draws,
so a DAE reader would add no model Mike cannot already see. Do not write one, and
do not vendor Assimp for it. Record the rejection in `DECISIONS.md` with that
reason. The one condition that would reopen it: a DAE arrives in the library with
no FBX/OBJ twin — which WP7's twin index will make visible the moment it happens.

---

## WP9 — Tagging speed: measure, then modes (item 9) · M

### How many threads it uses today (Verified, from the code)

| Dial | Value | Where |
|---|---|---|
| Renders in flight ("lanes") | **4** | `VisualTagQueue.defaultRenderLanes`, `lib/visual_tag_queue.dart:84` |
| Model threads (onnxruntime intra-op) | **2** | `threads = 2`, `visual_tag_queue.dart:25`; `DEFAULT_THREADS = 2`, `work/atlas_mcp/atlas_embed.py:84` |
| onnxruntime inter-op threads | 1 | `atlas_embed.py:151` |
| Execution provider | CPU only | `atlas_embed.py:158` |
| Batch size | 8 | `visual_tag_queue.dart:26` |
| Pause between renders | 0 ms | `paceMs`, `visual_tag_queue.dart:27` |
| Image-decode pool in the worker | min(threads, 4) | `atlas_embed.py:242` |

The only dial exposed is the command-line flag `--tag-lanes=N` (1–32), parsed in
`parseStartupOptions`, `main.dart:45`. Nothing in the UI.

The machine: Xeon W-2155, **10 cores / 20 threads**; an RTX 2070 SUPER that
tagging does not use.

### Where the time goes (last measured in commit `a7dd221`, not today)

Mean per asset over 24 archive models:

| Stage | ms | Runs where |
|---|---|---|
| Importer subprocess | 131 | its own process — spreads across lanes |
| Build mesh (textures, relink) | 89 | **the UI isolate** — one at a time |
| Rasterise | 19 | a freshly spawned isolate per render |
| Encode PNG | 8 | the UI isolate |
| Decode importer JSON | 6 | the UI isolate |
| Find and inflate the zip entry | 6 | the UI isolate |
| **Total** | **258** | |

**Inferred:** about 110 ms of each asset is work on the one UI isolate, which
serialises it however many lanes run. That caps rendering near 9 assets a second,
and it is why commit `4451015` found that four lanes "do not help". The embedder is
recorded at 74 ms an image in batches of eight (`atlas_embed.py:53`), on two
threads — the same order of size, so it may be the limit instead. `tag_assets.py:17`
says 9 ms. The two notes disagree; **which stage is the limit today is Unknown.**

**A correction to an earlier estimate.** The "8–9 hours for 14,836 models" quoted
in earlier reports is stale. `tag_assets.py:20` records about 3.5 hours for 31,495
models, measured after the speed-ups above. By proportion that is roughly
**1.7 hours** for 14,836 (Inferred — measure it).

### Step 1 — measure before changing anything

This repo has a written history of wrong guesses about this exact job (six
hypotheses, five wrong — see the header of `test/render_stage_timing_test.dart`).
Do not add a seventh.

1. Add to `TagProgress` (`lib/visual_tagging.dart:33`) and to the strip
   (`VisualTaggingStrip`, `main.dart:8360`): assets per second over the last
   minute, and two running totals — milliseconds spent waiting on renders and
   milliseconds spent waiting on the worker's `images` reply (`_handOver`,
   `visual_tag_queue.dart:352`). Whichever total is larger is the limit.
2. Re-run `test/render_breakdown_test.dart` (env-gated; its header gives the
   command) for the stage table as of today. This is a test over a listed handful
   of assets, not a tagging run — it is fine to run any time.
3. Tag the **same 200 models** at each row of the table in step 2 and record assets
   per second and whether the window stays usable. Put the table in the commit
   message.

   **200, not 500, and scope it to one pack** — see §0.6. Four runs of 200 at
   today's ~0.5 assets/s is about 7 minutes each. Ask Mike before starting them,
   and run them when he says the machine is free. 200 is ample: the thing being
   measured is a steady rate, and the first ~20 assets are warm-up to discard.

### Step 2 — modes

One setting, four values. The numbers are starting points; replace them with what
step 1 measures, and delete any mode that measures no faster than the one below it.

| Mode | Lanes | Model threads | Pause | For |
|---|---|---|---|---|
| Quiet | 1 | 1 | 100 ms | working in Atlas while it tags |
| Balanced (default, = today) | 4 | 2 | 0 | — |
| Fast | 8 | 6 | 0 | machine otherwise idle |
| Overnight | 12 | 10 | 0 | nobody at the keyboard |

- A dropdown in the tagging strip (`VisualTaggingStrip`). If you use
  `ToggleButtons` instead, remember rule 8.
- Persist it in the `settings` table as `tagging.mode` (see how
  `animationCharacterKey` is read and written, `main.dart:14463` onward).
- Add `--tag-mode=quiet|balanced|fast|overnight` beside `--tag-lanes` in
  `parseStartupOptions`. An explicit `--tag-lanes` still wins. A bad value is
  ignored, like the existing flag (`test/startup_options_test.dart` has the pattern).
- Pass `threads` and `paceMs` where the queue is built (`main.dart:329`); today
  only `renderConcurrency` is passed.
- Changing mode during a run takes effect at the next batch — or simply say "takes
  effect on the next run" in the UI. Do not restart the worker mid-batch.
- Cap model threads at the physical core count (`Platform.numberOfProcessors ~/ 2`).

### Step 3 — structural speed-ups, in the order worth trying

Do not start any of these until step 1 says which stage is the limit.

1. **Embed once per twin group (needs WP7).** 15,877 model names exist as both FBX
   and OBJ, and each copy is rendered and embedded separately today — the existing
   de-duplication (`f856950`) groups byte-identical files, and an FBX and its OBJ
   are not byte-identical. Rendering one and storing its vector for the group could
   remove a large share of the queue. **How large is Unknown:** first count the
   untagged models that have an already-tagged twin. Caveat to settle first: the
   OBJ twin can render differently from the FBX (different units, sometimes no
   texture), so sharing a vector is a judgement call — bring Mike the count and
   three side-by-side pictures and let him decide.
2. **Raise model threads.** Free if the embedder is the limit. That is what the
   modes do; step 1 tells you if it matters.
3. **Reuse the raster isolate.** `renderAsset` calls `rasterizeSceneInIsolate`
   (`main.dart:17562`), which spawns an isolate for every picture. `RenderWorker`
   (added in `bd8e9a2`) keeps one alive. Each tagged asset is a new scene, so the
   scene still has to be sent; the saving is the spawn, a few ms of 19. Small.
4. **Move the mesh build off the UI isolate** — the real fix if rendering is the
   limit, and the big one. Blocker: `loadMesh` decodes textures with `dart:ui`
   (`decodeImage`, `imageFromRgba`), which only works on the UI isolate. It needs a
   pixels-only loading path that never makes a `ui.Image` (the texture cache
   already holds raw pixels — commit `a7dd221`). Size L, its own plan, its own
   approval.
5. **The GPU.** `onnxruntime-directml` could run the vision model on the RTX 2070.
   Two unknowns: whether the quantised model (`vision_model_bnb4.onnx`) runs on
   DirectML at all — `atlas_embed.py:55` records that a different quantisation had
   no CPU kernel — and whether the vectors come out equal enough to mix with the
   32,084 already stored. It is also a tooling install, which needs Mike's
   approval. Only worth it if step 1 says the embedder is the limit.

### Tests

- `startup_options_test.dart`: each `--tag-mode` value; a bad one ignored;
  `--tag-lanes` beats the mode.
- `visual_tag_queue_test.dart`: the queue passes the mode's `threads` to
  `startWorker` (the test seam is already there) and honours `paceMs`.
- `visual_tagging_strip_test.dart`: the dropdown shows the saved mode; changing it
  writes the setting.
- The existing queue tests — the ones guarding against double-counted batches and
  duplicate vectors — must pass **unedited** at 12 lanes. They exist because
  parallel lanes broke the count once before.

---

## Appendix A — Reproducing the measurements

All read-only. The catalog is opened with `mode=ro`; nothing below writes to it.

- **Catalog:** `%APPDATA%\com.example\asset_atlas_native\asset_atlas_native.db`.
  Python: `sqlite3.connect('file:///C:/Users/.../asset_atlas_native.db?mode=ro',
  uri=True)`. Table `catalog_assets`; the columns used here are `path`,
  `relative_path`, `name`, `ext`, `type`, `model_kind`, `rig_family`.
- **Importer:**
  `work\asset_atlas_native\build\windows\x64\runner\Release\asset_atlas_mesh_importer.exe`.
  For a file on disk: `--summary <path>`. For a zip entry, pipe the entry's bytes
  in: `--stdin --summary <label>`. The JSON has `boneNames`, `rigMarkers`,
  `materialNames`, `textureFiles`, `bones`, `faces`.
- **Catalog paths for zip entries** look like `zip:<zip path>::<entry path>`.
- Run any Python that reads asset files with `-I`.

Files used as fixtures above:

| What | Where |
|---|---|
| War Robot | `Z:\Assets\Synty\POLYGON_SciFiSpace_SourceFiles.zip` → `_SourceFiles/Characters/SK_Chr_BR_War_Robot_01.fbx` |
| The one sibling that names a texture | same zip → `_SourceFiles/Characters/SK_Chr_BR_EVA_Suit_01.fbx` |
| That texture | same zip → `_SourceFiles/Textures/PolygonSciFiSpace_Texture_01_A.png` |
| Sidekick clip (121 bones) | `Z:\Assets\Synty\ANIMATION_Base_Locomotion_SourceFiles_v3.zip` → `SourceFiles/Animations/Sidekick/Feminine/Idles/A_MOD_BL_Idle_Standing_Femn.fbx` |
| Polygon clip (52 bones) | same zip → `SourceFiles/Animations/Polygon/Feminine/Idle/A_Idle_Standing_Femn.fbx` |
| Reference characters | same zip → `SourceFiles/Character/PolygonSyntyCharacter.fbx`, `SidekickSyntyCharacter.fbx` |
| Dog mesh (82 bones) | `Z:\Assets\Synty\POLYGON_Dogs_SourceFiles_v1.zip` → `_SourceFiles/Models/Unity_SK_Animals_Dog_01.fbx` |
| Dog clip | same zip → `_SourceFiles/Animations/Actions_Sitting/_POLYGON_Dog_Action_Sitting_Bark.fbx` |
| Kenney clip (58 bones, lone `Hips`) | `Z:\Assets\Kenney GameAssets All-in-1\kenney-game-assets\3D assets\Animated Characters 1\Animations\idle.fbx` |
| Unity build with the authored chain | `Z:\Assets\Synty\PolygonSciFiSpace_Unity_2017_4.zip` |
| The robot's prefab | same zip → `PolygonSciFiSpace/Prefabs/Characters/SM_Chr_BR_War_Robot_01.prefab` |
| Its material | same zip → `PolygonSciFiSpace/Materials/PolygonScifiSpace_Material_01_A.mat` |
| `.unitypackage` the Phase B numbers came from | `Z:\Assets\Synty\POLYGONTown_Unity_2019_4_28.unitypackage` (26 MB) |
| The larger one | `Z:\Assets\Synty\POLYGON_AncientEmpire_Unity_2021_3_v1_5_1.unitypackage` (120 MB) |

The scripts that produced the numbers were throwaway and live in a temporary
folder that a reboot may clear. They are not needed to do the work; each
measurement is described well enough above to redo from the two tools listed, plus
Appendix B for the Unity chain.

## Appendix B — Reading Unity's authored material chain

Three plain-text file kinds inside a Unity pack, all YAML-ish. Everything WP6
tier 1 and tier 2 need is in these three patterns.

**A `.meta` file** sits beside every asset and carries that asset's GUID:

```yaml
fileFormatVersion: 2
guid: 4cee7a5983b187943adc589b9cb1f084
```

So `Foo.mat.meta` holding that GUID means GUID → `Foo.mat`. Strip the trailing
`.meta` from the file's own path to get the asset it describes. Pattern:
`guid: ([0-9a-f]{32})` — take the **first** match in the file.

**A `.mat` file** names its textures per shader slot:

```yaml
    - _MainTex:
        m_Texture: {fileID: 2800000, guid: 90d9a0a4d81e8744ca7e5fd2d5bc5c9b, type: 3}
        m_Scale: {x: 1, y: 1}
```

Pattern: `- _MainTex:\s*\n\s*m_Texture: \{fileID: \d+(?:, guid: ([0-9a-f]{32}))?`
— the GUID group is **absent when no texture is assigned**, which is a real case
(`PolygonScifiSpace_Material_Glass.mat`), so handle a null group. `_EmissionMap`
works the same way if the emissive is ever wanted.

**A `.prefab`** references its material(s) by GUID anywhere in the file; collect
every `guid: ([0-9a-f]{32})` in it and keep the ones whose resolved path ends
`.mat`. A prefab typically references two: its mesh's FBX and its material.

Worked example, all four steps, verified on 2026-11-24:

```
SM_Chr_BR_War_Robot_01.prefab
  guid 4cee7a5983b187943adc589b9cb1f084  → PolygonScifiSpace_Material_01_A.mat
  guid 44202c79934aa8c45b2495a49b6e99b1  → Models/BR_Characters.fbx   (the mesh — ignore)
PolygonScifiSpace_Material_01_A.mat
  _MainTex → PolygonSciFiSpace/Textures/PolygonSciFiSpace_Texture_01_A.png
```

Notes that cost time to find out:

- The prefab's mesh reference points at the **Unity** pack's own FBX
  (`Models/BR_Characters.fbx`, a combined file), not at the SourceFiles FBX. So the
  model→prefab link must be made by **stem**, not by following that reference:
  lower-case and strip a leading `SM_` or `SK_`. 614 of 667 match that way.
- Counting which texture a pack "mostly uses" must count **prefabs**, not
  materials. Counting materials gave `PolygonSciFiSpace_Texture_01_B.png`, which is
  an `Alts/` palette variant used by a handful of props; counting prefabs gives
  `_01_A` with 544 of 662, which is the right answer and the one the robot uses.
- Material and texture file names do not always share the pack's spelling:
  `PolygonScifiSpace_Material_01_A.mat` (lower-case `f`) assigns
  `PolygonSciFiSpace_Texture_01_A.png` (upper-case `F`). Compare case-insensitively.

### The same chain inside a `.unitypackage`

Same three file kinds, different container, and the GUID map comes for free.

A `.unitypackage` is a **gzipped tar**, one directory per asset, the directory
*named by the GUID*:

```
001714447b764f24b9bd5b22a78b0c63/asset        <- the file's bytes
001714447b764f24b9bd5b22a78b0c63/asset.meta   <- Unity import settings
001714447b764f24b9bd5b22a78b0c63/pathname     <- "Assets/PolygonTown/Models/Props/SM_Prop_Streetlamp_02.fbx"
```

So `{guid: path}` is built from the directory names plus the one-line `pathname`
files; no `.meta` parsing. The `.mat` and `.prefab` bytes are read from `asset`,
and the `_MainTex` regex and prefab-GUID scan above are unchanged.

Notes that cost time to find out:

- **No random access.** A gzipped tar has no central directory, so it must be
  walked front to back. Python: `tarfile.open(path, "r|gz")` — the `|` is the
  streaming form and it refuses to seek backwards, which is the point.
- **Order is not guaranteed.** An `asset` entry can appear before the `pathname`
  that names it, so a reader must hold small unknown bytes briefly.
- **An entry name tells you nothing.** `.../asset` has no extension; anything
  keyed off the entry's name — including Atlas's own `typeForExt` — sees a file of
  type `other` and skips it.
- Verified timing: 0.7 s for a 26 MB package, 1.5 s for 120 MB, single-threaded,
  on this machine.

## Appendix C — Open items this plan touches but does not solve

- **No full tagging or embedding run — see §0.6.** Mike is using the machine.
  Small scoped passes only, and ask first.
- **Stale embeddings.** WP6 changes what ~14% of FBX models look like. Their
  stored vectors, and those of the ~4,900 OBJ files that gained colours in
  `64dc287`, were computed from the old picture. The queue skips anything already
  embedded; a `--force` option does not exist. It needs its own small task — and
  then a run, which is held.
- **14,836 models are still untagged.** Unblocked by none of this, sped up by WP9,
  held by §0.6.
- ~~Who runs the catalog rewrites.~~ Answered 2026-11-24: Claude runs them once
  the code is right, and tells Mike. Conditions in §0.3.
- **Browsing the Unity builds as assets.** WP6 Phase B reads `.unitypackage` as a
  sidecar, on demand. Indexing their contents as catalog rows is a different,
  larger decision (each row's name would have to come from `pathname`, not from
  the tar entry) and nobody has asked for it.
- **Grid collapsing of twins** (WP7) is deliberately deferred. **DAE** is not
  deferred — it is closed; see WP8 Phase B.
