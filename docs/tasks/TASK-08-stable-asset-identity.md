# TASK-08 — Stable asset identity + schema migration

**Stage 3 · Size L · Depends on TASK-07 · Pair with a senior**

## Problem

`AssetItem.id` encodes the file's mutable state:

```dart
id: '${entity.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
```

and for ZIP entries:

```dart
id: 'zip:${normalizePathKey(zipPath)}::$entryPath:${entry.size}:${zipModified.millisecondsSinceEpoch}',
```

So the identity of an asset changes whenever the file does. Edit a texture in Photoshop, re-scan, and:

- **Saved projects silently lose it.** `project_assets` stores the old id. `loadProjectSnapshot()`
  does `loadedAssetIds.where((id) => assets.any((asset) => asset.id == id))` — the stale id matches
  nothing and is dropped with no message. The user sees a project that quietly has fewer assets than
  they saved.
- **The ignore flag resets**, because `catalog_assets` is keyed by the same id.
- Re-touching a file (even without content change — a copy operation updates mtime) is enough to
  trigger this.

Editing assets is the normal state of a content pipeline, so the app forgets the user's curation
precisely when they are working hardest.

## Required behaviour

- An asset's identity is derived from **where it is**, not from what it currently contains:
  its source root plus its relative path, case-normalized for Windows.
- Size and modified time remain on `AssetItem` as *metadata* — they are shown in the details panel
  and are still refreshed on scan — but they no longer participate in identity.
- Existing databases migrate: previously saved projects and ignore flags survive the upgrade wherever
  the file is still at the same path.
- Re-scanning after a file edit preserves project membership and the ignore flag.

## Design

### New id format

```
asset:v2:<normalized source root>|<normalized relative path>
```

For ZIP entries:

```
asset:v2:<normalized source root>|<normalized zip relative path>!<normalized entry path>
```

Rules — write these down as a doc comment on the id builder, because everything downstream depends
on them:

- normalize separators to `/`;
- lowercase (Windows paths are case-insensitive; the app is Windows-first — note the tradeoff for a
  future Linux port in the comment);
- no trimming of Unicode, no hashing (a readable id is far easier to debug, and these strings are
  already stored in full elsewhere).

Add a top-level builder used by every construction site — there must be exactly one:

```dart
String buildAssetId({required String sourceRoot, required String relativePath});
```

### Migration (schema v2 → v3)

TASK-07 introduced `onUpgrade`. Add a `v3` step that rewrites ids in place:

1. Read every row of `catalog_assets` (old ids, but `source_root` and `relative_path` are already
   stored as columns — the migration needs no filesystem access).
2. Compute the new id for each row.
3. Build an old→new map.
4. Update `catalog_assets.id`, then `project_assets.asset_id` through the same map, inside **one
   transaction**.
5. Drop any `project_assets` row whose `asset_id` has no mapping (an asset that is already gone),
   and count them so the migration can log how many were dropped.

Note the ordering constraint: `project_assets` has no foreign key, so the update order does not
cascade, but doing both inside one transaction is required so a crash cannot leave the two tables
disagreeing.

`relative_path` is currently stored as `'$sourceName/$relativePath'` (the source folder's display
name is prefixed). Decide explicitly whether the id uses the prefixed or unprefixed form, use the
same choice in the scanner and the migration, and state the choice in the doc comment. The
unprefixed form is preferable — the prefix duplicates `source_root` and would change if a root
folder were renamed.

## Implementation notes

- Construction sites to update: `scanAssetFolder()` (~L3110), `scanZipAssetEntries()` (~L3210). Both
  must call the shared builder.
- `loadCatalog()` reads `id` straight from the row — no change needed once the data is migrated.
- Check for any place that *parses* an id rather than treating it as opaque. There should be none;
  confirm with a search for `.id` usages and fix anything that assumes structure.
- Duplicate-id risk: two source roots where one is nested inside the other will produce the same file
  under two ids. That is pre-existing behaviour and out of scope, but add an assertion or a log line
  if a duplicate id is inserted so it is visible if it happens.

## Tests

Extend `test/database_test.dart` (created in TASK-07) and add `test/asset_identity_test.dart`:

- **Builder**: same inputs → same id; separator and case variants of the same path → same id;
  different relative paths → different ids; ZIP form distinct from non-ZIP form.
- **Stability across content change** (the headline test — write it first, it fails today): scan a
  temp fixture tree, capture ids, modify a file's contents (changing size and mtime), re-scan, and
  assert the ids are unchanged.
- **Project membership survives an edit**: save a project containing that asset, modify the file,
  re-scan, load the project, assert the asset is still a member.
- **Ignore flag survives an edit**: same shape.
- **Migration**: build a v2 database populated with old-format ids and a project referencing them,
  open it through `AssetAtlasDatabase`, and assert every id is migrated, project membership is
  intact, and orphan rows were dropped and counted.
- **Idempotence**: running the upgrade against an already-migrated database is a no-op.

## Acceptance criteria

- [ ] Editing a file and re-scanning preserves project membership and ignore state — verified by
      test *and* by hand in the running app.
- [ ] Exactly one function builds asset ids.
- [ ] Migration is transactional, idempotent, and tested against a populated v2 database.
- [ ] A real user database (back one up first: `%APPDATA%/../Roaming/<app support>/asset_atlas_native.db`)
      opens correctly after the upgrade with its projects intact.
- [ ] `flutter analyze` clean, `flutter test` green.

## Out of scope

- Content hashing for duplicate detection across folders (interesting, separate feature).
- Tracking assets across renames or moves — a path change is still a new asset under this design.
  Say so in `USER_MANUAL.md`.
- Incremental re-scan.

## Risk note

This is the only task in the set that rewrites user data. Back up the development database before
testing, keep the migration in its own commit separate from the scanner change so it can be reverted
independently, and have the migration reviewed before merge.
