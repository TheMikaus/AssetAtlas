import 'dart:math' as math;
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 2x2 texture of one flat colour, so texturing does not vary the result.
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

/// One quad facing the camera, fully UV-mapped so the texture path runs.
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


/// A quad whose normal points straight down the half vector, so it sits in the
/// middle of the specular lobe. Anything less exact misses a tight highlight
/// entirely -- which is the point of a highlight, but makes for a poor test.
MeshModel _highlightQuad(MeshMaterial material) {
  // The corner light, normalised, plus the view direction (the camera looks
  // down +z, so it sits at -z).
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
  final n = [
    half[0] / halfLength,
    half[1] / halfLength,
    half[2] / halfLength,
  ];

  // Any two axes spanning the plane perpendicular to that normal.
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

  Vec3 corner(double a, double c) => Vec3(
    t[0] * a + b[0] * c,
    t[1] * a + b[1] * c,
    t[2] * a + b[2] * c,
  );

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
  LightingMode lighting = LightingMode.corner,
}) => rasterizeMesh(
  mesh: mesh,
  yaw: 0,
  pitch: 0,
  zoom: 1,
  width: 80,
  height: 80,
  renderMode: RenderMode.textured,
  lightingMode: lighting,
  cullBackFaces: false,
);

MeshMaterial _material({
  Uint8List? emissivePixels,
  double emissiveFactor = 0,
  double specularFactor = 0,
  double roughness = 0.7,
}) => MeshMaterial(
  name: 'm',
  color: const Color(0xff808080),
  textures: const ['base.png'],
  texturePixels: _flat(0x40, 0x40, 0x40),
  textureWidth: 2,
  textureHeight: 2,
  emissivePixels: emissivePixels,
  emissiveWidth: emissivePixels == null ? 0 : 2,
  emissiveHeight: emissivePixels == null ? 0 : 2,
  emissiveFactor: emissiveFactor,
  specularFactor: specularFactor,
  roughness: roughness,
);

void main() {
  group('emissive map', () {
    test('adds light the geometry does not receive', () {
      final dark = _render(_quad(_material()));
      final glowing = _render(
        _quad(
          _material(
            emissivePixels: _flat(0x00, 0xa0, 0x00),
            emissiveFactor: 1,
          ),
        ),
      );

      expect(_center(glowing).g, greaterThan(_center(dark).g + 60));
      expect(
        _center(glowing).b,
        _center(dark).b,
        reason: 'a green emissive map only adds green',
      );
    });

    test('does nothing without a map, whatever the factor says', () {
      final plain = _render(_quad(_material()));
      final claimed = _render(_quad(_material(emissiveFactor: 2)));
      expect(_center(claimed), _center(plain));
    });

    test('a map with no factor still renders: exporters leave it at 0', () {
      final dark = _center(_render(_quad(_material())));
      final glowing = _center(
        _render(_quad(_material(emissivePixels: _flat(0x00, 0xa0, 0x00)))),
      );
      expect(glowing.g, greaterThan(dark.g + 60));
    });

    test('the factor scales it', () {
      final weak = _render(
        _quad(
          _material(
            emissivePixels: _flat(0x00, 0x40, 0x00),
            emissiveFactor: 0.5,
          ),
        ),
      );
      final strong = _render(
        _quad(
          _material(
            emissivePixels: _flat(0x00, 0x40, 0x00),
            emissiveFactor: 2,
          ),
        ),
      );
      expect(_center(strong).g, greaterThan(_center(weak).g));
    });
  });

  group('specular', () {
    test('a shiny material catches a highlight a matte one does not', () {
      final matte = _center(_render(_highlightQuad(_material())));
      final shiny = _center(
        _render(_highlightQuad(_material(specularFactor: 1, roughness: 0.05))),
      );
      expect(shiny.r, greaterThan(matte.r + 40));
    });

    test('roughness widens the lobe and dims the peak', () {
      final tight = _center(
        _render(_highlightQuad(_material(specularFactor: 1, roughness: 0.05))),
      );
      final broad = _center(
        _render(_highlightQuad(_material(specularFactor: 1, roughness: 0.9))),
      );
      // Dead centre of the lobe, both peak; the difference shows up off-axis.
      expect(tight.r, greaterThanOrEqualTo(broad.r));
    });

    test('the strength scales it', () {
      final weak = _center(
        _render(_highlightQuad(_material(specularFactor: 0.1, roughness: 0.05))),
      );
      final strong = _center(
        _render(_highlightQuad(_material(specularFactor: 1, roughness: 0.05))),
      );
      expect(strong.r, greaterThan(weak.r));
    });

    test('unlit means unlit: no highlight is added', () {
      final matte = _center(
        _render(_highlightQuad(_material()), lighting: LightingMode.unlit),
      );
      final shiny = _center(
        _render(
          _highlightQuad(_material(specularFactor: 1, roughness: 0.05)),
          lighting: LightingMode.unlit,
        ),
      );
      expect(shiny, matte);
    });

    test('the highlight is white, not tinted by the surface', () {
      final plain = _center(_render(_highlightQuad(_material())));
      final shiny = _center(
        _render(_highlightQuad(_material(specularFactor: 1, roughness: 0.05))),
      );
      // Equal gain in every channel desaturates towards white rather than
      // deepening the surface colour.
      expect(shiny.r - plain.r, shiny.g - plain.g);
      expect(shiny.g - plain.g, shiny.b - plain.b);
    });
  });
}
