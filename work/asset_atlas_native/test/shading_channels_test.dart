import 'dart:math' as math;
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _flat(int r, int g, int b) {
  final pixels = Uint8List(2 * 2 * 4);
  for (var i = 0; i < 4; i += 1) {
    pixels[i * 4] = r;
    pixels[i * 4 + 1] = g;
    pixels[i * 4 + 2] = b;
    pixels[i * 4 + 3] = 255;
  }
  return pixels;
}

/// A camera-facing quad, fully UV-mapped so every channel has something to do.
MeshModel _quad(MeshMaterial material) => MeshModel(
  name: 'quad',
  vertices: const [
    Vec3(-1, -1, 0),
    Vec3(1, -1, 0),
    Vec3(1, 1, 0),
    Vec3(-1, 1, 0),
  ],
  faces: [
    MeshFace([0, 1, 2], 0, const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)]),
    MeshFace([0, 2, 3], 0, const [Vec2(0, 0), Vec2(1, 1), Vec2(0, 1)]),
  ],
  materials: [material],
);


/// A quad whose normal sits on the half vector, so it is inside the specular
/// lobe. A camera-facing quad is not: a tight highlight misses it entirely.
MeshModel _highlightQuad(MeshMaterial material) {
  final light = [-0.45, 0.75, -0.5];
  final lightLength = math.sqrt(
    light[0] * light[0] + light[1] * light[1] + light[2] * light[2],
  );
  final half = [
    light[0] / lightLength,
    light[1] / lightLength,
    light[2] / lightLength - 1,
  ];
  final halfLength = math.sqrt(
    half[0] * half[0] + half[1] * half[1] + half[2] * half[2],
  );
  final n = [half[0] / halfLength, half[1] / halfLength, half[2] / halfLength];
  final tRaw = [n[2], 0.0, -n[0]];
  final tLength = math.sqrt(
    tRaw[0] * tRaw[0] + tRaw[1] * tRaw[1] + tRaw[2] * tRaw[2],
  );
  final t = [tRaw[0] / tLength, tRaw[1] / tLength, tRaw[2] / tLength];
  final b = [
    n[1] * t[2] - n[2] * t[1],
    n[2] * t[0] - n[0] * t[2],
    n[0] * t[1] - n[1] * t[0],
  ];
  Vec3 corner(double a, double c) =>
      Vec3(t[0] * a + b[0] * c, t[1] * a + b[1] * c, t[2] * a + b[2] * c);

  return MeshModel(
    name: 'highlight',
    vertices: [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)],
    faces: [
      MeshFace([0, 1, 2], 0, const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)]),
      MeshFace([0, 2, 3], 0, const [Vec2(0, 0), Vec2(1, 1), Vec2(0, 1)]),
    ],
    materials: [material],
  );
}

({int r, int g, int b}) _center(RasterResult raster) {
  final i = ((raster.height ~/ 2) * raster.width + raster.width ~/ 2) * 4;
  return (r: raster.pixels[i], g: raster.pixels[i + 1], b: raster.pixels[i + 2]);
}

RasterResult _render(
  MeshModel mesh, {
  bool base = true,
  bool normals = true,
  bool emissive = true,
  bool specular = true,
}) => rasterizeMesh(
  mesh: mesh,
  yaw: 0,
  pitch: 0,
  zoom: 1,
  width: 80,
  height: 80,
  renderMode: RenderMode.textured,
  lightingMode: LightingMode.corner,
  cullBackFaces: false,
  useBaseTexture: base,
  useNormalMaps: normals,
  useEmissiveMaps: emissive,
  useSpecular: specular,
);

/// A base texture that is unmistakably not the material's flat colour.
MeshMaterial _material({Uint8List? emissivePixels, double specularFactor = 0}) =>
    MeshMaterial(
      name: 'm',
      color: const Color(0xff303030),
      textures: const ['base.png'],
      texturePixels: _flat(0xc0, 0x20, 0x20),
      textureWidth: 2,
      textureHeight: 2,
      emissivePixels: emissivePixels,
      emissiveWidth: emissivePixels == null ? 0 : 2,
      emissiveHeight: emissivePixels == null ? 0 : 2,
      specularFactor: specularFactor,
      roughness: 0.05,
    );

void main() {
  group('shading channel switches', () {
    test('base texture off falls back to the flat colour', () {
      final on = _center(_render(_quad(_material())));
      final off = _center(_render(_quad(_material()), base: false));
      expect(on.r, greaterThan(off.r + 40));
    });

    test('emissive off removes only the emissive contribution', () {
      final mesh = _quad(_material(emissivePixels: _flat(0, 0xa0, 0)));
      final on = _center(_render(mesh));
      final off = _center(_render(mesh, emissive: false));
      expect(on.g, greaterThan(off.g + 60));
      expect(on.r, off.r, reason: 'a green emissive map touches no other channel');
    });

    test('specular off removes the highlight', () {
      final mesh = _highlightQuad(_material(specularFactor: 1));
      final on = _center(_render(mesh));
      final off = _center(_render(mesh, specular: false));
      expect(on.r, greaterThan(off.r + 40));
    });

    test('the channels are independent: base off keeps emissive', () {
      final mesh = _quad(_material(emissivePixels: _flat(0, 0xa0, 0)));
      final noBase = _center(_render(mesh, base: false));
      final neither = _center(_render(mesh, base: false, emissive: false));
      expect(noBase.g, greaterThan(neither.g + 60));
    });

    test('all four on is the default', () {
      final mesh = _quad(_material(emissivePixels: _flat(0, 0xa0, 0), specularFactor: 1));
      final explicit = _render(mesh);
      final byDefault = rasterizeMesh(
        mesh: mesh,
        yaw: 0,
        pitch: 0,
        zoom: 1,
        width: 80,
        height: 80,
        renderMode: RenderMode.textured,
        lightingMode: LightingMode.corner,
        cullBackFaces: false,
      );
      expect(explicit.pixels, byDefault.pixels);
    });

    test('solid mode ignores every channel: there is no texturing to switch', () {
      RasterResult solid({required bool base}) => rasterizeMesh(
        mesh: _quad(_material(emissivePixels: _flat(0, 0xa0, 0), specularFactor: 1)),
        yaw: 0,
        pitch: 0,
        zoom: 1,
        width: 80,
        height: 80,
        renderMode: RenderMode.solid,
        lightingMode: LightingMode.corner,
        cullBackFaces: false,
        useBaseTexture: base,
        useEmissiveMaps: base,
        useSpecular: base,
      );
      expect(solid(base: true).pixels, solid(base: false).pixels);
    });
  });
}
