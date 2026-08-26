import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native importer preserves instances, embedded texture, and UV sets',
    () async {
      final helper = File(
        'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
      );
      if (!helper.existsSync()) {
        markTestSkipped(
          'Build the Windows app before running native FBX tests.',
        );
        return;
      }

      final fixture = File(
        'test/fixtures/fbx/transformed_uv_embedded.fbx',
      ).absolute;
      expect(fixture.existsSync(), isTrue);

      final result = await Process.run(helper.absolute.path, [fixture.path]);
      expect(result.exitCode, 0, reason: result.stderr as String? ?? '');

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final vertices = json['vertices'] as List<dynamic>;
      final faces = json['faces'] as List<dynamic>;
      expect(vertices, hasLength(6));
      expect(faces, hasLength(2));

      final xs = vertices
          .map((vertex) => ((vertex as List<dynamic>)[0] as num).toDouble())
          .toList();
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(-1.0, 1e-6));
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-6));

      final materials = json['materials'] as List<dynamic>;
      final material = materials.single as Map<String, dynamic>;
      expect(material['uvSet'], 'DetailUV');
      final embedded = base64Decode(
        material['embeddedTextureBase64'] as String,
      );
      expect(embedded.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);

      final uvSets = json['uvSets'] as List<dynamic>;
      expect(
        uvSets.map((item) => (item as Map<String, dynamic>)['name']),
        containsAll(['UVMap', 'DetailUV']),
      );

      final mesh = await meshModelFromImporterJson(
        json,
        modelPath: fixture.path,
        name: fixture.uri.pathSegments.last,
      );
      expect(mesh.faces, hasLength(2));
      expect(mesh.materials.single.hasEmbeddedTexture, isTrue);
      expect(mesh.materials.single.uvSet, 'DetailUV');
      expect(mesh.availableUvSets, ['DetailUV', 'UVMap']);
      expect(mesh.faces.first.uvsFor('DetailUV').first.x, closeTo(0.25, 1e-6));
      expect(mesh.faces.first.uvsFor('DetailUV').first.y, closeTo(0.75, 1e-6));
    },
  );

  test(
    'importer output survives the round trip as UTF-8 and stays valid JSON',
    () async {
      final helper = File(
        'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
      );
      if (!helper.existsSync()) {
        markTestSkipped('Build the Windows app before running native FBX tests.');
        return;
      }

      final fixture = File('test/fixtures/fbx/non_ascii_material.fbx').absolute;
      expect(fixture.existsSync(), isTrue);

      // The on-disk branch is the one that used to decode with systemEncoding.
      final result = await runMeshImporter(helper.absolute.path, fixture.path);
      expect(result.exitCode, 0, reason: result.stderr);

      // A raw control byte in the material name must be escaped by the
      // importer, or this decode throws.
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      final material = (json['materials'] as List<dynamic>).first
          as Map<String, dynamic>;
      expect(material['name'], 'Matériau_Grün\u0001x');
    },
  );
}
