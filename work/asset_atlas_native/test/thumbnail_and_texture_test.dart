import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _image(String relativePath, {bool referenced = false}) {
  final name = relativePath.split('/').last;
  return AssetItem(
    id: relativePath,
    name: name,
    path: r'C:\Packs\' + relativePath.replaceAll('/', r'\'),
    relativePath: relativePath,
    sourceRoot: r'C:\Packs',
    sourceName: 'Packs',
    ext: name.split('.').last,
    type: 'image',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
    referencedByModel: referenced,
  );
}

void main() {
  group('telling textures from other images', () {
    test('an image in a Textures folder reads as a texture', () {
      expect(
        _image('Synty/Airport/Textures/atlas.png').effectiveType,
        'texture',
      );
      expect(
        _image('Synty/Airport/Materials/skin.png').effectiveType,
        'texture',
      );
    });

    test('an ordinary image stays an image', () {
      expect(_image('Synty/Airport/Icons/logo.png').effectiveType, 'image');
      expect(_image('Docs/screenshot.png').effectiveType, 'image');
    });

    test('a folder merely containing the word is not enough', () {
      // "TextureWork" is not a Textures folder, and neither is a file called
      // texture.png sitting somewhere unrelated.
      expect(
        _image('Synty/TextureWork/notes.png').effectiveType,
        'image',
        reason: 'the segment has to be the whole folder name',
      );
    });

    test('being used by a model wins over location', () {
      expect(
        _image('Synty/Airport/Icons/logo.png', referenced: true).effectiveType,
        'texture',
        reason: 'a model using it is evidence, not a guess',
      );
    });

    test('looksLikeTextureLocation handles both separators', () {
      expect(looksLikeTextureLocation(r'Synty\Airport\Textures\a.png'), isTrue);
      expect(looksLikeTextureLocation('Synty/Airport/textures/a.png'), isTrue);
      expect(looksLikeTextureLocation('Synty/Airport/Meshes/a.png'), isFalse);
    });
  });

  group('model thumbnails', () {
    setUp(() {
      ModelThumbnailCache.clear();
      ModelThumbnailCache.renderCount = 0;
      MeshLoadCache.clear();
    });
    tearDown(ModelThumbnailCache.clear);

    test('renders a square image for a real mesh', () async {
      final helper = File(
        'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
      );
      if (!helper.existsSync()) {
        markTestSkipped('Build the Windows app before running native tests.');
        return;
      }

      final path = File(
        'test/fixtures/fbx/transformed_uv_embedded.fbx',
      ).absolute.path;
      final asset = AssetItem(
        id: 'thumb-mesh',
        name: 'transformed_uv_embedded.fbx',
        path: path,
        relativePath: 'transformed_uv_embedded.fbx',
        sourceRoot: File(path).parent.path,
        sourceName: 'fixtures',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
      );

      final image = await renderModelThumbnail(asset);
      expect(image, isNotNull);
      expect(image!.width, ModelThumbnailCache.size);
      expect(image.height, ModelThumbnailCache.size);
      image.dispose();
    });

    test('an animation clip has nothing to draw', () async {
      final helper = File(
        'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
      );
      if (!helper.existsSync()) {
        markTestSkipped('Build the Windows app before running native tests.');
        return;
      }

      final path = File('test/fixtures/fbx/animation_only.fbx').absolute.path;
      final asset = AssetItem(
        id: 'thumb-anim',
        name: 'animation_only.fbx',
        path: path,
        relativePath: 'animation_only.fbx',
        sourceRoot: File(path).parent.path,
        sourceName: 'fixtures',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
      );

      expect(await renderModelThumbnail(asset), isNull);
    });

    test('a scrolling flood does not queue unbounded work', () {
      AssetItem model(int i) => AssetItem(
        id: 'm$i',
        name: 'm$i.fbx',
        path: r'C:\nope\m$i.fbx',
        relativePath: 'm$i.fbx',
        sourceRoot: r'C:\nope',
        sourceName: 'nope',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
      );

      // Stand in for flinging through a grid of tens of thousands of models.
      for (var i = 0; i < 500; i += 1) {
        ModelThumbnailCache.imageFor(model(i), const []);
      }

      expect(
        ModelThumbnailCache.queuedCount,
        lessThanOrEqualTo(ModelThumbnailCache.maxQueued),
      );
    });

    test('disabled means no render is even attempted', () {
      ModelThumbnailCache.enabled = false;
      addTearDown(() => ModelThumbnailCache.enabled = true);

      final asset = AssetItem(
        id: 'thumb-off',
        name: 'x.fbx',
        path: r'C:\nope\x.fbx',
        relativePath: 'x.fbx',
        sourceRoot: r'C:\nope',
        sourceName: 'nope',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
      );

      expect(ModelThumbnailCache.imageFor(asset, const []), isNull);
      expect(ModelThumbnailCache.renderCount, 0);
    });
  });
}
