import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The nearby-texture walk, which was running once per dragged frame.
///
/// [findNearbyTextures] is called from inside two `build` methods -- the
/// viewer's texture picker and the discovery panel -- and the viewport calls
/// `setState` on every pointer move. So moving the camera walked the whole
/// catalog per frame, and every asset with a texture extension paid two regex
/// replaces in `parentPath` on the way past.
///
/// It was survivable at 221,183 assets and stopped being survivable when a
/// rescan took the library to 327,365. The walk did not change; there is just
/// more of it. So these tests are about the memo in front of it: that it
/// gives the same answer as the walk, that it is actually cheaper, and that
/// it notices a new catalog.
void main() {
  /// A catalog shaped like the real one: models in a kit folder with a
  /// `Textures` folder beside them, and a long tail of assets elsewhere that
  /// the walk has to reject one at a time.
  List<AssetItem> catalogOf({required int textures, required int elsewhere}) {
    final assets = <AssetItem>[];

    AssetItem at(String path, String ext, String type) => AssetItem(
      id: 'test:$path',
      name: path.split(r'\').last,
      path: path,
      relativePath: path,
      sourceRoot: r'Z:\Assets',
      sourceName: 'kit',
      ext: ext,
      type: type,
      size: 1024,
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      tags: const [],
    );

    // Built by joining rather than interpolating into a raw string: a raw
    // string would put a literal "$index" in every path and the fixture
    // would quietly collapse to one texture.
    const kitTextures = r'Z:\Assets\Kit\Textures\atlas_';
    const otherSprites = r'Z:\Assets\OtherPack\Sprites\icon_';

    assets.add(at(r'Z:\Assets\Kit\Models\barn.obj', 'obj', 'model'));
    for (var index = 0; index < textures; index += 1) {
      assets.add(at('$kitTextures$index.png', 'png', 'texture'));
    }
    // The tail. Texture extensions, so they survive the cheap extension
    // check and reach the path work, but in a folder that cannot match.
    for (var index = 0; index < elsewhere; index += 1) {
      assets.add(at('$otherSprites$index.png', 'png', 'texture'));
    }
    return assets;
  }

  AssetItem modelOf(List<AssetItem> catalog) =>
      catalog.firstWhere((asset) => asset.ext == 'obj');

  test('the memo returns exactly what the walk returns', () {
    final catalog = catalogOf(textures: 24, elsewhere: 300);
    final model = modelOf(catalog);

    final walked = findNearbyTextures(model, catalog, byScan: true);
    final memoised = findNearbyTextures(model, catalog);

    expect(memoised.map((asset) => asset.path).toList(),
        walked.map((asset) => asset.path).toList());
    expect(walked, isNotEmpty, reason: 'a test over an empty answer proves '
        'nothing -- the fixture must actually find textures');
  });

  test('asking twice costs far less than asking twice', () {
    // The regression this file exists for. Before the memo both calls walked,
    // so the ratio was about 1; a frame of dragging paid the whole walk.
    // 40,000 rather than the real 327,365, and ten frames rather than sixty:
    // the cost is linear in both, so a tenth of the work shows the same ratio
    // without putting half a minute into the ordinary suite.
    const tail = 40000;
    const frames = 10;
    final catalog = catalogOf(textures: 40, elsewhere: tail);
    final model = modelOf(catalog);

    // Both measured here, in one process against identical data, because a
    // figure for one without the other is not a comparison -- and `byScan` is
    // what the code did before the memo, so this is a before and after rather
    // than an assertion about a remembered number.
    final firstAnswer = findNearbyTextures(model, catalog);
    expect(firstAnswer, isNotEmpty);

    final scanned = Stopwatch()..start();
    for (var frame = 0; frame < frames; frame += 1) {
      findNearbyTextures(model, catalog, byScan: true);
    }
    scanned.stop();

    final memoised = Stopwatch()..start();
    for (var frame = 0; frame < frames; frame += 1) {
      findNearbyTextures(model, catalog);
    }
    memoised.stop();

    final perScannedFrame = scanned.elapsedMicroseconds / frames;
    final perMemoisedFrame = memoised.elapsedMicroseconds / frames;
    // ignore: avoid_print
    print('${catalog.length} assets: walk ${perScannedFrame.round()}us/frame, '
        'memo ${perMemoisedFrame.round()}us/frame');

    expect(
      memoised.elapsedMicroseconds * 20,
      lessThan(scanned.elapsedMicroseconds),
      reason: 'a dragged frame must not pay for the walk; '
          'walk=${perScannedFrame.round()}us '
          'memo=${perMemoisedFrame.round()}us per frame',
    );
  });

  test('a new catalog is not answered out of the old one', () {
    final before = catalogOf(textures: 4, elsewhere: 10);
    final model = modelOf(before);
    final firstAnswer = findNearbyTextures(model, before);
    expect(firstAnswer, hasLength(4));

    // A rescan hands out fresh AssetItem objects, so the list is a different
    // object with a different length: both halves of the identity change.
    final after = catalogOf(textures: 9, elsewhere: 10);
    final secondAnswer = findNearbyTextures(modelOf(after), after);
    expect(secondAnswer, hasLength(9),
        reason: 'a stale answer here would be a picker listing textures from '
            'before the rescan');
  });

  test('a list shared between callers cannot be edited by one of them', () {
    // The answer is now one object handed to the picker, the discovery panel
    // and the validation sweep. A caller that sorted it in place would have
    // been editing the cache.
    final catalog = catalogOf(textures: 3, elsewhere: 5);
    final answer = findNearbyTextures(modelOf(catalog), catalog);
    expect(() => answer.sort((a, b) => 0), throwsUnsupportedError);
  });

  test('two models in one catalog each get their own answer', () {
    // A one-entry cache would have the validation sweep evict the viewer's
    // answer on every asset it looked at.
    final catalog = catalogOf(textures: 6, elsewhere: 20);
    final model = modelOf(catalog);
    final stranger = catalog.firstWhere(
      (asset) => asset.path.contains('OtherPack'),
    );

    final forModel = findNearbyTextures(model, catalog);
    final forStranger = findNearbyTextures(stranger, catalog);
    final forModelAgain = findNearbyTextures(model, catalog);

    // The two answers differ in the stranger's own folder. They overlap on
    // the Kit's `Textures` folder, which the walk offers to everything under
    // the same source root -- long-standing behaviour, and not what this test
    // is about: what matters is that one model's answer is not served for
    // another's.
    expect(forModel.map((asset) => asset.path),
        isNot(contains(r'Z:\Assets\OtherPack\Sprites\icon_0.png')));
    expect(forStranger.map((asset) => asset.path),
        contains(r'Z:\Assets\OtherPack\Sprites\icon_0.png'));
    expect(identical(forModel, forModelAgain), isTrue,
        reason: 'the second ask for the first model must still be the '
            'remembered list, not a fresh walk');
  });
}
