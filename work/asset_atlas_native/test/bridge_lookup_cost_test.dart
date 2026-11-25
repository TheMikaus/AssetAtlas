@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:asset_atlas_native/main.dart';

/// What naming an asset costs the bridge, both ways, against the real
/// catalog.
///
/// Every tool the MCP serves out of Atlas starts here: inspect_model,
/// rig_compatibility and render_asset each take a path and have to turn it
/// into an asset. That was a walk of all 221,183 assets normalizing each path
/// as it went, and a tagging pass makes the call once per asset.
///
/// Both the walk and the index are measured in one process against identical
/// data, because a figure for one without the other is not a comparison.
/// It also measures the miss, which runs two further walks the index does not
/// replace -- a consumer that guesses a path pays that, and knowing whether
/// it matters is the point of measuring rather than assuming.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=<a copy of asset_atlas_native.db> \
///     flutter test test/bridge_lookup_cost_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' && dbPath != null;

  test('naming an asset, before and after', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      dbPath!,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await database.rawQuery(
      'select id, name, path, relative_path, source_root, source_name, ext, '
      'type, size, modified_ms from catalog_assets',
    );
    final catalog = [
      for (final row in rows)
        AssetItem(
          // The real id, not the path: the lookup accepts both and they are
          // different strings, so substituting one hides half the question.
          id: (row['id'] as String?) ?? (row['path'] as String),
          name: row['name'] as String,
          path: row['path'] as String,
          relativePath: (row['relative_path'] as String?) ?? '',
          sourceRoot: (row['source_root'] as String?) ?? '',
          sourceName: (row['source_name'] as String?) ?? '',
          ext: ((row['ext'] as String?) ?? '').toLowerCase(),
          type: (row['type'] as String?) ?? '',
          size: (row['size'] as int?) ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch(
            (row['modified_ms'] as int?) ?? 0,
          ),
          tags: const [],
        ),
    ];
    await database.close();

    expect(catalog.length, greaterThan(1000), reason: 'that is not the real catalog');

    // Spread through the catalog rather than taken from the front: the walk
    // returns early, so where an asset sits is most of what it costs.
    final sample = <AssetItem>[];
    final step = catalog.length ~/ 40;
    for (var index = 0; index < catalog.length; index += step) {
      sample.add(catalog[index]);
    }

    double timeOf(void Function() work) {
      final started = Stopwatch()..start();
      work();
      return started.elapsedMicroseconds / 1000.0;
    }

    // Warm both paths once, so neither pays for the other's first call.
    bridgeFindAsset(sample.first.path, catalog, byScan: true);
    bridgeFindAsset(sample.first.path, catalog);

    final scanned = timeOf(() {
      for (final asset in sample) {
        bridgeFindAsset(asset.path, catalog, byScan: true);
      }
    });
    final indexed = timeOf(() {
      for (final asset in sample) {
        bridgeFindAsset(asset.path, catalog);
      }
    });

    // The maps are built on the first call and kept; a consumer's first
    // question pays for them and every later one does not. During a tagging
    // pass even that is already paid, because the render path builds the
    // path map itself.
    _dropCachedIndexes(catalog);
    final built = timeOf(() => bridgeFindAsset(sample.first.path, catalog));

    var misses = 0.0;
    for (final needle in ['SM_NothingLikeThis_01.fbx', 'not/a/path.fbx']) {
      misses += timeOf(() {
        try {
          bridgeFindAsset(needle, catalog);
        } on BridgeRequestException {
          misses += 0;
        }
      });
    }

    stdout.writeln('');
    stdout.writeln('  catalog                      ${catalog.length} assets');
    stdout.writeln('  sampled                      ${sample.length} lookups');
    stdout.writeln(
      '  by scan                      ${(scanned / sample.length).toStringAsFixed(1)} ms each',
    );
    stdout.writeln(
      '  indexed                      ${(indexed / sample.length).toStringAsFixed(3)} ms each',
    );
    stdout.writeln(
      '  building the index           ${built.toStringAsFixed(0)} ms, once per catalog',
    );
    stdout.writeln(
      '  a miss (two more walks)      ${(misses / 2).toStringAsFixed(1)} ms each',
    );

    expect(indexed, lessThan(scanned), reason: 'the index is not helping');
  }, skip: enabled ? null : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB', timeout: const Timeout(Duration(minutes: 10)));
}

/// Forces the maps to be rebuilt, so building them can be timed on its own.
///
/// Both are cached on the identity and length of the list they were built
/// from, so asking about a different list is what drops them.
void _dropCachedIndexes(List<AssetItem> assets) {
  try {
    bridgeFindAsset(assets.first.path, [assets.first]);
  } on BridgeRequestException {
    // Nothing to do: the call is for its side effect on the caches.
  }
}
