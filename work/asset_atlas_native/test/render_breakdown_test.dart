@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:asset_atlas_native/main.dart';

/// Every stage of one render, timed separately, against the real catalog.
///
/// Five hypotheses about the two seconds an asset costs have been wrong:
/// the importer subprocess (27 ms on an OBJ, 135 ms on real FBX), geometry
/// size (flat across four orders of magnitude), archive inflation (zip assets
/// were the faster group), embedded textures (real in one pack, absent from
/// the rest) and the relink walk (144 ms, not the 2,032 ms a badly shaped
/// synthetic benchmark reported). Each was retired by measurement, and each
/// time the measurement covered one stage rather than all of them.
///
/// So this times the whole sequence `loadMesh` actually performs, stage by
/// stage, on assets drawn from the catalog the way the tagging run met them:
/// consecutive models inside one archive, which is what the archive cache
/// sees during a run over a pack.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=<a copy of asset_atlas_native.db> \
///     flutter test test/render_breakdown_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' && dbPath != null;

  test('where one render spends its time', () async {
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

    // Consecutive FBX models per archive, which is the order a pass over a
    // pack meets them in and so the order the archive cache was built for.
    final perArchive = <String, List<AssetItem>>{};
    for (final asset in catalog) {
      if (asset.ext != 'fbx') continue;
      final zip = parseZipVirtualPath(asset.path);
      if (zip == null) continue;
      (perArchive[zip.zipPath] ??= <AssetItem>[]).add(asset);
    }
    final archives =
        perArchive.keys.where((key) => perArchive[key]!.length >= 12).toList()
          ..sort();
    expect(archives, isNotEmpty, reason: 'no archive has enough FBX models');

    const perArchiveSample = 12;
    final sample = <AssetItem>[];
    for (final archive in [
      archives.first,
      archives[archives.length ~/ 2],
      archives.last,
    ]) {
      sample.addAll(perArchive[archive]!.take(perArchiveSample));
    }

    final helper = meshImporterPath();
    expect(File(helper).existsSync(), isTrue, reason: 'importer missing');

    var inflate = 0.0;
    var importer = 0.0;
    var decodeJson = 0.0;
    var buildModel = 0.0;
    var raster = 0.0;
    var encode = 0.0;
    var firstInArchive = 0.0;
    var counted = 0;
    var jsonBytes = 0;
    final seenArchives = <String>{};

    stdout.writeln('');
    stdout.writeln('  inflate  import    json   model  raster  encode'
        '   total  jsonKB  name');

    for (final asset in sample) {
      final clock = Stopwatch()..start();
      try {
        // Stage 1: the archive. Opening it is once per archive; finding and
        // inflating the entry is once per asset.
        final bytes = await readZipVirtualAssetBytesByPath(asset.path);
        if (bytes == null || bytes.isEmpty) continue;
        final afterInflate = clock.elapsedMicroseconds / 1000.0;

        // Stage 2: the importer subprocess, fed the entry on stdin.
        final result = await runMeshImporter(
          helper,
          asset.path,
          inputBytes: bytes,
        );
        if (result.exitCode != 0) continue;
        final afterImporter = clock.elapsedMicroseconds / 1000.0;

        // Stage 3: parsing what it wrote.
        final decoded = jsonDecode(result.stdout) as Map<String, dynamic>;
        final afterJson = clock.elapsedMicroseconds / 1000.0;

        // Stage 4: building the mesh, which is where textures are resolved
        // against the catalog and decoded.
        final mesh = await meshModelFromImporterJson(
          decoded,
          modelPath: asset.path,
          name: asset.name,
          allAssets: catalog,
        );
        final afterModel = clock.elapsedMicroseconds / 1000.0;
        if (mesh.faces.isEmpty) continue;

        // Stage 5: the rasteriser, which has an isolate to itself.
        final image = await rasterizeSceneInIsolate(
          RasterRequest(
            scene: RasterScene.fromMesh(mesh),
            yaw: 0.6,
            pitch: 0.35,
            zoom: 1.0,
            width: 224,
            height: 224,
            renderMode: RenderMode.textured,
            lightingMode: LightingMode.corner,
            cullBackFaces: true,
          ),
        );
        final afterRaster = clock.elapsedMicroseconds / 1000.0;

        // Stage 6: PNG, which is what the embedder is handed.
        img.encodePng(
          img.Image.fromBytes(
            width: image.width,
            height: image.height,
            bytes: image.pixels.buffer,
            numChannels: 4,
          ),
        );
        final afterEncode = clock.elapsedMicroseconds / 1000.0;

        final archiveKey = parseZipVirtualPath(asset.path)!.zipPath;
        final isFirst = seenArchives.add(archiveKey);
        if (isFirst) firstInArchive += afterInflate;

        inflate += afterInflate;
        importer += afterImporter - afterInflate;
        decodeJson += afterJson - afterImporter;
        buildModel += afterModel - afterJson;
        raster += afterRaster - afterModel;
        encode += afterEncode - afterRaster;
        jsonBytes += result.stdout.length;
        counted += 1;

        stdout.writeln(
          '${afterInflate.toStringAsFixed(0).padLeft(9)}'
          '${(afterImporter - afterInflate).toStringAsFixed(0).padLeft(8)}'
          '${(afterJson - afterImporter).toStringAsFixed(0).padLeft(8)}'
          '${(afterModel - afterJson).toStringAsFixed(0).padLeft(8)}'
          '${(afterRaster - afterModel).toStringAsFixed(0).padLeft(8)}'
          '${(afterEncode - afterRaster).toStringAsFixed(0).padLeft(8)}'
          '${afterEncode.toStringAsFixed(0).padLeft(8)}'
          '${(result.stdout.length / 1024).toStringAsFixed(0).padLeft(8)}'
          '  ${isFirst ? '* ' : ''}${asset.name}',
        );
      } catch (error) {
        stdout.writeln('     ----  (${asset.name}: $error)');
      }
    }

    expect(counted, greaterThan(0), reason: 'nothing rendered');
    void line(String label, double total) {
      stdout.writeln('  ${label.padRight(34)}'
          '${(total / counted).toStringAsFixed(0).padLeft(6)} ms'
          '${(100 * total / (inflate + importer + decodeJson + buildModel + raster + encode)).toStringAsFixed(0).padLeft(6)}%');
    }

    stdout.writeln('');
    stdout.writeln('$counted assets from ${seenArchives.length} archives, '
        'mean per asset:');
    line('archive: find and inflate entry', inflate);
    line('importer subprocess', importer);
    line('jsonDecode of its output', decodeJson);
    line('build mesh (textures, relink)', buildModel);
    line('rasterise (own isolate)', raster);
    line('encode png', encode);
    stdout.writeln('  ${'total'.padRight(34)}'
        '${((inflate + importer + decodeJson + buildModel + raster + encode) / counted).toStringAsFixed(0).padLeft(6)} ms');
    stdout.writeln('');
    stdout.writeln('  mean importer output '
        '${(jsonBytes / counted / 1024).toStringAsFixed(0)} KB');
    stdout.writeln('  the * rows are the first asset out of an archive, and '
        'carry opening it:');
    stdout.writeln('  ${(firstInArchive / seenArchives.length).toStringAsFixed(0)}'
        ' ms mean against '
        '${((inflate - firstInArchive) / (counted - seenArchives.length)).toStringAsFixed(0)}'
        ' ms for the rest');
  },
      skip: enabled
          ? null
          : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB to run this benchmark',
      timeout: const Timeout(Duration(minutes: 30)));
}
