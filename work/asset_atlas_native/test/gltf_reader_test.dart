import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading GLB, through the same importer and the same JSON as FBX.
///
/// 3,035 GLB files are in this library and 192 of them -- the KayKit
/// Dungeon pack -- have no FBX or OBJ twin, so before this nothing could
/// draw them. The other formats in that family all have twins, which is why
/// DAE is not read at all.

const _corpusVariable = 'ASSET_ATLAS_SYNTY_CORPUS';

File get _importer =>
    File('build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe');

AssetItem _asset(String path, {String? type}) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return AssetItem(
    id: path,
    name: name,
    path: path,
    relativePath: name,
    sourceRoot: r'Z:\Assets',
    sourceName: 'Assets',
    ext: ext,
    type: type ?? 'model',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

void main() {
  group('what Atlas says it can draw', () {
    test('GLB and glTF are previewable, DAE is not', () {
      expect(previewableModelExts, contains('glb'));
      expect(previewableModelExts, contains('gltf'));
      expect(previewableModelExts, isNot(contains('dae')));
    });

    test('a GLB in an archive is previewable; a glTF in one is not', () {
      final glb = _asset(r'zip:Z:\Packs\Kit.zip::Models/Chest.glb');
      final gltf = _asset(r'zip:Z:\Packs\Kit.zip::Models/Chest.gltf');
      expect(previewKindFor(glb), PreviewKind.model);
      expect(
        previewKindFor(gltf),
        PreviewKind.zipModelUnsupported,
        reason: 'its geometry is in a .bin the reader cannot reach',
      );
    });

    test('a loose glTF on disk is previewable', () {
      expect(
        previewKindFor(_asset(r'Z:\Packs\Kit\Chest.gltf')),
        PreviewKind.model,
      );
    });

    test('a DAE is still not drawn', () {
      expect(
        previewKindFor(_asset(r'Z:\Packs\Kit\Chest.dae')),
        PreviewKind.zipModelUnsupported,
      );
    });
  });

  group('the importer reads a real GLB', () {
    final root = Platform.environment[_corpusVariable];
    // The KayKit pack sits beside the Synty one under the same assets root.
    final kit = root == null
        ? null
        : Directory(root).parent.path;
    final skip = root == null || root.isEmpty
        ? 'set $_corpusVariable to the folder holding the asset library'
        : null;

    String? findGlb() {
      if (kit == null) return null;
      final folder = Directory(
        '$kit${Platform.pathSeparator}KayKit Dungeon Pack 1.0',
      );
      if (!folder.existsSync()) return null;
      for (final entity in folder.listSync(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.glb')) {
          return entity.path;
        }
      }
      return null;
    }

    test('--probe calls it a mesh and counts its faces', () async {
      if (!_importer.existsSync()) {
        markTestSkipped('build the Windows app first');
        return;
      }
      final path = findGlb();
      if (path == null) {
        markTestSkipped('no KayKit GLB in this library');
        return;
      }
      final result = await Process.run(_importer.absolute.path, [
        '--probe',
        path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr as String? ?? '');
      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(json['kind'], 'mesh');
      expect(json['faces'], greaterThan(0));
      // Skins are not read yet, so no rig is claimed rather than a wrong one.
      expect(json['bones'], 0);
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

    test('the geometry decodes into a mesh with UVs and materials', () async {
      if (!_importer.existsSync()) {
        markTestSkipped('build the Windows app first');
        return;
      }
      final path = findGlb();
      if (path == null) {
        markTestSkipped('no KayKit GLB in this library');
        return;
      }
      final mesh = await loadMesh(_asset(path));
      expect(mesh.vertices, isNotEmpty);
      expect(mesh.faces, isNotEmpty);
      expect(mesh.materials, isNotEmpty);
      expect(
        mesh.faces.any((face) => face.uvs.isNotEmpty),
        isTrue,
        reason: 'the first UV set is read',
      );
      // Every vertex index has to be inside the vertex list, or the
      // rasteriser reads off the end of it.
      for (final face in mesh.faces) {
        for (final index in face.indices) {
          expect(index, inInclusiveRange(0, mesh.vertices.length - 1));
        }
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

    test('it draws, and not as an empty frame', () async {
      if (!_importer.existsSync()) {
        markTestSkipped('build the Windows app first');
        return;
      }
      final path = findGlb();
      if (path == null) {
        markTestSkipped('no KayKit GLB in this library');
        return;
      }
      final mesh = await loadMesh(_asset(path));
      final raster = rasterizeMesh(
        mesh: mesh,
        yaw: -0.6,
        pitch: 0.3,
        zoom: 1,
        width: 192,
        height: 192,
        renderMode: RenderMode.textured,
        lightingMode: LightingMode.corner,
        cullBackFaces: true,
      );
      expect(raster.drawnFaces, greaterThan(0));
      final background = raster.pixels.sublist(0, 4);
      var different = 0;
      for (var i = 0; i < raster.pixels.length; i += 4) {
        if (raster.pixels[i] != background[0] ||
            raster.pixels[i + 1] != background[1] ||
            raster.pixels[i + 2] != background[2]) {
          different += 1;
        }
      }
      expect(
        different,
        greaterThan(192 * 192 ~/ 50),
        reason: 'the model covers a visible part of the frame',
      );
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
  });
}
