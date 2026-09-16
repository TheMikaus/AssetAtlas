// A rescan must not forget what the catalog already knew.
//
// Classification is an importer run per FBX -- 27,000 of them in this
// library -- and the first rescan after the Unreal rules landed threw every
// one away, emptying the Character and Animation filters until the whole lot
// had been probed a second time. Ids are built from the source root and the
// relative path, so they survive a rescan and the answers can ride across.
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _fbx(String path, {String? modelKind, String? rigFamily, bool ignored = false}) =>
    AssetItem(
      id: path,
      name: path.split('/').last,
      path: path,
      relativePath: path,
      sourceRoot: r'C:\Packs',
      sourceName: 'Packs',
      ext: 'fbx',
      type: 'model',
      size: 1,
      modified: DateTime.fromMillisecondsSinceEpoch(0),
      tags: const [],
      modelKind: modelKind,
      rigFamily: rigFamily,
      ignored: ignored,
    );

void main() {
  test('the kind, rig and ignored flag carry across by id', () {
    final before = {
      'a.fbx': _fbx('a.fbx', modelKind: 'animation', rigFamily: 'polygon'),
      'b.fbx': _fbx('b.fbx', modelKind: 'mesh', rigFamily: 'none', ignored: true),
    };
    final after = carryClassification([_fbx('a.fbx'), _fbx('b.fbx'), _fbx('c.fbx')], before);

    expect(after[0].modelKind, 'animation');
    expect(after[0].rigFamily, 'polygon');
    expect(after[1].modelKind, 'mesh');
    expect(after[1].ignored, isTrue);
    expect(after[2].modelKind, isNull, reason: 'a new file is still unknown');
  });

  test('a fresh answer is not overwritten by an old one', () {
    final before = {'a.fbx': _fbx('a.fbx', modelKind: 'mesh', rigFamily: 'none')};
    final after = carryClassification(
      [_fbx('a.fbx', modelKind: 'animation', rigFamily: 'polygon')],
      before,
    );
    expect(after[0].modelKind, 'animation');
    expect(after[0].rigFamily, 'polygon');
  });
}
