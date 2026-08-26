import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact shape of the file that crashed the app: macOS writes a small
/// AppleDouble sidecar carrying the shadowed file's extension.
final _appleDoubleStub = <int>[
  0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00,
  ...List<int>.filled(260, 0),
];

void main() {
  group('looksLikePlayableAudio', () {
    test('rejects an AppleDouble stub named .mp3', () {
      expect(looksLikePlayableAudio(_appleDoubleStub, 'mp3'), isFalse);
    });

    test('rejects anything too short to identify', () {
      expect(looksLikePlayableAudio([0xFF, 0xFB], 'mp3'), isFalse);
      expect(looksLikePlayableAudio(const [], 'mp3'), isFalse);
    });

    test('accepts an ID3-tagged mp3', () {
      final bytes = [0x49, 0x44, 0x33, ...List<int>.filled(20, 0)];
      expect(looksLikePlayableAudio(bytes, 'mp3'), isTrue);
    });

    test('accepts a bare MPEG frame sync', () {
      final bytes = [0xFF, 0xFB, ...List<int>.filled(20, 0)];
      expect(looksLikePlayableAudio(bytes, 'mp3'), isTrue);
    });

    test('checks wav for both RIFF and WAVE', () {
      final riffOnly = [
        0x52, 0x49, 0x46, 0x46,
        0, 0, 0, 0,
        0x4A, 0x55, 0x4E, 0x4B, // "JUNK", not "WAVE"
      ];
      expect(looksLikePlayableAudio(riffOnly, 'wav'), isFalse);

      final wave = [
        0x52, 0x49, 0x46, 0x46,
        0, 0, 0, 0,
        0x57, 0x41, 0x56, 0x45,
      ];
      expect(looksLikePlayableAudio(wave, 'wav'), isTrue);
    });

    test('recognises ogg, flac and midi', () {
      expect(
        looksLikePlayableAudio(
          [0x4F, 0x67, 0x67, 0x53, ...List<int>.filled(12, 0)],
          'ogg',
        ),
        isTrue,
      );
      expect(
        looksLikePlayableAudio(
          [0x66, 0x4C, 0x61, 0x43, ...List<int>.filled(12, 0)],
          'flac',
        ),
        isTrue,
      );
      expect(
        looksLikePlayableAudio(
          [0x4D, 0x54, 0x68, 0x64, ...List<int>.filled(12, 0)],
          'midi',
        ),
        isTrue,
      );
    });
  });

  group('AppleDouble files are not cataloged', () {
    test('isAppleDoubleName spots the sidecar naming', () {
      expect(isAppleDoubleName('._track.mp3'), isTrue);
      expect(isAppleDoubleName('track.mp3'), isFalse);
      expect(isAppleDoubleName('_track.mp3'), isFalse);
    });

    test('a scan skips ._ files on disk', () async {
      final root = await Directory.systemTemp.createTemp('asset_atlas_apple_');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final separator = Platform.pathSeparator;
      await File('${root.path}${separator}track.mp3').writeAsBytes([
        0x49, 0x44, 0x33,
        ...List<int>.filled(64, 0),
      ]);
      await File(
        '${root.path}$separator._track.mp3',
      ).writeAsBytes(_appleDoubleStub);

      final scan = await scanAssetFolder(root.path, onStatus: (_) {});
      expect(scan.assets.map((asset) => asset.name), ['track.mp3']);
    });

    test('a scan skips __MACOSX and ._ entries inside archives', () async {
      final root = await Directory.systemTemp.createTemp('asset_atlas_apple_z');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });

      final archive = Archive()
        ..addFile(ArchiveFile('music/track.mp3', 8, [0x49, 0x44, 0x33, 0, 0, 0, 0, 0]))
        ..addFile(
          ArchiveFile(
            '__MACOSX/music/._track.mp3',
            _appleDoubleStub.length,
            _appleDoubleStub,
          ),
        )
        ..addFile(
          ArchiveFile(
            'music/._track.mp3',
            _appleDoubleStub.length,
            _appleDoubleStub,
          ),
        );
      await File(
        '${root.path}${Platform.pathSeparator}pack.zip',
      ).writeAsBytes(ZipEncoder().encode(archive), flush: true);

      final scan = await scanAssetFolder(root.path, onStatus: (_) {});
      expect(scan.assets.map((asset) => asset.name), ['track.mp3']);
    });
  });
}
