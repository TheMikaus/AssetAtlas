import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Reading the `.mtl` sidecar, which nothing in Atlas did until now.
///
/// `parseObjMesh` built every material flat grey and put the `mtllib`
/// filename where the texture references go -- so the only reference an OBJ
/// could offer the resolver was `ship_dark.mtl`, which is not an image, and
/// which then came back as a missing texture.
///
/// Measured over the 4,189 OBJ files on disk in this library: 3,429 have a
/// sidecar carrying `Kd` colours and no texture at all, 201 name a texture
/// with `map_Kd`, 559 have no sidecar. So the colour half is the common case
/// and is tested first.
void main() {
  group('parsing a sidecar', () {
    test('Kd becomes the material colour', () {
      final library = parseObjMaterialLibrary('''
# Blender MTL File
newmtl BlueDark
Ns 225.000000
Ka 1.000000 1.000000 1.000000
Kd 0.130795 0.252614 0.408371
Ks 0.500000 0.500000 0.500000
illum 2
''');
      expect(library.keys, ['BlueDark']);
      final colour = library['BlueDark']!.color!;
      // Scaled straight from 0..1, no gamma step, matching what the FBX path
      // does with the same quantity.
      expect(colour.r * 255, closeTo(33, 1));
      expect(colour.g * 255, closeTo(64, 1));
      expect(colour.b * 255, closeTo(104, 1));
      expect(library['BlueDark']!.diffuseTexture, isNull);
    });

    test('map_Kd becomes the texture reference, path kept whole', () {
      final library = parseObjMaterialLibrary('''
# Exported using Kenney Suite 1.2
newmtl alien
Ka 0.000000 0.000000 0.000000
Kd 1 1 1
Ks 0.330000 0.330000 0.330000
map_Kd Textures/alien.png
''');
      expect(library['alien']!.diffuseTexture, 'Textures/alien.png');
    });

    test('several materials in one file each keep their own values', () {
      // ship_dark.obj declares five, and they all drew the same colour.
      final library = parseObjMaterialLibrary('''
newmtl wood
Kd 0.8 0.6 0.3
newmtl iron
Kd 0.2 0.2 0.25
newmtl window
Kd 0.1 0.4 0.6
''');
      expect(library, hasLength(3));
      final colours = {
        for (final entry in library.entries) entry.key: entry.value.color,
      };
      expect(colours.values.toSet(), hasLength(3),
          reason: 'three declared materials must be three colours');
    });

    test('the last material in the file is not dropped', () {
      // There is no `endmtl`, so the final block is only committed when the
      // file ends -- the easy thing to get wrong.
      final library = parseObjMaterialLibrary('newmtl only\nKd 1 0 0\n');
      expect(library['only']!.color!.r * 255, closeTo(255, 1));
    });

    test('a material that states nothing is present but has no colour', () {
      final library = parseObjMaterialLibrary('newmtl bare\n');
      expect(library.containsKey('bare'), isTrue);
      expect(library['bare']!.color, isNull);
    });

    test('carriage returns do not become part of a number', () {
      final library = parseObjMaterialLibrary(
        'newmtl thing\r\nKd 1 0 0\r\n',
      );
      expect(library['thing']!.color, isNotNull);
    });

    test('a map_Kd with option flags is left unread rather than guessed', () {
      // The format allows `map_Kd -o 0 0 0 wood.png`. None of the 357 map_Kd
      // lines in this library uses one, and a parser that guessed where the
      // options stop would sometimes apply the wrong texture. Missing beats
      // wrong.
      final library = parseObjMaterialLibrary(
        'newmtl thing\nmap_Kd -o 0 0 0 wood.png\n',
      );
      expect(library['thing']!.diffuseTexture, isNull);
    });

    test('comments and blank lines are ignored', () {
      final library = parseObjMaterialLibrary('''

# newmtl commented
   # Kd 1 1 1

newmtl real
Kd 0 1 0
''');
      expect(library.keys, ['real']);
    });

    test('an empty sidecar is empty, not an error', () {
      expect(parseObjMaterialLibrary(''), isEmpty);
    });
  });

  group('which sidecar an OBJ asks for', () {
    test('mtllib lines are read in order, without duplicates', () {
      const text = 'mtllib first.mtl\nv 0 0 0\nmtllib second.mtl\n'
          'mtllib first.mtl\n';
      expect(objMaterialLibraryNames(text), ['first.mtl', 'second.mtl']);
    });

    test('an OBJ naming none asks for none', () {
      expect(objMaterialLibraryNames('v 0 0 0\nf 1 1 1\n'), isEmpty);
    });
  });

  group('through loadMesh, the way the app reaches it', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('atlas_mtl_');
    });

    tearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });

    String at(String name) => '${workspace.path}${Platform.pathSeparator}$name';

    /// A unit square with two materials, so a lost sidecar shows up as one
    /// colour where there should be two.
    const twoMaterialObj = '''
mtllib part.mtl
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
usemtl red
f 1/1 2/2 3/3
usemtl blue
f 1/1 3/3 4/4
''';

    AssetItem assetAt(String path, String name) => AssetItem(
      id: 'test:$path',
      name: name,
      path: path,
      relativePath: name,
      sourceRoot: workspace.path,
      sourceName: 'kit',
      ext: 'obj',
      type: 'model',
      size: 1,
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      tags: const [],
    );

    test('the sidecar beside the OBJ gives each material its colour',
        () async {
      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      await File(at('part.mtl')).writeAsString(
        'newmtl red\nKd 1 0 0\nnewmtl blue\nKd 0 0 1\n',
        flush: true,
      );

      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      expect(mesh.materials, hasLength(2));
      final colours = mesh.materials.map((material) => material.color).toList();
      expect(colours[0].r * 255, closeTo(255, 1));
      expect(colours[0].b * 255, closeTo(0, 1));
      expect(colours[1].b * 255, closeTo(255, 1));
      expect(colours[1].r * 255, closeTo(0, 1));
    });

    test('no sidecar leaves the materials grey, as before', () async {
      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      expect(mesh.materials, hasLength(2));
      expect(mesh.materials.first.color, mesh.materials.last.color,
          reason: 'with nothing to read, both materials keep the one grey');
    });

    test('a map_Kd texture is resolved and decoded', () async {
      final textures = Directory(at('Textures'))..createSync();
      final png = img.Image(width: 4, height: 4);
      img.fill(png, color: png.getColor(10, 200, 30, 255));
      await File('${textures.path}${Platform.pathSeparator}skin.png')
          .writeAsBytes(img.encodePng(png), flush: true);

      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      await File(at('part.mtl')).writeAsString(
        'newmtl red\nKd 1 0 0\nmap_Kd Textures/skin.png\n'
        'newmtl blue\nKd 0 0 1\n',
        flush: true,
      );

      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      final textured = mesh.materials.first;
      expect(textured.textures, ['Textures/skin.png'],
          reason: 'the reference must be what the sidecar asked for, not the '
              'sidecar filename');
      expect(textured.resolvedTextures, hasLength(1));
      expect(textured.textureWidth, 4);
      expect(textured.textureHeight, 4);
      expect(textured.texturePixels, isNotNull);
      // The second material names no texture and must not inherit the first's.
      expect(mesh.materials.last.resolvedTextures, isEmpty);
      expect(mesh.materials.last.textureWidth, 0);
    });

    test('a map_Kd naming a file that is not there resolves to nothing',
        () async {
      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      await File(at('part.mtl')).writeAsString(
        'newmtl red\nKd 1 0 0\nmap_Kd Textures/absent.png\n'
        'newmtl blue\nKd 0 0 1\n',
        flush: true,
      );

      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      // The reference is kept so the discovery panel can report it missing,
      // but nothing was substituted for it and the Kd colour still applies.
      expect(mesh.materials.first.textures, ['Textures/absent.png']);
      expect(mesh.materials.first.resolvedTextures, isEmpty);
      expect(mesh.materials.first.color.r * 255, closeTo(255, 1));
    });

    test('the mesh no longer offers the .mtl filename as a texture', () async {
      // The bug this file is about: `allTexturePaths` used to contain
      // `part.mtl`, which resolved to no image and was reported as missing.
      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      await File(at('part.mtl')).writeAsString(
        'newmtl red\nKd 1 0 0\nnewmtl blue\nKd 0 0 1\n',
        flush: true,
      );

      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      expect(mesh.allTexturePaths, isNot(contains('part.mtl')));
      expect(mesh.allTexturePaths, isEmpty);
    });

    test('an unreadable sidecar is not fatal to the geometry', () async {
      await File(at('part.obj')).writeAsString(twoMaterialObj, flush: true);
      // A directory where the sidecar should be: reading it throws.
      Directory(at('part.mtl')).createSync();

      final mesh = await loadMesh(assetAt(at('part.obj'), 'part.obj'));
      expect(mesh.faces, hasLength(2),
          reason: 'a sidecar that cannot be read must cost the colours, not '
              'the model');
    });
  });
}
