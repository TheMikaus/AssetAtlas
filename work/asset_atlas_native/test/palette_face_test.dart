import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MeshMaterial _paletteMaterial() {
  // 2x1 texture: red texel, blue texel. No ui.Image needed -- the flat-fill
  // path reads pixels, not the GPU image.
  return MeshMaterial(
    name: 'atlas',
    color: const Color(0xffffffff),
    textures: const [],
    texturePixels: Uint8List.fromList(<int>[
      220, 30, 40, 255, // red
      30, 60, 220, 255, // blue
    ]),
    textureWidth: 2,
    textureHeight: 1,
  );
}

void main() {
  group('isDegenerateUvTriangle', () {
    test('three identical corners are degenerate', () {
      expect(
        isDegenerateUvTriangle(const [
          Vec2(0.3, 0.7),
          Vec2(0.3, 0.7),
          Vec2(0.3, 0.7),
        ]),
        isTrue,
      );
    });

    test('a triangle with area is not', () {
      expect(
        isDegenerateUvTriangle(const [
          Vec2(0.0, 0.0),
          Vec2(1.0, 0.0),
          Vec2(0.0, 1.0),
        ]),
        isFalse,
      );
    });

    test('collinear corners are degenerate too', () {
      expect(
        isDegenerateUvTriangle(const [
          Vec2(0.1, 0.1),
          Vec2(0.2, 0.2),
          Vec2(0.3, 0.3),
        ]),
        isTrue,
      );
    });
  });

  group('sampling the palette texel', () {
    test('reads the texel a face is pinned to', () {
      final material = _paletteMaterial();

      final red = material.sampleTexture(const Vec2(0.0, 0.5));
      expect(red, isNotNull);
      expect(red!.r * 255, greaterThan(150));
      expect(red.b * 255, lessThan(90));

      // 0.9 rather than 1.0: exactly 1.0 wraps back to the first texel, which
      // is what a tiling texture should do.
      final blue = material.sampleTexture(const Vec2(0.9, 0.5));
      expect(blue, isNotNull);
      expect(blue!.b * 255, greaterThan(150));
      expect(blue.r * 255, lessThan(90));
    });

    test('wraps UVs outside 0..1 the way a tiling material does', () {
      final material = _paletteMaterial();
      expect(
        material.sampleTexture(const Vec2(2.0, 0.5)),
        material.sampleTexture(const Vec2(0.0, 0.5)),
      );
      expect(
        material.sampleTexture(const Vec2(1.9, 0.5)),
        material.sampleTexture(const Vec2(0.9, 0.5)),
      );
      expect(
        material.sampleTexture(const Vec2(-1.0, 0.5)),
        material.sampleTexture(const Vec2(0.0, 0.5)),
      );
    });

    test('returns null when there was no readback', () {
      const material = MeshMaterial(
        name: 'no pixels',
        color: Color(0xffffffff),
        textures: [],
      );
      expect(material.sampleTexture(const Vec2(0.5, 0.5)), isNull);
    });
  });
}
