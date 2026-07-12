import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FBX importer JSON pipeline decodes UVs and texture image', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asset_atlas_fbx_texture_test_',
    );
    addTearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    final modelFile = File(
      '${tempDir.path}${Platform.pathSeparator}fixture.fbx',
    );
    await modelFile.writeAsString('; fixture placeholder');

    final textureFile = File(
      '${tempDir.path}${Platform.pathSeparator}albedo.png',
    );
    final onePixelPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO3ZfQ0AAAAASUVORK5CYII=',
    );
    await textureFile.writeAsBytes(onePixelPng, flush: true);

    final mesh = await meshModelFromImporterJson(
      {
        'vertices': [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
        ],
        'faces': [
          [0, 1, 2, 0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
        ],
        'materials': [
          {
            'name': 'Mat',
            'color': [1.0, 1.0, 1.0],
            'textures': ['albedo.png'],
          },
        ],
        'textureFiles': ['albedo.png'],
      },
      modelPath: modelFile.path,
      name: 'fixture.fbx',
    );

    expect(mesh.materials.length, 1);
    expect(mesh.faces.length, 1);
    expect(mesh.faces.first.uvs.length, 3);
    expect(mesh.faces.first.uvs.first.x, 0.0);
    expect(mesh.faces.first.uvs.first.y, 0.0);
    expect(mesh.materials.first.resolvedTextures, contains(textureFile.path));
    expect(mesh.materials.first.textures, contains('albedo.png'));
    expect(mesh.allTexturePaths, contains('albedo.png'));
  });
}
