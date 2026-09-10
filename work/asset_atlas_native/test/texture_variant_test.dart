// Finding the palette swaps of a model's atlas.
//
// The case this exists for: `SM_Chr_Captain_Male_01.fbx` has exactly one
// material, so the per-material grid shows it nothing, while the pack ships
// three colourways of the atlas that material asks for. The variants are not
// in the file, they are beside it.
import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _texture(String path) => AssetItem(
  id: path,
  name: path.split(RegExp(r'[/\\]')).last,
  path: path,
  relativePath: path,
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: path.split('.').last.toLowerCase(),
  type: 'image',
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
);

AssetItem _model(String path) => AssetItem(
  id: path,
  name: path.split(RegExp(r'[/\\]')).last,
  path: path,
  relativePath: path,
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: 'fbx',
  type: 'model',
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
);

MeshModel _meshAsking(List<String> references, {int materials = 1}) => MeshModel(
  name: 'model.fbx',
  vertices: const [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
  faces: const [MeshFace([0, 1, 2])],
  materials: [
    for (var i = 0; i < materials; i += 1)
      MeshMaterial(
        name: 'Material $i',
        color: const Color(0xffffffff),
        textures: references,
      ),
  ],
);

void main() {
  // The names are the real ones from POLYGON_AncientEmpire_SourceFiles_v1.
  const captainAtlas =
      r'U:\Dropbox\SyntyStudios\PolygonAncientWorlds\Working\_Textures'
      r'\PolygonAncientWorlds_Texture_01.psd';
  const model = r'C:\Packs\Empire\SourceFiles\FBX\Characters\Captain.fbx';

  List<AssetItem> pack() => [
    for (final name in [
      'PolygonAncientWorlds_Texture_01_A.png',
      'PolygonAncientWorlds_Texture_01_B.png',
      'PolygonAncientWorlds_Texture_01_C.png',
      'PolygonAncientWorlds_Texture_02_A.png',
      'PolygonAncientWorlds_Texture_02_B.png',
      'PolygonAncientWorlds_Metallic_1A.tga',
      'Brick_Brown_Tex.png',
    ])
      _texture('${r'C:\Packs\Empire\SourceFiles\Textures\Alts'}\\$name'),
  ];

  group('the palette swaps of one atlas', () {
    test('a one-material character still has four looks', () {
      final found = findTextureVariants(
        mesh: _meshAsking(const [captainAtlas]),
        model: _model(model),
        allAssets: [_model(model), ...pack()],
      );
      expect(found.map((a) => a.name), [
        'PolygonAncientWorlds_Texture_01_A.png',
        'PolygonAncientWorlds_Texture_01_B.png',
        'PolygonAncientWorlds_Texture_01_C.png',
      ]);
    });

    test('a different atlas in the same pack is not a variant', () {
      final found = findTextureVariants(
        mesh: _meshAsking(const [captainAtlas]),
        model: _model(model),
        allAssets: [_model(model), ...pack()],
      );
      expect(
        found.map((a) => a.name).where((n) => n.contains('_02_')),
        isEmpty,
        reason: '_02 is a different atlas, not a colourway of _01',
      );
    });

    test('a metallic map of the same pack is not a colourway', () {
      final found = findTextureVariants(
        mesh: _meshAsking(const [captainAtlas]),
        model: _model(model),
        allAssets: [_model(model), ...pack()],
      );
      expect(found.map((a) => a.name).where((n) => n.contains('Metallic')), isEmpty);
    });

    test('the stem is matched in either direction', () {
      // A material referencing a swap directly still finds the plain atlas.
      final found = findTextureVariants(
        mesh: _meshAsking(const ['PolygonAncientWorlds_Texture_01_A.png']),
        model: _model(model),
        allAssets: [
          _model(model),
          _texture(
            '${r'C:\Packs\Empire\SourceFiles\Textures'}\\'
            'PolygonAncientWorlds_Texture_01.png',
          ),
          ...pack(),
        ],
      );
      expect(
        found.map((a) => a.name),
        contains('PolygonAncientWorlds_Texture_01.png'),
      );
    });

    test('another pack is out of reach even with the same names', () {
      final found = findTextureVariants(
        mesh: _meshAsking(const [captainAtlas]),
        model: _model(model),
        allAssets: [
          _model(model),
          _texture(
            '${r'C:\Packs\Other\Textures'}\\'
            'PolygonAncientWorlds_Texture_01_A.png',
          ),
        ],
      );
      expect(found, isEmpty);
    });

    test('a model that names no texture has nothing to swap', () {
      final found = findTextureVariants(
        mesh: _meshAsking(const []),
        model: _model(model),
        allAssets: [_model(model), ...pack()],
      );
      expect(found, isEmpty);
    });

    test('the list is capped, since every cell decodes an image', () {
      final many = [
        for (var i = 0; i < maxTextureVariants + 5; i += 1)
          _texture(
            '${r'C:\Packs\Empire\SourceFiles\Textures'}\\'
            'PolygonAncientWorlds_Texture_01_$i.png',
          ),
      ];
      final found = findTextureVariants(
        mesh: _meshAsking(const [captainAtlas]),
        model: _model(model),
        allAssets: [_model(model), ...many],
      );
      expect(found, hasLength(maxTextureVariants));
    });
  });
}
