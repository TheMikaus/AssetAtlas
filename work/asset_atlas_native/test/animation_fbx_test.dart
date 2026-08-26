import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _fbx({String modelKind = '', String ext = 'fbx'}) {
  final asset = AssetItem(
    id: 'a1',
    name: 'A_Idle_Standing.fbx',
    path: r'C:\Packs\A\A_Idle_Standing.fbx',
    relativePath: 'A/A_Idle_Standing.fbx',
    sourceRoot: r'C:\Packs\A',
    sourceName: 'A',
    ext: ext,
    type: 'model',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
  if (modelKind.isNotEmpty) asset.modelKind = modelKind;
  return asset;
}

void main() {
  group('effectiveType', () {
    test('an unclassified model is still a model', () {
      expect(_fbx().effectiveType, 'model');
    });

    test('a mesh classification leaves it a model', () {
      expect(_fbx(modelKind: 'mesh').effectiveType, 'model');
    });

    test('an animation classification changes the type', () {
      expect(_fbx(modelKind: 'animation').effectiveType, 'animation');
    });

    test('an unreadable file is not reclassified as animation', () {
      expect(_fbx(modelKind: 'unreadable').effectiveType, 'model');
    });
  });

  group('importer JSON', () {
    test('animation output becomes an animation-only MeshModel', () async {
      final mesh = await meshModelFromImporterJson(
        {
          'kind': 'animation',
          'name': 'A_Idle_Standing_Femn.fbx',
          'animationStacks': 2,
          'bones': 52,
          'durationSeconds': 1.76667,
          'animationNames': ['A_Idle_Standing_Femn', 'Take 001'],
        },
        modelPath: r'C:\Packs\A\A_Idle_Standing.fbx',
        name: 'A_Idle_Standing.fbx',
      );

      expect(mesh.isAnimationOnly, isTrue);
      expect(mesh.kind, FbxContentKind.animation);
      expect(mesh.animationStacks, 2);
      expect(mesh.boneCount, 52);
      expect(mesh.durationSeconds, closeTo(1.76667, 1e-5));
      expect(mesh.animationNames, ['A_Idle_Standing_Femn', 'Take 001']);
      expect(mesh.vertices, isEmpty);
      expect(mesh.faces, isEmpty);
    });

    test('mesh output stays a mesh', () async {
      final mesh = await meshModelFromImporterJson(
        {
          'kind': 'mesh',
          'name': 'cube.fbx',
          'vertices': [
            [0, 0, 0],
            [1, 0, 0],
            [0, 1, 0],
          ],
          'faces': [
            [0, 1, 2, 0],
          ],
          'materials': <dynamic>[],
        },
        modelPath: r'C:\Packs\A\cube.fbx',
        name: 'cube.fbx',
      );

      expect(mesh.isAnimationOnly, isFalse);
      expect(mesh.faces, hasLength(1));
    });
  });

  test('probe classifies without paying for a full import', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    AssetItem fixtureAsset(String fileName) {
      final path = File('test/fixtures/fbx/$fileName').absolute.path;
      return AssetItem(
        id: 'probe:$fileName',
        name: fileName,
        path: path,
        relativePath: fileName,
        sourceRoot: File(path).parent.path,
        sourceName: 'fixtures',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
      );
    }

    expect(
      await probeFbxContentKind(fixtureAsset('animation_only.fbx')),
      'animation',
    );
    expect(
      await probeFbxContentKind(fixtureAsset('transformed_uv_embedded.fbx')),
      'mesh',
    );
    expect(
      await probeFbxContentKind(fixtureAsset('does_not_exist.fbx')),
      'unreadable',
    );
  });

  test('the native importer reports a real animation clip', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final fixture = File('test/fixtures/fbx/animation_only.fbx').absolute;
    if (!fixture.existsSync()) {
      markTestSkipped('animation_only.fbx fixture is missing.');
      return;
    }

    final mesh = await importFbxWithUfbx(fixture.path, 'animation_only.fbx');
    expect(mesh.isAnimationOnly, isTrue);
    expect(mesh.boneCount, greaterThan(0));
    expect(mesh.animationStacks, greaterThan(0));
    expect(mesh.durationSeconds, greaterThan(0));
  });
}
