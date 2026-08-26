import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The v1 DDL, pasted as a fixture so the migration test can build a database
/// that predates the current schema.
const _v1Ddl = [
  '''
    CREATE TABLE catalog_assets (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      source_root TEXT NOT NULL,
      source_name TEXT NOT NULL,
      ext TEXT NOT NULL,
      type TEXT NOT NULL,
      size INTEGER NOT NULL,
      modified_ms INTEGER NOT NULL,
      tags_json TEXT NOT NULL,
      ignored INTEGER NOT NULL DEFAULT 0
    )
  ''',
  '''
    CREATE TABLE catalog_sources (
      root_path TEXT PRIMARY KEY
    )
  ''',
  '''
    CREATE TABLE projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      root_path TEXT,
      created_ms INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE project_assets (
      project_id TEXT NOT NULL,
      asset_id TEXT NOT NULL,
      PRIMARY KEY (project_id, asset_id)
    )
  ''',
];

AssetItem _asset(
  String id, {
  String name = 'albedo.png',
  String sourceRoot = r'C:\Packs\A',
  String type = 'image',
  bool ignored = false,
  List<String> tags = const ['image', 'png'],
}) {
  return AssetItem(
    id: id,
    name: name,
    path: '$sourceRoot\\$name',
    relativePath: 'A/$name',
    sourceRoot: sourceRoot,
    sourceName: 'A',
    ext: name.split('.').last,
    type: type,
    size: 123,
    modified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    tags: tags,
    ignored: ignored,
  );
}

Future<String> _freshDbPath(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    // Windows keeps the file locked, so the handle has to go first.
    await AssetAtlasDatabase.instance.close();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });
  return '${dir.path}${Platform.pathSeparator}asset_atlas_native.db';
}

/// Each test needs its own database; the production object is a singleton that
/// caches its handle, so reset it between tests.
Future<AssetAtlasDatabase> _openAt(String path) async {
  final db = AssetAtlasDatabase.instance;
  await db.close();
  await db.initialize(databasePath: path);
  return db;
}

Future<List<String>> _indexNames(Database raw, String table) async {
  final rows = await raw.rawQuery('PRAGMA index_list($table)');
  return rows.map((row) => row['name'] as String).where((name) {
    return !name.startsWith('sqlite_autoindex');
  }).toList()..sort();
}

Future<List<String>> _columnNames(Database raw, String table) async {
  final rows = await raw.rawQuery('PRAGMA table_info($table)');
  return rows.map((row) => row['name'] as String).toList()..sort();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await AssetAtlasDatabase.instance.close();
  });

  test('catalog round trips, including unicode and zip virtual paths', () async {
    final db = await _openAt(await _freshDbPath('asset_atlas_db_roundtrip_'));

    final zipVirtual = buildZipVirtualPath(
      r'C:\Packs\pack.zip',
      'Textures/Grün.png',
    );
    final assets = [
      _asset('a1', name: 'Matériau_Grün.png', tags: const ['image', 'grün']),
      AssetItem(
        id: 'a2',
        name: 'Grün.png',
        path: zipVirtual,
        relativePath: 'A/pack.zip!/Textures/Grün.png',
        sourceRoot: r'C:\Packs\A',
        sourceName: 'A',
        ext: 'png',
        type: 'image',
        size: 9,
        modified: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        tags: const ['image'],
        ignored: true,
      ),
    ];

    await db.saveCatalog(assets: assets, sourceRoots: [r'C:\Packs\A']);
    final restored = await db.loadCatalog();

    expect(restored.sourceRoots, {r'C:\Packs\A'});
    expect(restored.assets, hasLength(2));

    final byId = {for (final asset in restored.assets) asset.id: asset};
    expect(byId['a1']!.name, 'Matériau_Grün.png');
    expect(byId['a1']!.tags, ['image', 'grün']);
    expect(byId['a2']!.path, zipVirtual);
    expect(byId['a2']!.ignored, isTrue);
    expect(
      byId['a2']!.modified,
      DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  });

  test('updateAssetIgnored touches one row and leaves the rest alone', () async {
    final path = await _freshDbPath('asset_atlas_db_ignore_');
    final db = await _openAt(path);

    await db.saveCatalog(
      assets: [_asset('a1'), _asset('a2', name: 'normal.png'), _asset('a3')],
      sourceRoots: [r'C:\Packs\A'],
    );

    String describe(AssetItem asset) =>
        '${asset.id}|${asset.name}|${asset.path}|${asset.size}|'
        '${asset.modified.millisecondsSinceEpoch}|${asset.tags}|${asset.ignored}';

    final before = {
      for (final asset in (await db.loadCatalog()).assets)
        asset.id: describe(asset),
    };

    await db.updateAssetIgnored(assetId: 'a2', ignored: true);

    final after = {
      for (final asset in (await db.loadCatalog()).assets)
        asset.id: describe(asset),
    };

    expect(after.keys.toSet(), before.keys.toSet());
    for (final id in before.keys) {
      if (id == 'a2') {
        expect(before[id], contains('|false'));
        expect(after[id], contains('|true'));
      } else {
        expect(after[id], before[id], reason: 'untouched rows must not change');
      }
    }
  });

  test('upsertAssets replaces by id rather than duplicating', () async {
    final db = await _openAt(await _freshDbPath('asset_atlas_db_upsert_'));

    await db.saveCatalog(assets: [_asset('a1')], sourceRoots: const []);
    await db.upsertAssets([_asset('a1', name: 'renamed.png')]);

    final restored = await db.loadCatalog();
    expect(restored.assets, hasLength(1));
    expect(restored.assets.single.name, 'renamed.png');
  });

  test('deleteAssetsForSourceRoot removes only that root', () async {
    final db = await _openAt(await _freshDbPath('asset_atlas_db_delete_'));

    await db.saveCatalog(
      assets: [
        _asset('a1', sourceRoot: r'C:\Packs\A'),
        _asset('b1', sourceRoot: r'C:\Packs\B'),
      ],
      sourceRoots: [r'C:\Packs\A', r'C:\Packs\B'],
    );

    await db.deleteAssetsForSourceRoot(r'C:\Packs\A');
    final restored = await db.loadCatalog();

    expect(restored.assets.map((asset) => asset.id), ['b1']);
    expect(restored.sourceRoots, {r'C:\Packs\B'});
  });

  test('project membership survives a save/load cycle', () async {
    final db = await _openAt(await _freshDbPath('asset_atlas_db_project_'));

    await db.saveCatalog(
      assets: [_asset('a1'), _asset('a2')],
      sourceRoots: const [],
    );
    final projectId = await db.saveProject(
      name: 'Pass one',
      rootPath: r'C:\Packs\A',
      createdMs: 1700000000000,
    );
    await db.replaceProjectAssetIds(
      projectId: projectId,
      assetIds: ['a1', 'a2'],
    );

    expect(await db.loadProjectAssetIds(projectId), {'a1', 'a2'});

    await db.replaceProjectAssetIds(projectId: projectId, assetIds: ['a2']);
    expect(await db.loadProjectAssetIds(projectId), {'a2'});

    await db.deleteProject(projectId);
    expect(await db.listProjects(), isEmpty);
    expect(await db.loadProjectAssetIds(projectId), isEmpty);
  });

  group('migration', () {
    test('a v1 database upgrades, keeping its rows, and gains indexes', () async {
      final path = await _freshDbPath('asset_atlas_db_migrate_');

      // Build a v1 database by hand.
      final legacy = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final statement in _v1Ddl) {
              await db.execute(statement);
            }
          },
        ),
      );
      await legacy.insert('catalog_assets', {
        'id': 'legacy-1',
        'name': 'albedo.png',
        'path': r'C:\Packs\A\albedo.png',
        'relative_path': 'A/albedo.png',
        'source_root': r'C:\Packs\A',
        'source_name': 'A',
        'ext': 'png',
        'type': 'image',
        'size': 5,
        'modified_ms': 1700000000000,
        'tags_json': '["image"]',
        'ignored': 1,
      });
      await legacy.insert('projects', {
        'id': 'p1',
        'name': 'Legacy project',
        'root_path': r'C:\Packs\A',
        'created_ms': 1700000000000,
      });
      await legacy.insert('project_assets', {
        'project_id': 'p1',
        'asset_id': 'legacy-1',
      });
      expect(await legacy.getVersion(), 1);
      await legacy.close();

      // Open through the app: the upgrade runs.
      final db = await _openAt(path);
      final restored = await db.loadCatalog();
      expect(restored.assets, hasLength(1));
      expect(restored.assets.single.ignored, isTrue);
      expect(await db.loadProjectAssetIds('p1'), {'legacy-1'});
      await db.close();

      final raw = await databaseFactory.openDatabase(path);
      expect(await raw.getVersion(), AssetAtlasDatabase.schemaVersion);
      expect(
        await _indexNames(raw, 'catalog_assets'),
        containsAll(['idx_catalog_assets_source_root', 'idx_catalog_assets_type']),
      );
      expect(
        await _indexNames(raw, 'project_assets'),
        contains('idx_project_assets_project'),
      );
      await raw.close();
    });

    test('upgrading twice is a no-op', () async {
      final path = await _freshDbPath('asset_atlas_db_migrate_twice_');
      final legacy = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final statement in _v1Ddl) {
              await db.execute(statement);
            }
          },
        ),
      );
      await legacy.close();

      await (await _openAt(path)).close();
      // Second open must not throw on the already-created indexes.
      final db = await _openAt(path);
      expect((await db.loadCatalog()).assets, isEmpty);
    });

    test('a fresh v2 schema matches an upgraded v1 schema', () async {
      final freshPath = await _freshDbPath('asset_atlas_db_fresh_');
      await (await _openAt(freshPath)).close();

      final upgradedPath = await _freshDbPath('asset_atlas_db_upgraded_');
      final legacy = await databaseFactory.openDatabase(
        upgradedPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final statement in _v1Ddl) {
              await db.execute(statement);
            }
          },
        ),
      );
      await legacy.close();
      await (await _openAt(upgradedPath)).close();

      final fresh = await databaseFactory.openDatabase(freshPath);
      final upgraded = await databaseFactory.openDatabase(upgradedPath);
      const tables = [
        'catalog_assets',
        'catalog_sources',
        'projects',
        'project_assets',
      ];
      for (final table in tables) {
        expect(
          await _columnNames(upgraded, table),
          await _columnNames(fresh, table),
          reason: 'columns diverge for $table',
        );
        expect(
          await _indexNames(upgraded, table),
          await _indexNames(fresh, table),
          reason: 'indexes diverge for $table',
        );
      }
      await fresh.close();
      await upgraded.close();
    });
  });
}
