@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';

/// What one texture reference costs when the catalog is the size it is now.
///
/// `_relinkCandidatesFor` partitions every asset in the catalog for the model
/// being loaded, and caches exactly one result, keyed on the model path. For
/// somebody clicking through models that is the right trade. For a tagging
/// run it means the partition is rebuilt per model -- and the comment on it
/// was written when the catalog held 26,000 assets, where this library now
/// holds 221,183.
///
/// Run with: flutter test test/relink_cost_test.dart
void main() {
  List<AssetItem> libraryOf(int models, int textures) {
    final assets = <AssetItem>[];
    final now = DateTime.now();
    AssetItem make(String path, String ext, String type) => AssetItem(
      id: path,
      name: path.split('/').last,
      path: path,
      relativePath: path,
      sourceRoot: 'Z:/Assets',
      sourceName: 'bench',
      ext: ext,
      type: type,
      size: 1024,
      modified: now,
      tags: const [],
    );

    for (var index = 0; index < models; index += 1) {
      assets.add(
        make('Z:/Assets/Pack$index/Models/SM_Thing_$index.fbx', 'fbx', 'model'),
      );
    }
    for (var index = 0; index < textures; index += 1) {
      assets.add(
        make('Z:/Assets/Pack$index/Textures/T_Thing_$index.png', 'png',
            'image'),
      );
    }
    return assets;
  }

  // Guarded like the other benchmark: it builds 221,183 objects and takes
  // seconds, and the ordinary suite should stay fast and assertion-shaped.
  final enabled = Platform.environment['ATLAS_BENCH'] == '1';

  test('one unresolved texture reference, by catalog size', () {
    stdout.writeln('');
    stdout.writeln('  assets   first call   second call (same model)');
    for (final size in const [26000, 100000, 221183]) {
      // Four fifths models, one fifth textures: the partition walks all of
      // them and keeps the texture ones, which is the shape that matters.
      final assets = libraryOf((size * 0.8).round(), (size * 0.2).round());
      const model = 'Z:/Assets/Pack7/Models/SM_Thing_7.fbx';

      final cold = Stopwatch()..start();
      findDeterministicTextureRelink(model, 'T_trim_BC.tga', assets);
      cold.stop();

      final warm = Stopwatch()..start();
      findDeterministicTextureRelink(model, 'T_other_BC.tga', assets);
      warm.stop();

      stdout.writeln(
        '${assets.length.toString().padLeft(8)}'
        '${'${cold.elapsedMilliseconds} ms'.padLeft(13)}'
        '${'${warm.elapsedMilliseconds} ms'.padLeft(14)}',
      );
    }

    stdout.writeln('');
    stdout.writeln('The second column is what a tagging run pays per model,');
    stdout.writeln('because the cache is keyed on the model path and every');
    stdout.writeln('asset is a different model.');
  },
      skip: enabled ? null : 'set ATLAS_BENCH=1 to run this benchmark',
      timeout: const Timeout(Duration(minutes: 5)));
}
