@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:asset_atlas_native/main.dart';

/// Where the two seconds per asset goes.
///
/// Not an assertion about behaviour -- it prints a table. It exists because
/// four hypotheses about that two seconds were wrong in a row: the importer
/// subprocess (27 ms), geometry size (flat across four orders of magnitude),
/// archive inflation (zip assets are the *faster* group), and texture
/// decoding (median zero textures per model in a sample of forty). Guessing
/// was the problem, so this measures.
///
/// Reads real assets listed in a file given by ATLAS_BENCH_PATHS, one path
/// per line, and skips entirely when that is unset -- it must not run in the
/// ordinary suite, where there is no asset library.
void main() {
  final listing = Platform.environment['ATLAS_BENCH_PATHS'];

  test(
    'where the time goes in one render',
    () async {
      final paths = File(listing!)
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      AssetItem itemFor(String path) => AssetItem(
        id: path,
        name: path.split(RegExp(r'[\\/]')).last,
        path: path,
        relativePath: path.split(RegExp(r'[\\/]')).last,
        sourceRoot: parentPath(path),
        sourceName: 'bench',
        ext: extensionOf(path),
        type: 'model',
        size: File(path).existsSync() ? File(path).lengthSync() : 0,
        modified: DateTime.now(),
        tags: const [],
      );

      var meshTotal = 0.0;
      var rasterTotal = 0.0;
      var encodeTotal = 0.0;
      var counted = 0;

      stdout.writeln('');
      stdout.writeln('   mesh  raster  encode   total   faces  name');

      for (final path in paths) {
        final asset = itemFor(path);
        final clock = Stopwatch()..start();
        try {
          // Stage one: the importer subprocess, its JSON, the mesh, and
          // whatever textures get resolved and decoded. All on this isolate.
          final mesh = await loadMesh(asset);
          final afterMesh = clock.elapsedMicroseconds / 1000.0;
          if (mesh.faces.isEmpty) continue;

          // Stage two: the rasteriser, which has an isolate to itself.
          final raster = await rasterizeSceneInIsolate(
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

          // Stage three: PNG encoding, back on this isolate.
          final image = img.Image.fromBytes(
            width: raster.width,
            height: raster.height,
            bytes: raster.pixels.buffer,
            numChannels: 4,
          );
          img.encodePng(image);
          final afterEncode = clock.elapsedMicroseconds / 1000.0;

          meshTotal += afterMesh;
          rasterTotal += afterRaster - afterMesh;
          encodeTotal += afterEncode - afterRaster;
          counted += 1;

          stdout.writeln(
            '${afterMesh.toStringAsFixed(0).padLeft(7)}'
            '${(afterRaster - afterMesh).toStringAsFixed(0).padLeft(8)}'
            '${(afterEncode - afterRaster).toStringAsFixed(0).padLeft(8)}'
            '${afterEncode.toStringAsFixed(0).padLeft(8)}'
            '${raster.totalFaces.toString().padLeft(8)}  ${asset.name}',
          );
        } catch (error) {
          stdout.writeln('   ----    ----    ----    ----    ----  '
              '${asset.name}: $error');
        }
      }

      expect(counted, greaterThan(0), reason: 'nothing rendered');
      stdout.writeln('');
      stdout.writeln('$counted assets, mean milliseconds:');
      stdout.writeln('  mesh + textures (this isolate) '
          '${(meshTotal / counted).toStringAsFixed(0)}');
      stdout.writeln('  raster (own isolate)           '
          '${(rasterTotal / counted).toStringAsFixed(0)}');
      stdout.writeln('  png encode (this isolate)      '
          '${(encodeTotal / counted).toStringAsFixed(0)}');
      stdout.writeln('  total                          '
          '${((meshTotal + rasterTotal + encodeTotal) / counted)
              .toStringAsFixed(0)}');
    },
    skip: listing == null
        ? 'set ATLAS_BENCH_PATHS to a file of asset paths to run this'
        : null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
