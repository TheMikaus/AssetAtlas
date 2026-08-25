# TASK-07 — Incremental catalog persistence

**Stage 2 · Size M · No dependencies · Prerequisite for TASK-08**

## Problem

`AssetAtlasDatabase.saveCatalog()` (`lib/main.dart` ~L4589) is the only write path for the catalog,
and it is a full rewrite:

```dart
await db.transaction((txn) async {
  await txn.delete('catalog_assets');
  await txn.delete('catalog_sources');
  for (final rootPath in sourceRoots) { await txn.insert(...); }
  for (final asset in assets) { await txn.insert('catalog_assets', {...}); }
});
```

Callers:

- `scanFolder()` — reasonable, the catalog really did change wholesale;
- `removeSource()` — fire-and-forget;
- **`setIgnored()`** — fire-and-forget, on **every checkbox click**. Ticking "ignore" on one asset in
  a 100k-asset catalog deletes 100k rows and re-inserts them one statement at a time.

Additional issues in the same layer:

- No `Batch` — every insert is a separate round trip through the FFI layer.
- No indexes on `catalog_assets`; `source_root` and `type` are filtered in Dart after loading
  everything.
- `onCreate` declares schema `version: 1` with **no `onUpgrade`**. Any future column addition has no
  migration path. (TASK-08 needs one — this task lays the groundwork.)
- Writes are fired with `unawaited(...)`, so two rapid toggles can overlap; sqflite serializes
  transactions, but the app has no idea whether a write succeeded, and a failure is silent.

## Required behaviour

- Toggling one asset's `ignored` flag writes **one row**, not the whole table.
- Bulk operations (scan complete, source removed) use a batch, not per-row inserts.
- The schema has a working `onUpgrade` path, exercised by a test.
- Write failures surface to the UI instead of vanishing.

## Implementation notes

### Step 1 — targeted updates

Add to `AssetAtlasDatabase`:

```dart
Future<void> updateAssetIgnored({required String assetId, required bool ignored});
Future<void> deleteAssetsForSourceRoot(String rootPath);
Future<void> upsertAssets(List<AssetItem> assets);      // batch
Future<void> replaceSourceRoots(List<String> rootPaths); // small, full replace is fine
```

Point `_CatalogScreenState.setIgnored()` at `updateAssetIgnored` and `removeSource()` at
`deleteAssetsForSourceRoot` + `replaceSourceRoots`. Keep `saveCatalog()` for the post-scan path, but
implement it with a batch.

### Step 2 — batching

```dart
final batch = txn.batch();
for (final asset in assets) {
  batch.insert('catalog_assets', _rowFor(asset),
      conflictAlgorithm: ConflictAlgorithm.replace);
}
await batch.commit(noResult: true);
```

`noResult: true` matters — collecting results for 100k inserts allocates a list you never read.
Factor the row-map construction into a private helper used by both paths so the column list exists
once.

### Step 3 — schema version 2 with a real migration

Bump `version: 1` → `2` and add:

```dart
onUpgrade: (db, oldVersion, newVersion) async {
  if (oldVersion < 2) {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_catalog_assets_source_root ON catalog_assets(source_root)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_catalog_assets_type ON catalog_assets(type)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_project_assets_project ON project_assets(project_id)');
  }
},
```

Create the same indexes in `onCreate` so fresh installs and upgraded installs converge on an
identical schema. Verify that convergence in a test — divergence between the two paths is the classic
migration bug.

### Step 4 — surface failures

Give the persistence calls in `_CatalogScreenState` a `try/catch` that sets
`status = ScanStatus('Save failed', error.toString())`. Do not swallow. The existing `unawaited(...)`
calls can keep their fire-and-forget shape as long as the future has its own error handling attached.

## Tests

New file `test/database_test.dart`. `sqflite_common_ffi` runs fine in tests — initialise with
`sqfliteFfiInit()` and open a database under `Directory.systemTemp.createTemp()`, tearing it down
afterwards. This will require `AssetAtlasDatabase` to accept an explicit path or factory rather than
always using `getApplicationSupportDirectory()`; add an optional named parameter to `initialize()`
for that (test seam, default behaviour unchanged).

- `updateAssetIgnored` flips one row and leaves the others byte-identical (read all rows before and
  after and compare).
- `upsertAssets` on an existing id replaces rather than duplicates (assert row count).
- `deleteAssetsForSourceRoot` removes only that root's rows.
- Round trip: save a catalog with tags, unicode names, and a ZIP virtual path; reload; assert
  equality field by field.
- **Migration**: create a database at version 1 using the old `onCreate` DDL (paste it into the test
  as a fixture), open it through `AssetAtlasDatabase`, assert the upgrade ran, the indexes exist
  (`PRAGMA index_list`), and pre-existing rows survived.
- **Schema convergence**: open a fresh v2 database and an upgraded v1 database; assert
  `PRAGMA table_info` and `PRAGMA index_list` match for every table.

## Acceptance criteria

- [ ] Toggling `ignored` issues a single-row UPDATE (verify by logging SQL or by timing a 10k-asset
      catalog before/after — put the numbers in the PR).
- [ ] No per-row `insert` loop remains in the bulk paths.
- [ ] `onUpgrade` exists, is tested, and converges with `onCreate`.
- [ ] Persistence failures set a visible status.
- [ ] `flutter analyze` clean, `flutter test` green.

## Out of scope

- Changing the asset id format (that is TASK-08 — this task must land first).
- Moving persistence off the UI isolate.
- Incremental re-scan / change detection.
