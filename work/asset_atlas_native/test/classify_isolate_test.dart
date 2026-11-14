import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';

AssetItem _fbx(String id, String path) => AssetItem(
  id: id,
  name: path.split(RegExp(r'[\\/]')).last,
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

/// Stands in for the object that used to own the classification loop.
///
/// It holds something unsendable, exactly like a State holding a widget tree:
/// if the isolate launcher captured `this`, the message could not cross.
class _Owner {
  final ReceivePort port = ReceivePort();

  Future<Map<String, String>> classify(FbxClassifyChunk chunk) {
    // Touching an instance member is the point: it is what pulled `this` into
    // the closure context before.
    if (port.hashCode == -1) return Future.value(const {});
    return runFbxClassifyChunk(chunk);
  }

  void dispose() => port.close();
}

void main() {
  group('buildFbxClassifyChunks', () {
    test('groups by container so a worker opens each archive once', () {
      final assets = [
        _fbx('a', buildZipVirtualPath(r'C:\packs\one.zip', 'a.fbx')),
        _fbx('b', buildZipVirtualPath(r'C:\packs\two.zip', 'b.fbx')),
        _fbx('c', buildZipVirtualPath(r'C:\packs\one.zip', 'c.fbx')),
        _fbx('d', r'C:\packs\loose.fbx'),
      ];

      final chunks = buildFbxClassifyChunks(
        assets: assets,
        helperPath: 'helper.exe',
      );

      expect(chunks, hasLength(3));
      final containers = chunks.map((chunk) => chunk.containerPath).toList();
      expect(containers, contains(null));
      expect(containers.where((c) => c?.endsWith('one.zip') ?? false), hasLength(1));

      final one = chunks.firstWhere(
        (chunk) => chunk.containerPath?.endsWith('one.zip') ?? false,
      );
      expect(one.assetIds, ['a', 'c']);
    });

    test('splits a large container into chunks', () {
      final assets = [
        for (var i = 0; i < 950; i += 1)
          _fbx('a$i', buildZipVirtualPath(r'C:\packs\big.zip', 'a$i.fbx')),
      ];
      final chunks = buildFbxClassifyChunks(
        assets: assets,
        helperPath: 'helper.exe',
        chunkSize: 400,
      );
      expect(chunks.map((chunk) => chunk.length), [400, 400, 150]);
    });
  });

  test('the isolate launcher is sendable from inside an object', () async {
    // Regression test. The launcher used to be an inline closure in a State
    // method, which captured `this` and therefore the whole widget tree:
    // every chunk failed with "object is unsendable", and the app recorded
    // 26,237 files as unreadable.
    final root = await Directory.systemTemp.createTemp('asset_atlas_iso_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final zipPath = '${root.path}${Platform.pathSeparator}pack.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('models/not_really.fbx', 4, [1, 2, 3, 4]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    final chunk = FbxClassifyChunk(
      // No helper needed: the point is that the message crosses the boundary.
      helperPath: '${root.path}${Platform.pathSeparator}missing_helper.exe',
      containerPath: zipPath,
      assetIds: const ['id-1'],
      assetPaths: [buildZipVirtualPath(zipPath, 'models/not_really.fbx')],
    );

    final owner = _Owner();
    addTearDown(owner.dispose);

    // Completing at all is the guard: an unsendable capture throws out of
    // Isolate.run rather than coming back with the wrong answer.
    final kinds = await owner.classify(chunk);

    // And nothing is recorded, because nothing was learned. The helper was
    // never run, so there is no verdict about this file -- and 'unreadable'
    // is a verdict. Writing it here is the second half of the bug above: the
    // unsendable launcher is what made every chunk fail, and recording our
    // own failure as the file's property is what turned that into 26,237
    // permanently misclassified assets. Classification is lazy and skips
    // anything that already has a kind, so such a row never heals. Absent
    // means a later pass tries again.
    expect(
      kinds,
      isEmpty,
      reason: 'a failure of ours is not a fact about the file',
    );
  });

  test('a chunk that crosses with a working helper comes back judged',
      () async {
    // Without this, the test above would keep passing if the message stopped
    // crossing entirely: "nothing recorded" is what both a missing helper and
    // a broken boundary look like. Here the helper exists, so a crossing that
    // works has to produce a verdict.
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    final root = await Directory.systemTemp.createTemp('asset_atlas_iso_ok_');
    addTearDown(() async {
      closeCachedArchives();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final zipPath = '${root.path}${Platform.pathSeparator}pack.zip';
    final archive = Archive()
      ..addFile(ArchiveFile('models/not_really.fbx', 4, [1, 2, 3, 4]));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    final chunk = FbxClassifyChunk(
      helperPath: helper.absolute.path,
      containerPath: zipPath,
      assetIds: const ['id-1'],
      assetPaths: [buildZipVirtualPath(zipPath, 'models/not_really.fbx')],
    );

    final owner = _Owner();
    addTearDown(owner.dispose);

    final kinds = await owner.classify(chunk);

    // Four bytes of nonsense is not an FBX, and this time something actually
    // looked: the helper ran and rejected it, which is a real answer.
    expect(kinds['id-1'], 'unreadable');
  });
}
