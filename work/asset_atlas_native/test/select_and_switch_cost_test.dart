@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What a 30-to-60 second stall in the window is made of.
///
/// Reported from the app: on All with `war_robot_01` in the filter, select
/// it, then switch to Character. The window froze for most of a minute.
/// Every candidate below runs on the UI thread, so any one of them would
/// show up exactly like that, and guessing which is pointless when the real
/// catalog is right there to measure against.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=`asset_atlas_native.db` \
///     flutter test test/select_and_switch_cost_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' && dbPath != null;

  test('selecting a uasset and switching to Character', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      dbPath!,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await database.rawQuery(
      'select id, name, path, relative_path, source_root, source_name, ext, '
      'type, size, modified_ms, ignored, model_kind, rig_family, '
      'rig_signature, referenced_by_model from catalog_assets',
    );
    final boneRows = await database.rawQuery(
      'select signature, bones_json from rig_bones',
    );
    await database.close();

    final catalog = [
      for (final row in rows)
        AssetItem(
          id: row['id'] as String,
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
          ignored: ((row['ignored'] as int?) ?? 0) != 0,
          modelKind: row['model_kind'] as String?,
          rigFamily: row['rig_family'] as String?,
          rigSignature: row['rig_signature'] as String?,
          referencedByModel: ((row['referenced_by_model'] as int?) ?? 0) != 0,
        ),
    ];
    final rigBones = <String, List<String>>{
      for (final row in boneRows)
        (row['signature'] as String): [
          for (final name in (row['bones_json'] as String)
              .replaceAll('[', '')
              .replaceAll(']', '')
              .split(','))
            name.trim().replaceAll('"', ''),
        ],
    };
    // ignore: avoid_print
    print('catalog ${catalog.length} assets, ${rigBones.length} rigs');

    int msOf(void Function() body) {
      final watch = Stopwatch()..start();
      body();
      return watch.elapsedMilliseconds;
    }

    // Each index is memoised per catalog, so the first caller pays for the
    // build and that first caller is whatever the user happened to click.
    resetTwinIndex();
    resetRigIndex();

    // ignore: avoid_print
    print('twinIndexFor build   ${msOf(() => twinIndexFor(catalog))} ms');
    // ignore: avoid_print
    print('rigIndexFor build    '
        '${msOf(() => rigIndexFor(catalog, rigBones))} ms');

    // What the index builds are actually made of, per asset.
    var eligible = 0;
    // ignore: avoid_print
    print('  twinEligible       ${msOf(() {
      for (final asset in catalog) {
        if (twinEligible(asset)) eligible += 1;
      }
    })} ms ($eligible eligible)');
    // ignore: avoid_print
    print('  parseZipVirtualPath ${msOf(() {
      for (final asset in catalog) {
        parseZipVirtualPath(asset.path);
      }
    })} ms');
    // ignore: avoid_print
    print('  containerDisplayName ${msOf(() {
      for (final asset in catalog) {
        containerDisplayName(asset);
      }
    })} ms');
    // ignore: avoid_print
    print('  normalizePathKey   ${msOf(() {
      for (final asset in catalog) {
        normalizePathKey(asset.path);
      }
    })} ms');

    final robot = catalog.firstWhere(
      (asset) =>
          asset.ext == 'uasset' &&
          asset.name.toLowerCase().contains('war_robot_01') &&
          asset.name.toLowerCase().startsWith('sk_'),
    );
    // ignore: avoid_print
    print('the row clicked      ${robot.path}');
    // ignore: avoid_print
    print('previewableTwinOf    '
        '${msOf(() => previewableTwinOf(robot, catalog))} ms');

    final twin = previewableTwinOf(robot, catalog);
    // ignore: avoid_print
    print('its twin             ${twin?.path}');

    if (twin != null) {
      final container = twin.path.startsWith('zip:')
          ? twin.path.substring(4).split('::').first
          : null;
      if (container != null && File(container).existsSync()) {
        resetUnityChainCache();
        // ignore: avoid_print
        print('readUnityTextureChain '
            '${msOf(() => readUnityTextureChain(container))} ms '
            '(${(File(container).lengthSync() / 1048576).round()} MB)');
      }
      // ignore: avoid_print
      print('findInferredTexture  '
          '${msOf(() => findInferredTexture(twin, catalog))} ms');
    }

    // The Character pass itself: every asset through the same two tests the
    // filter applies, with no query to narrow it first.
    var characters = 0;
    final filterMs = msOf(() {
      for (final asset in catalog) {
        if (asset.ignored) continue;
        if (!assetIsCharacterModel(asset)) continue;
        characters += 1;
      }
    });
    // ignore: avoid_print
    print('character predicate  $filterMs ms over ${catalog.length} '
        '($characters characters)');

    // The sort the list is filtered out of. Keyed on an epoch that several
    // things bump, so this is not a once-per-session cost.
    for (final mode in [AssetSortMode.path, AssetSortMode.name]) {
      // ignore: avoid_print
      print('sortAssets ${mode.name.padRight(9)} '
          '${msOf(() => sortAssets(catalog, mode))} ms');
    }

    // Both passes run on every build: one for the list, one for the "12 /
    // 300" denominator beside it.
    final queried = msOf(() {
      final parsed = parseAssetQuery('war_robot_01');
      for (final asset in catalog) {
        if (asset.ignored) continue;
        if (!assetIsCharacterModel(asset)) continue;
        assetMatchesQuery(parsed, asset.queryValue);
      }
    });
    // ignore: avoid_print
    print('with the query       $queried ms');

    // Collapsing runs at the end of each pass, so it is paid twice per
    // rebuild like the filter itself.
    CollapsedAssets? collapsed;
    final collapseMs = msOf(() {
      collapsed = collapseAssetVersions(catalog);
    });
    // ignore: avoid_print
    print('collapseAssetVersions $collapseMs ms: ${catalog.length} files to '
        '${collapsed!.rows.length} rows, ${collapsed!.membersById.length} '
        'of them standing for more than one');
    final second = msOf(() => collapseAssetVersions(catalog));
    // ignore: avoid_print
    print('  again, keys cached  $second ms');

    expect(catalog, isNotEmpty);
  }, skip: enabled ? false : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB');
}
