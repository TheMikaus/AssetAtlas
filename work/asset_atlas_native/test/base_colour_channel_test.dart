import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Which of a material's textures may colour a face.
///
/// `textures` holds every reference a material names, the normal and emissive
/// maps included, and the base colour used to be whichever of them resolved
/// first. That is right only while the colour map resolves: on
/// SM_Wep_Mining_Laser_01 the colour map resolved to nothing, the emissive
/// did resolve, and so the emissive became the base colour -- an emissive map
/// is black but for a few bright spots, so the model drew as a black
/// silhouette while still reporting a texture as found.
void main() {
  /// A real PNG of a known colour, encoded rather than pasted: the first
  /// draft of this used base64 written by hand, which did not decode -- so
  /// every texture came back null, `textureWidth` was 0 throughout, and the
  /// test that matters passed for the wrong reason while its own control
  /// failed and gave it away.
  Future<String> writePng(
    Directory where,
    String name,
    int shade, {
    int size = 4,
  }) async {
    final picture = img.Image(width: size, height: size, numChannels: 4);
    for (var y = 0; y < size; y += 1) {
      for (var x = 0; x < size; x += 1) {
        picture.setPixelRgba(x, y, shade, shade, shade, 255);
      }
    }
    final file = File('${where.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(img.encodePng(picture), flush: true);
    return file.path;
  }

  const white = 235;
  const black = 0;

  late Directory workspace;
  late String modelPath;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('atlas_base_colour_');
    final model = File('${workspace.path}${Platform.pathSeparator}thing.fbx');
    await model.writeAsString('; fixture');
    modelPath = model.path;
  });

  tearDown(() async {
    if (workspace.existsSync()) await workspace.delete(recursive: true);
  });

  Future<MeshModel> build(Map<String, Object?> material) {
    return meshModelFromImporterJson(
      {
        'vertices': [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
        ],
        'faces': [
          [0, 1, 2, 0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0],
        ],
        'materials': [material],
      },
      modelPath: modelPath,
      name: 'thing.fbx',
    );
  }

  test('an emissive map does not become the base colour', () async {
    // The reported shape: the colour map is named but absent, the emissive is
    // named and present.
    await writePng(workspace, 'Pack_Emissive_01_A.png', black);
    final mesh = await build({
      'name': 'MAT_01A',
      'color': [1.0, 1.0, 1.0],
      'textures': ['Pack_Texture_01_A.png', 'Pack_Emissive_01_A.png'],
      'emissiveTexture': 'Pack_Emissive_01_A.png',
    });

    final material = mesh.materials.single;
    // The emissive did resolve, and saying otherwise would lose something
    // true: it is reported, used for emission, and simply not the base.
    expect(
      material.resolvedTextures.any((path) => path.contains('Emissive')),
      isTrue,
      reason: 'the emissive resolved and the report should still say so',
    );
    // But nothing coloured the face, so this material is untextured.
    expect(
      material.textureWidth,
      0,
      reason: 'the emissive must not have been taken as the base colour',
    );
  });

  test('a normal map does not become the base colour either', () async {
    await writePng(workspace, 'Pack_Texture_A_01_Normal.png', black);
    final mesh = await build({
      'name': 'MAT',
      'color': [1.0, 1.0, 1.0],
      'textures': ['Pack_Texture_01.png', 'Pack_Texture_A_01_Normal.png'],
      'normalTexture': 'Pack_Texture_A_01_Normal.png',
    });
    expect(mesh.materials.single.textureWidth, 0);
  });

  test('a channel map is refused even when nothing declared it', () async {
    // The importer does not always fill in emissiveTexture, so the name has
    // to be enough on its own.
    await writePng(workspace, 'Pack_Emissive_01_A.png', black);
    final mesh = await build({
      'name': 'MAT',
      'color': [1.0, 1.0, 1.0],
      'textures': ['Pack_Texture_01_A.png', 'Pack_Emissive_01_A.png'],
    });
    expect(mesh.materials.single.textureWidth, 0);
  });

  test('the colour map is still used when it does resolve', () async {
    // The control: this is the common case and it must not change.
    await writePng(workspace, 'Pack_Texture_01_A.png', white);
    await writePng(workspace, 'Pack_Emissive_01_A.png', black);
    final mesh = await build({
      'name': 'MAT',
      'color': [1.0, 1.0, 1.0],
      'textures': ['Pack_Texture_01_A.png', 'Pack_Emissive_01_A.png'],
      'emissiveTexture': 'Pack_Emissive_01_A.png',
    });
    final material = mesh.materials.single;
    expect(material.textureWidth, 4, reason: 'the colour map should be used');
    expect(material.resolvedTextures.length, 2);
  });

  test('the colour map wins even when it is named second', () async {
    // Order in `textures` is the importer's, not a priority, so the rule has
    // to be about the channel rather than about the position.
    await writePng(workspace, 'Pack_Texture_01_A.png', white);
    await writePng(workspace, 'Pack_Emissive_01_A.png', black);
    final mesh = await build({
      'name': 'MAT',
      'color': [1.0, 1.0, 1.0],
      'textures': ['Pack_Emissive_01_A.png', 'Pack_Texture_01_A.png'],
      'emissiveTexture': 'Pack_Emissive_01_A.png',
    });
    expect(mesh.materials.single.textureWidth, 4);
  });

  test('a material naming only channel maps is untextured, not black',
      () async {
    await writePng(workspace, 'Pack_Normal_01.png', black);
    final mesh = await build({
      'name': 'MAT',
      'color': [0.5, 0.5, 0.5],
      'textures': ['Pack_Normal_01.png'],
    });
    final material = mesh.materials.single;
    expect(material.textureWidth, 0);
    // It falls back to the material's own colour, which is what an
    // untextured material has always done.
    expect(material.color, isNotNull);
  });
}
