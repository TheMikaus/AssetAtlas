import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an isolate scan matches a direct scan of the same folder', () async {
    final fixtureRoot = Directory('test/fixtures/corpus').absolute.path;

    final direct = await scanAssetFolder(fixtureRoot, onStatus: (_) {});
    final handle = await startFolderScan(fixtureRoot, onStatus: (_) {});
    final viaIsolate = await handle.result;

    expect(viaIsolate.assets.length, direct.assets.length);
    expect(viaIsolate.skippedUnsupported, direct.skippedUnsupported);
    expect(viaIsolate.skippedBinaryObj, direct.skippedBinaryObj);
    expect(
      viaIsolate.assets.map((asset) => asset.id).toSet(),
      direct.assets.map((asset) => asset.id).toSet(),
      reason: 'crossing an isolate must not change what was found',
    );

    // Field-level check on one asset: everything has to survive the copy.
    final byId = {for (final asset in direct.assets) asset.id: asset};
    for (final asset in viaIsolate.assets) {
      final original = byId[asset.id]!;
      expect(asset.name, original.name);
      expect(asset.path, original.path);
      expect(asset.relativePath, original.relativePath);
      expect(asset.type, original.type);
      expect(asset.size, original.size);
      expect(asset.modified, original.modified);
      expect(asset.tags, original.tags);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('progress is reported while the scan runs', () async {
    final root = await Directory.systemTemp.createTemp('asset_atlas_progress_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    // Enough files that the scanner's periodic report fires.
    final separator = Platform.pathSeparator;
    for (var i = 0; i < 600; i += 1) {
      await File('${root.path}${separator}asset_$i.png').writeAsBytes([
        0x89, 0x50, 0x4E, 0x47,
      ]);
    }

    final statuses = <ScanStatus>[];
    final handle = await startFolderScan(root.path, onStatus: statuses.add);
    final result = await handle.result;

    expect(result.assets, hasLength(600));
    expect(
      statuses,
      isNotEmpty,
      reason: 'the UI has to be able to show that something is happening',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a cancelled scan reports cancellation rather than a result', () async {
    final root = await Directory.systemTemp.createTemp('asset_atlas_cancel_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    // A ZIP big enough that the scan is still busy when cancel lands.
    final archive = Archive();
    for (var i = 0; i < 4000; i += 1) {
      archive.addFile(
        ArchiveFile('models/model_$i.obj', 12, 'v 0 0 0\nv 1 1 1'.codeUnits),
      );
    }
    await File(
      '${root.path}${Platform.pathSeparator}big.zip',
    ).writeAsBytes(ZipEncoder().encode(archive), flush: true);

    final handle = await startFolderScan(root.path, onStatus: (_) {});
    handle.cancel();

    expect(handle.cancelled, isTrue);
    await expectLater(handle.result, throwsA(isA<ScanCancelledException>()));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cancelling twice is harmless', () async {
    final root = await Directory.systemTemp.createTemp('asset_atlas_cancel2_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    final handle = await startFolderScan(root.path, onStatus: (_) {});
    handle.cancel();
    handle.cancel();
    expect(handle.cancelled, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
