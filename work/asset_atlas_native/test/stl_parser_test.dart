import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading STL, which the library holds 2,843 of and could not draw.
///
/// The format is triangles and nothing else, so most of what can go wrong is
/// in telling the two encodings apart -- and the usual way of doing that,
/// looking for the word "solid", is wrong for a large share of real files.
void main() {
  /// A binary STL. `header` fills the 80 bytes nothing is supposed to read.
  Uint8List binaryStl(List<List<double>> triangles, {String header = ''}) {
    final bytes = Uint8List(84 + triangles.length * 50);
    final data = ByteData.sublistView(bytes);
    final headerBytes = utf8.encode(header);
    for (var index = 0; index < headerBytes.length && index < 80; index += 1) {
      bytes[index] = headerBytes[index];
    }
    data.setUint32(80, triangles.length, Endian.little);
    for (var triangle = 0; triangle < triangles.length; triangle += 1) {
      final at = 84 + triangle * 50;
      // A deliberately wrong facet normal, to prove nothing reads it.
      data.setFloat32(at, 999, Endian.little);
      data.setFloat32(at + 4, 999, Endian.little);
      data.setFloat32(at + 8, 999, Endian.little);
      final corners = triangles[triangle];
      for (var value = 0; value < 9; value += 1) {
        data.setFloat32(at + 12 + value * 4, corners[value], Endian.little);
      }
      data.setUint16(at + 48, 0, Endian.little);
    }
    return bytes;
  }

  const oneTriangle = [
    [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
  ];
  const twoTriangles = [
    [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
    [1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0],
  ];

  String asciiStl(List<List<double>> triangles, {String name = 'thing'}) {
    final lines = <String>['solid $name'];
    for (final corners in triangles) {
      lines.add('  facet normal 0 0 1');
      lines.add('    outer loop');
      for (var corner = 0; corner < 3; corner += 1) {
        final at = corner * 3;
        lines.add('      vertex ${corners[at]} ${corners[at + 1]} '
            '${corners[at + 2]}');
      }
      lines.add('    endloop');
      lines.add('  endfacet');
    }
    lines.add('endsolid $name');
    return lines.join('\n');
  }

  group('telling the two encodings apart', () {
    test('a binary file is read as binary', () {
      expect(looksLikeBinaryStl(binaryStl(twoTriangles)), isTrue);
    });

    test('a binary file whose header begins "solid" is still binary', () {
      // The trap. Exporters write their product name into the header and it
      // routinely starts with this word, so looking for it reads a perfectly
      // good binary file as ASCII and finds no geometry in it.
      final bytes = binaryStl(twoTriangles, header: 'solid SolidWorks export');
      expect(looksLikeBinaryStl(bytes), isTrue);
      final mesh = parseStlMesh(bytes, 'thing.stl');
      expect(mesh.faces, hasLength(2));
    });

    test('an ASCII file is not read as binary', () {
      final bytes = Uint8List.fromList(utf8.encode(asciiStl(twoTriangles)));
      expect(looksLikeBinaryStl(bytes), isFalse);
    });

    test('a long ASCII file is still not read as binary', () {
      // The arithmetic has to hold for a file long enough that some count
      // read out of its text could plausibly fit.
      final many = [for (var index = 0; index < 400; index += 1) oneTriangle.first];
      final bytes = Uint8List.fromList(utf8.encode(asciiStl(many)));
      expect(looksLikeBinaryStl(bytes), isFalse);
      expect(parseStlMesh(bytes, 'thing.stl').faces, hasLength(400));
    });

    test('something far too short is not binary', () {
      expect(looksLikeBinaryStl(Uint8List(20)), isFalse);
    });
  });

  group('binary', () {
    test('every triangle becomes a face of three corners', () {
      final mesh = parseStlMesh(binaryStl(twoTriangles), 'thing.stl');
      expect(mesh.faces, hasLength(2));
      expect(mesh.faces.every((face) => face.indices.length == 3), isTrue);
      expect(mesh.vertices, hasLength(6));
    });

    test('the corners are the corners, not the facet normal', () {
      // The fixture writes 999 into every normal, so reading the wrong
      // offset puts the model a thousand units away and this catches it.
      final mesh = parseStlMesh(binaryStl(oneTriangle), 'thing.stl');
      final corners = mesh.faces.single.indices
          .map((index) => mesh.vertices[index])
          .toList();
      // MeshModel.normalized recentres and rescales, so the test is about
      // the shape rather than the absolute numbers: a unit right triangle
      // has two edges of equal length meeting at a right angle.
      double distance(Vec3 a, Vec3 b) {
        final dx = a.x - b.x;
        final dy = a.y - b.y;
        final dz = a.z - b.z;
        return dx * dx + dy * dy + dz * dz;
      }

      final ab = distance(corners[0], corners[1]);
      final ac = distance(corners[0], corners[2]);
      final bc = distance(corners[1], corners[2]);
      expect(ab, closeTo(ac, ab * 1e-6));
      expect(bc, closeTo(ab * 2, ab * 1e-6));
    });

    test('trailing bytes after the last triangle are tolerated', () {
      final padded = Uint8List.fromList(
        [...binaryStl(twoTriangles), 0, 0, 0, 0, 0],
      );
      expect(parseStlMesh(padded, 'thing.stl').faces, hasLength(2));
    });

    test('a count larger than the file stops at what is there', () {
      final bytes = binaryStl(twoTriangles);
      ByteData.sublistView(bytes, 80, 84).setUint32(0, 9000, Endian.little);
      // It no longer looks binary by the length test, so it falls through to
      // the ASCII reader and finds nothing -- which is the honest answer for
      // a file whose header disagrees with its contents.
      expect(() => parseStlMesh(bytes, 'thing.stl'),
          throwsA(isA<FormatException>()));
    });
  });

  group('ASCII', () {
    test('every facet becomes a face', () {
      final bytes = Uint8List.fromList(utf8.encode(asciiStl(twoTriangles)));
      final mesh = parseStlMesh(bytes, 'thing.stl');
      expect(mesh.faces, hasLength(2));
      expect(mesh.vertices, hasLength(6));
    });

    test('upper case keywords are read too', () {
      final shouted = asciiStl(oneTriangle)
          .replaceAll('vertex', 'VERTEX')
          .replaceAll('facet', 'FACET');
      final bytes = Uint8List.fromList(utf8.encode(shouted));
      expect(parseStlMesh(bytes, 'thing.stl').faces, hasLength(1));
    });

    test('carriage returns do not become part of a number', () {
      final windows = asciiStl(twoTriangles).replaceAll('\n', '\r\n');
      final bytes = Uint8List.fromList(utf8.encode(windows));
      expect(parseStlMesh(bytes, 'thing.stl').faces, hasLength(2));
    });

    test('a facet cut short contributes nothing', () {
      final truncated = asciiStl(twoTriangles)
          .split('\n')
          .takeWhile((line) => !line.contains('1.0 1.0 0.0'))
          .join('\n');
      final bytes = Uint8List.fromList(utf8.encode(truncated));
      // The first facet is whole and the second is not.
      expect(parseStlMesh(bytes, 'thing.stl').faces, hasLength(1));
    });
  });

  group('nothing to draw', () {
    test('an empty file says so rather than returning an empty mesh', () {
      expect(() => parseStlMesh(Uint8List(0), 'thing.stl'),
          throwsA(isA<FormatException>()));
    });

    test('a file with a header and no triangles says so', () {
      final header = Uint8List(84);
      expect(() => parseStlMesh(header, 'thing.stl'),
          throwsA(isA<FormatException>()));
    });

    test('text that is not STL at all says so', () {
      final bytes = Uint8List.fromList(utf8.encode('hello, not a model'));
      expect(() => parseStlMesh(bytes, 'thing.stl'),
          throwsA(isA<FormatException>()));
    });
  });

  group('through loadMesh, the way the app reaches it', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('atlas_stl_');
    });

    tearDown(() async {
      if (workspace.existsSync()) await workspace.delete(recursive: true);
    });

    AssetItem assetAt(String path, String name) => AssetItem(
      id: 'test:$path',
      name: name,
      path: path,
      relativePath: name,
      sourceRoot: workspace.path,
      sourceName: 'kit',
      ext: 'stl',
      type: 'model',
      size: 1,
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      tags: const [],
    );

    test('a binary STL on disk loads', () async {
      final file = File('${workspace.path}${Platform.pathSeparator}part.stl');
      await file.writeAsBytes(binaryStl(twoTriangles), flush: true);
      final mesh = await loadMesh(assetAt(file.path, 'part.stl'));
      expect(mesh.faces, hasLength(2));
      // One flat material, which is everything the format can describe.
      expect(mesh.materials, hasLength(1));
      expect(mesh.materials.single.textures, isEmpty);
    });

    test('an ASCII STL on disk loads', () async {
      final file = File('${workspace.path}${Platform.pathSeparator}part.stl');
      await file.writeAsString(asciiStl(twoTriangles), flush: true);
      final mesh = await loadMesh(assetAt(file.path, 'part.stl'));
      expect(mesh.faces, hasLength(2));
    });

    test('STL is a format the discovery panel will talk about', () {
      // Without this the panel treats an STL as something it cannot read and
      // says nothing, which is how 2,843 files looked before.
      expect(previewableModelExts, contains('stl'));
    });
  });
}
