# TASK-05 — Stop re-importing FBX on every rebuild

**Stage 2 · Size M · No dependencies · Biggest perceived-performance win**

## Problem

Selecting an FBX makes the app launch a subprocess and parse the whole mesh. That is by design. Doing
it dozens of times per second is not.

### 5a. Diagnostics re-imports on every rebuild

`ModelTextureDiagnostics` (`lib/main.dart` ~L2508) is a `StatelessWidget`, and its `build()` creates
the future inline:

```dart
return FutureBuilder<List<TextureDiscoveryEntry>>(
  future: loadModelTextureReferenceEntries(asset, allAssets),   // <-- new future every build
```

`loadModelTextureReferenceEntries()` calls `importFbxWithUfbx()` — process spawn, full mesh JSON,
texture decode. A `FutureBuilder` given a fresh future rebuilds from scratch every time, so **every**
rebuild of the details panel re-runs the import. The details panel rebuilds whenever
`_CatalogScreenState` calls `setState`: every keystroke in search, every checkbox, every pixel of a
splitter drag, every status update.

`ModelPreview` separately imports the same file for the mesh, so selecting one model parses it at
least twice before anyone touches anything.

### 5b. The texture filter imports the entire catalog

`_validateModelTexture()` (~L330) answers a boolean — "does this model have usable textures?" — like
this:

```dart
final refs = await loadModelTextureReferences(asset, assets);
hasValidTexture = refs.any((value) => value.contains('(found)'));
```

That is a full FBX import per model, run sequentially over every model in the catalog when the
"missing textures" filter is on, on the UI isolate — and the answer is recovered by substring-matching
a human-readable label built for display. Rewording that label silently changes program behaviour.

### 5c. ZIP image previews re-inflate on every rebuild

Same inline-future pattern in `_PreviewPanelState._previewFor` (~L1494):
`FutureBuilder(future: readZipVirtualAssetBytesByPath(item.path))`. Each rebuild re-reads and
re-inflates the archive entry.

## Required behaviour

- Importing a given FBX yields at most **one** helper invocation while the selection and catalog are
  unchanged. Rebuilds caused by unrelated UI state must not trigger any import.
- The texture-validity boolean is derived from resolver results, not from display strings.
- Cached results are invalidated when the asset changes (different asset id) or the catalog is
  re-scanned.
- ZIP byte reads for the image preview are not repeated per rebuild.

## Implementation notes

### Step 1 — an import cache

Add a small top-level cache keyed by asset id (public, so tests can clear it):

```dart
class FbxImportCache {
  static final _entries = <String, Future<MeshModel>>{};

  static Future<MeshModel> importFor(AssetItem asset, List<AssetItem> allAssets, {int checkerSize = 16}) { ... }
  static void invalidate(String assetId) { ... }
  static void clear() { ... }
}
```

Notes:
- Cache the **`Future`**, not the resolved value — two widgets asking during the same frame then
  share one in-flight import instead of racing two subprocesses.
- Bound it (an LRU of ~8 entries, mirroring `maxZipArchiveCacheEntries`) — a `MeshModel` holds decoded
  `ui.Image` textures and is not small.
- `_CatalogScreenState.scanFolder()` and `removeSource()` must call `FbxImportCache.clear()`, since
  relink results depend on the catalog contents.
- The `checkerSquareSize` fallback option changes the produced mesh — include it in the cache key or
  invalidate when it changes (`ModelPreview` already reloads on that dropdown).

### Step 2 — structured texture-reference results

`loadModelTextureReferenceEntries()` currently bakes `(found)` / `(missing)` into `label`. Add the
fact as a field instead:

```dart
class TextureDiscoveryEntry {
  const TextureDiscoveryEntry({
    required this.label,
    required this.copyPath,
    required this.resolved,   // <-- new: bool
    this.jumpAsset,
  });
```

Keep `label` for display, but let it be *built from* `resolved` rather than parsed for it. Then:

```dart
hasValidTexture = entries.any((entry) => entry.resolved);
```

No `.contains('(found)')` may remain in the codebase.

### Step 3 — hold the future in state

Convert `ModelTextureDiagnostics` to a `StatefulWidget` that creates its future in `initState` and
re-creates it in `didUpdateWidget` **only** when `widget.asset.id` changes (or the catalog identity
changes — see the note below). Apply the same treatment to the ZIP image preview in `PreviewPanel`.

Note on the existing `didUpdateWidget` check in `ModelPreview`:

```dart
oldWidget.allAssets.length != widget.allAssets.length
```

Comparing lengths misses same-size catalog changes. Prefer an explicit catalog revision counter — an
`int` on `_CatalogScreenState` incremented on every scan/removeSource — passed down and compared.
That is cheap, exact, and removes the heuristic.

### Step 4 — make validation cheaper still

With the cache in place, `_validateModelTexture` will reuse imports rather than re-running them, but
it still walks the whole catalog serially. Two cheap improvements, both in scope:

- Cap concurrency at 2–3 in-flight validations (a simple counter around the existing queue) rather
  than strictly one at a time.
- Skip validation entirely for models whose entry is already in `modelHasValidTextures`.

Leave the queue on the UI isolate — moving it off is the separate isolates work.

## Tests

- **Import happens once** (`test/fbx_import_cache_test.dart`): call `FbxImportCache.importFor` twice
  for the same asset and assert the second returns the identical `Future`/instance. Guard the
  native-helper part with the existing `helper.existsSync()` skip pattern, or test the cache with a
  stubbed loader if you extract the import call behind a function reference.
- **Invalidation**: after `clear()`, a subsequent call produces a new future.
- **Resolved flag** (`test/fbx_texture_pipeline_test.dart`): assert `TextureDiscoveryEntry.resolved`
  is true for a texture that exists next to the model and false for a dangling reference — using the
  synthetic-JSON path already established in that file, so no helper build is needed.
- **Widget rebuild does not re-import**: in a widget test, pump a `ModelTextureDiagnostics`, trigger
  several unrelated rebuilds, and assert the import counter (a test-visible counter on the cache)
  incremented exactly once.

## Acceptance criteria

- [ ] Typing in the search box with an FBX selected launches zero new helper processes (verify with
      Task Manager or by watching `logs/asset_atlas_fbx.log` stop growing).
- [ ] Selecting an FBX produces one import, not two.
- [ ] `.contains('(found)')` no longer appears in the codebase.
- [ ] Cache is cleared on re-scan and on source removal.
- [ ] `flutter analyze` clean, `flutter test` green.

## Out of scope

- Moving imports to a background isolate.
- Changing the importer protocol.
- Reworking the diagnostics panel's visual design.
