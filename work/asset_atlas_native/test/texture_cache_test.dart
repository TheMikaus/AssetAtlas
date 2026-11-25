import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:asset_atlas_native/main.dart';

/// The texture cache, and the one thing it must not change: what gets drawn.
///
/// Every asset in a pack names the same atlas, and the whole of it used to be
/// read and decoded again for each one. Caching the decoded pixels is only
/// worth having if the image a material ends up holding is the same image, so
/// the round trip through raw pixels is tested first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final originalBudget = maxTextureBitmapCacheBytes;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('atlas_texture_cache');
    clearTextureBitmapCache();
  });

  tearDown(() {
    maxTextureBitmapCacheBytes = originalBudget;
    clearTextureBitmapCache();
    try {
      workspace.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A PNG with a recognisable pattern, so a wrong round trip shows up as
  /// wrong pixels rather than as the right size of nothing.
  String writePng(String name, int width, int height, {int shift = 0}) {
    final picture = img.Image(width: width, height: height);
    for (var y = 0; y < height; y += 1) {
      for (var x = 0; x < width; x += 1) {
        picture.setPixelRgba(
          x,
          y,
          (x * 7 + shift) % 256,
          (y * 11 + shift) % 256,
          ((x + y) * 3 + shift) % 256,
          255,
        );
      }
    }
    final path = '${workspace.path}${Platform.pathSeparator}$name';
    File(path).writeAsBytesSync(img.encodePng(picture));
    return path;
  }

  group('what gets drawn does not change', () {
    test('pixels survive the trip back into an image', () async {
      final path = writePng('atlas.png', 64, 48);
      final bitmap = await textureBitmap(path);
      expect(bitmap, isNotNull);
      expect(bitmap!.width, 64);
      expect(bitmap.height, 48);

      final image = await imageFromRgba(
        bitmap.rgba,
        bitmap.width,
        bitmap.height,
      );
      addTearDown(image.dispose);
      expect(image.width, 64);
      expect(image.height, 48);

      final readBack = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(readBack, isNotNull);
      expect(
        readBack!.buffer.asUint8List(),
        bitmap.rgba,
        reason: 'the image a material holds must be the texture that was read',
      );
    });

    test('and every caller gets its own image to dispose', () async {
      // The reason the cache holds pixels and not images: widgets dispose
      // what they are handed, and two materials sharing one image would be
      // a use-after-dispose.
      final path = writePng('shared.png', 32, 32);
      final first = await firstTextureImage([path]);
      final second = await firstTextureImage([path]);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(identical(first, second), isFalse);
      first!.dispose();
      expect(second!.width, 32);
      second.dispose();
    });

    test('the average colour is the average of those same pixels', () async {
      final path = writePng('flat.png', 16, 16);
      final bitmap = await textureBitmap(path);
      expect(bitmap!.averageColor, averageColorOfRgba(bitmap.rgba));
      expect(await averageImageColor(path), bitmap.averageColor);
    });

    test('a fully transparent texture averages to nothing', () async {
      // numChannels: 4 matters -- the default is three, which would drop the
      // alpha and make this a test of an opaque texture.
      final picture = img.Image(width: 8, height: 8, numChannels: 4);
      for (var y = 0; y < 8; y += 1) {
        for (var x = 0; x < 8; x += 1) {
          picture.setPixelRgba(x, y, 200, 100, 50, 0);
        }
      }
      final path = '${workspace.path}${Platform.pathSeparator}clear.png';
      File(path).writeAsBytesSync(img.encodePng(picture));
      expect(await averageImageColor(path), isNull);
    });
  });

  group('the cache', () {
    test('reads a texture once however often it is asked for', () async {
      final path = writePng('once.png', 32, 32);
      final first = await textureBitmap(path);
      final second = await textureBitmap(path);
      expect(identical(first, second), isTrue);
      expect(textureBitmapCacheCount, 1);
    });

    test('and once when four lanes ask at the same moment', () async {
      // The render lanes run concurrently, so without this the first pack
      // texture would be read four times before any of them finished.
      final path = writePng('lanes.png', 64, 64);
      final answers = await Future.wait([
        textureBitmap(path),
        textureBitmap(path),
        textureBitmap(path),
        textureBitmap(path),
      ]);
      expect(answers.every((bitmap) => identical(bitmap, answers.first)), isTrue);
      expect(textureBitmapCacheCount, 1);
    });

    test('counts what it is holding', () async {
      final path = writePng('weight.png', 40, 20);
      final bitmap = await textureBitmap(path);
      expect(bitmap!.byteCount, 40 * 20 * 4);
      expect(textureBitmapCacheBytes, bitmap.byteCount);
    });

    test('notices a texture replaced on disk', () async {
      final path = writePng('replaced.png', 16, 16);
      final before = await textureBitmap(path);

      // A rewrite inside the same clock tick must still be noticed, so the
      // state key has to see the size change as well as the timestamp.
      final picture = img.Image(width: 32, height: 32);
      for (var y = 0; y < 32; y += 1) {
        for (var x = 0; x < 32; x += 1) {
          picture.setPixelRgba(x, y, 1, 2, 3, 255);
        }
      }
      File(path).writeAsBytesSync(img.encodePng(picture));

      final after = await textureBitmap(path);
      expect(after, isNotNull);
      expect(identical(after, before), isFalse);
      expect(after!.width, 32);
    });

    test('forgets nothing it was never able to read', () async {
      final missing = '${workspace.path}${Platform.pathSeparator}absent.png';
      expect(await textureBitmap(missing), isNull);
      expect(textureBitmapCacheCount, 0);

      final corrupt = '${workspace.path}${Platform.pathSeparator}broken.png';
      File(corrupt).writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await textureBitmap(corrupt), isNull);
      expect(textureBitmapCacheCount, 0,
          reason: 'a texture that becomes readable later must get another go');
    });

    test('skips to the next candidate when one will not decode', () async {
      final corrupt = '${workspace.path}${Platform.pathSeparator}bad.png';
      File(corrupt).writeAsBytesSync(Uint8List.fromList([9, 9, 9]));
      final good = writePng('good.png', 8, 8);
      final bitmap = await firstTextureBitmap([corrupt, good]);
      expect(bitmap, isNotNull);
      expect(bitmap!.width, 8);
    });

    test('ignores candidates that are not images at all', () async {
      final model = '${workspace.path}${Platform.pathSeparator}thing.fbx';
      File(model).writeAsBytesSync(Uint8List.fromList([0, 1, 2]));
      expect(await firstTextureBitmap([model]), isNull);
      expect(await firstTextureBitmap(const []), isNull);
    });
  });

  group('the budget', () {
    test('evicts the least recently used until it fits', () async {
      // Two 64x64 textures are 16KB each decoded.
      maxTextureBitmapCacheBytes = 64 * 64 * 4 * 2;
      final first = writePng('a.png', 64, 64, shift: 1);
      final second = writePng('b.png', 64, 64, shift: 2);
      final third = writePng('c.png', 64, 64, shift: 3);

      await textureBitmap(first);
      await textureBitmap(second);
      expect(textureBitmapCacheCount, 2);
      expect(textureBitmapCacheBytes, lessThanOrEqualTo(maxTextureBitmapCacheBytes));

      // Touch the first so the second becomes the least recent.
      await textureBitmap(first);
      await textureBitmap(third);

      expect(textureBitmapCacheCount, 2);
      expect(textureBitmapCacheBytes, lessThanOrEqualTo(maxTextureBitmapCacheBytes));
      // The promoted one is still held; asking again does not re-read it.
      final again = await textureBitmap(first);
      expect(textureBitmapCacheCount, 2);
      expect(again, isNotNull);
    });

    test('uses a texture too big to keep without emptying itself', () async {
      maxTextureBitmapCacheBytes = 32 * 32 * 4;
      final small = writePng('small.png', 32, 32);
      await textureBitmap(small);
      expect(textureBitmapCacheCount, 1);

      final huge = writePng('huge.png', 128, 128);
      final bitmap = await textureBitmap(huge);
      expect(bitmap, isNotNull, reason: 'it is still used, just not kept');
      expect(bitmap!.width, 128);
      expect(textureBitmapCacheCount, 1);
      expect(textureBitmapCacheBytes, 32 * 32 * 4);
    });
  });
}
