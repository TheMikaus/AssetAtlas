import 'dart:io';
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 2x1 normal map: left texel tilts towards -X, right texel towards +X.
MeshMaterial _normalMappedMaterial() => MeshMaterial(
  name: 'bumpy',
  color: const Color(0xffffffff),
  textures: const [],
  normalTexture: 'normal_map.png',
  normalPixels: Uint8List.fromList(<int>[
    40, 128, 200, 255, // tilted -X
    215, 128, 200, 255, // tilted +X
  ]),
  normalWidth: 2,
  normalHeight: 1,
);

/// A flat quad in the XY plane facing the viewer, with UVs spread across it.
const _viewPositions = [
  Vec3(-1, -1, 0),
  Vec3(1, -1, 0),
  Vec3(-1, 1, 0),
];
const _spreadUvs = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)];

void main() {
  group('sampleNormal', () {
    test('decodes the usual RGB encoding around 0.5', () {
      final material = _normalMappedMaterial();

      final left = material.sampleNormal(const Vec2(0.0, 0.5))!;
      expect(left.x, lessThan(0), reason: 'red below 128 means -X');
      expect(left.z, greaterThan(0), reason: 'blue is the outward axis');

      final right = material.sampleNormal(const Vec2(0.9, 0.5))!;
      expect(right.x, greaterThan(0));
    });

    test('is null when the material carries no normal map', () {
      const material = MeshMaterial(
        name: 'plain',
        color: Color(0xffffffff),
        textures: [],
      );
      expect(material.hasNormalMap, isFalse);
      expect(material.sampleNormal(const Vec2(0.5, 0.5)), isNull);
    });
  });

  group('faceDiffuseWithNormalMap', () {
    test('without a sampled normal it is the plain geometric term', () {
      final plain = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: const Vec3(0, 0, 1),
        viewPositions: _viewPositions,
        uvs: _spreadUvs,
      );
      expect(plain, closeTo(1.0, 1e-9), reason: 'light straight down the normal');
    });

    test('a tilted normal changes the shading', () {
      const light = Vec3(1, 0, 0.2);
      final flat = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: _spreadUvs,
      );
      final tilted = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: _spreadUvs,
        // Strongly tilted towards +X in tangent space.
        sampledNormal: const Vec3(0.8, 0, 0.6),
      );
      expect(
        tilted,
        isNot(closeTo(flat, 1e-6)),
        reason: 'that is the entire point of a normal map',
      );
    });

    test('opposite tilts shade differently from each other', () {
      const light = Vec3(1, 0, 0.2);
      final towards = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: _spreadUvs,
        sampledNormal: const Vec3(0.8, 0, 0.6),
      );
      final away = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: _spreadUvs,
        sampledNormal: const Vec3(-0.8, 0, 0.6),
      );
      expect(towards, isNot(closeTo(away, 1e-6)));
    });

    test('a face pinned to one texel keeps its geometric normal', () {
      const light = Vec3(1, 0, 0.2);
      const pinned = [Vec2(0.3, 0.7), Vec2(0.3, 0.7), Vec2(0.3, 0.7)];
      final plain = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: pinned,
      );
      final withSample = faceDiffuseWithNormalMap(
        geometricNormal: const Vec3(0, 0, 1),
        lightDirection: light,
        viewPositions: _viewPositions,
        uvs: pinned,
        sampledNormal: const Vec3(0.8, 0, 0.6),
      );
      expect(
        withSample,
        closeTo(plain, 1e-9),
        reason: 'no UV gradient means no tangent frame to rotate into',
      );
    });

    test('stays within the renderer\'s shading range', () {
      for (final sample in [
        const Vec3(0.9, 0, 0.4),
        const Vec3(-0.9, 0, 0.4),
        const Vec3(0, 0.9, 0.4),
      ]) {
        final value = faceDiffuseWithNormalMap(
          geometricNormal: const Vec3(0, 0, 1),
          lightDirection: const Vec3(-0.45, 0.75, -0.5),
          viewPositions: _viewPositions,
          uvs: _spreadUvs,
          sampledNormal: sample,
        );
        expect(value, inInclusiveRange(0.42, 1.0));
      }
    });
  });

  test('the importer reports a material\'s normal map', () async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final fixture = File('test/fixtures/fbx/normal_mapped.fbx').absolute;
    expect(fixture.existsSync(), isTrue);

    final mesh = await importFbxWithUfbx(fixture.path, 'normal_mapped.fbx');
    final material = mesh.materials.single;
    expect(material.normalTexture, contains('normal_map.png'));
    expect(
      material.hasNormalMap,
      isTrue,
      reason: 'the map sits next to the model and should resolve',
    );
    expect(material.normalWidth, 2);
    expect(material.sampleNormal(const Vec2(0.0, 0.5)), isNotNull);
  });
}
