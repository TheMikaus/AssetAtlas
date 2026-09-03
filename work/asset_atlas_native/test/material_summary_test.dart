import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MeshMaterial _material({
  List<String> textures = const [],
  List<String> resolved = const [],
  Uint8List? normalPixels,
  Uint8List? emissivePixels,
}) => MeshMaterial(
  name: 'm',
  color: const Color(0xff808080),
  textures: textures,
  resolvedTextures: resolved,
  normalPixels: normalPixels,
  normalWidth: normalPixels == null ? 0 : 2,
  normalHeight: normalPixels == null ? 0 : 2,
  emissivePixels: emissivePixels,
  emissiveWidth: emissivePixels == null ? 0 : 2,
  emissiveHeight: emissivePixels == null ? 0 : 2,
);

void main() {
  group('materialSummaryLine', () {
    test('a material with no textures is flat by design', () {
      expect(materialSummaryLine(_material()), 'flat colour, no texture');
    });

    test('a material that asked and got nothing says so', () {
      final line = materialSummaryLine(
        _material(textures: const ['a.png', 'b.png']),
      );
      expect(line, 'missing: asks for 2 textures, none found');
    });

    test('one missing texture is singular', () {
      expect(
        materialSummaryLine(_material(textures: const ['a.png'])),
        'missing: asks for 1 texture, none found',
      );
    });

    test('a resolved texture is not missing', () {
      expect(
        materialSummaryLine(
          _material(textures: const ['a.png'], resolved: const ['C:/a.png']),
        ),
        'flat colour, no texture',
        reason: 'resolved but not decoded is a different problem',
      );
    });

    test('a decoded texture reports its size', () {
      expect(
        materialSummaryLine(
          _material(textures: const ['a.png']),
          width: 256,
          height: 128,
        ),
        'textured 256x128',
      );
    });

    test('extra channels are named', () {
      expect(
        materialSummaryLine(
          _material(
            textures: const ['a.png'],
            normalPixels: Uint8List(16),
            emissivePixels: Uint8List(16),
          ),
          width: 64,
          height: 64,
        ),
        'textured 64x64, normal map, emissive map',
      );
    });

    test('a broken link still names the channels it did find', () {
      expect(
        materialSummaryLine(
          _material(textures: const ['a.png'], normalPixels: Uint8List(16)),
        ),
        'missing: asks for 1 texture, none found, normal map',
      );
    });
  });
}
