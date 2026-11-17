@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:asset_atlas_native/main.dart';

/// What relinking one texture reference costs against the real catalog, both
/// ways.
///
/// The synthetic benchmark beside this one was misleading: it gave every
/// asset the same source root and made a fifth of them textures, so the
/// model's own container held 44,000 candidates. The real catalog holds
/// 221,183 assets under one source root, of which 173,121 sit in 341
/// archives and only 19,200 are loose textures. Those two shapes pay for
/// completely different things, so the measurement has to use the real one.
///
/// `byScan: true` runs the walk this change replaced, so before and after are
/// measured in one process against identical data.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=<a copy of asset_atlas_native.db> \
///     flutter test test/relink_real_catalog_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' && dbPath != null;

  test('relinking one reference, before and after', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      dbPath!,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await database.rawQuery(
      'select name, path, relative_path, source_root, source_name, ext, '
      'type, size, modified_ms from catalog_assets',
    );
    final catalog = [
      for (final row in rows)
        AssetItem(
          id: row['path'] as String,
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

    const modelExts = {'fbx', 'obj', 'gltf', 'glb'};
    final zipModels = [
      for (final asset in catalog)
        if (isZipVirtualPath(asset.path) && modelExts.contains(asset.ext))
          asset.path,
    ];
    final looseModels = [
      for (final asset in catalog)
        if (!isZipVirtualPath(asset.path) && modelExts.contains(asset.ext))
          asset.path,
    ];

    stdout.writeln('');
    stdout.writeln('catalog ${catalog.length} assets, '
        '${zipModels.length} models in archives, '
        '${looseModels.length} loose models');

    /// Times [models] spread evenly across the list, one reference each, so
    /// every call is a different model -- which is what a tagging run is and
    /// what the old cache, keyed on the model path, never got to reuse.
    double perModelMs(List<String> models, int samples, {required bool scan}) {
      if (models.isEmpty) return double.nan;
      final step = (models.length / samples).ceil();
      final clock = Stopwatch()..start();
      var counted = 0;
      for (var index = 0; index < models.length && counted < samples;
          index += step) {
        findDeterministicTextureRelink(
          models[index],
          'T_Missing_Reference_BC.tga',
          catalog,
          byScan: scan,
        );
        counted += 1;
      }
      clock.stop();
      return clock.elapsedMicroseconds / 1000.0 / counted;
    }

    stdout.writeln('');
    stdout.writeln('  milliseconds per model, one unresolved reference');
    stdout.writeln('  shape              by scan (before)   indexed (after)');
    for (final shape in [
      ('models in archives', zipModels, 60),
      ('loose models      ', looseModels, 20),
    ]) {
      final scanned = perModelMs(shape.$2, shape.$3, scan: true);
      final indexed = perModelMs(shape.$2, shape.$3, scan: false);
      stdout.writeln(
        '  ${shape.$1}'
        '${scanned.toStringAsFixed(1).padLeft(15)}'
        '${indexed.toStringAsFixed(1).padLeft(19)}',
      );
    }

    stdout.writeln('');
    stdout.writeln('The second column is the per-model cost of the change.');
    stdout.writeln('Loose models keep whatever the scoring of their own');
    stdout.writeln('container costs: all 19,200 loose textures share one');
    stdout.writeln('source root, so each reference scores every one of them.');
    expect(catalog, isNotEmpty);
  },
      skip: enabled
          ? null
          : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB to run this benchmark',
      timeout: const Timeout(Duration(minutes: 20)));
}
