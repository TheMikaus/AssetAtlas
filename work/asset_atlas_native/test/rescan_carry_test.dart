import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';

/// What a rescan keeps, and what it must throw away.
///
/// This is the only thing standing between a rescan and hours of lost work.
/// Classification is an importer run per FBX — 34,801 of them in this
/// library — and it is persisted and only ever computed when absent, so a
/// verdict that is wrong never heals and a verdict that is lost costs the
/// whole probe again. Both directions matter, which is why both are here.
AssetItem asset({
  required String id,
  int size = 1000,
  int modifiedMs = 1000,
  String? modelKind,
  String? rigFamily,
  bool referencedByModel = false,
  bool ignored = false,
  String sourceRoot = 'K:/lib',
}) => AssetItem(
  id: id,
  name: '$id.fbx',
  path: '$sourceRoot/$id.fbx',
  relativePath: '$id.fbx',
  sourceRoot: sourceRoot,
  sourceName: 'lib',
  ext: 'fbx',
  type: 'model',
  size: size,
  modified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
  tags: const [],
  modelKind: modelKind,
  rigFamily: rigFamily,
  referencedByModel: referencedByModel,
)..ignored = ignored;

void main() {
  group('assetLooksUnchanged', () {
    test('same size and timestamp is unchanged', () {
      expect(
        assetLooksUnchanged(
          asset(id: 'a', size: 10, modifiedMs: 5),
          asset(id: 'a', size: 10, modifiedMs: 5),
        ),
        isTrue,
      );
    });

    test('a different size is a change', () {
      expect(
        assetLooksUnchanged(
          asset(id: 'a', size: 11, modifiedMs: 5),
          asset(id: 'a', size: 10, modifiedMs: 5),
        ),
        isFalse,
      );
    });

    test('a different timestamp is a change', () {
      // Both are checked because either alone is too weak: a re-export can
      // land on the same byte count, and copying a file about changes its
      // timestamp without changing anything inside it.
      expect(
        assetLooksUnchanged(
          asset(id: 'a', size: 10, modifiedMs: 6),
          asset(id: 'a', size: 10, modifiedMs: 5),
        ),
        isFalse,
      );
    });
  });

  group('carryClassification', () {
    test('an unchanged file keeps everything that was learned about it', () {
      final fresh = [asset(id: 'a')];
      final result = carryClassification(fresh, {
        'a': asset(
          id: 'a',
          modelKind: 'mesh',
          rigFamily: 'polygon',
          referencedByModel: true,
        ),
      });
      expect(result.single.modelKind, 'mesh');
      expect(result.single.rigFamily, 'polygon');
      expect(result.single.referencedByModel, isTrue);
    });

    test('a changed file keeps none of it', () {
      // The old verdict was about different bytes. Keeping it states
      // something the catalog cannot support, and because classification is
      // only computed when absent, it would never be revisited.
      final fresh = [asset(id: 'a', size: 2000)];
      final result = carryClassification(fresh, {
        'a': asset(
          id: 'a',
          size: 1000,
          modelKind: 'mesh',
          rigFamily: 'polygon',
          referencedByModel: true,
        ),
      });
      expect(result.single.modelKind, isNull);
      expect(result.single.rigFamily, isNull);
      expect(result.single.referencedByModel, isFalse);
    });

    test('the texture link is carried, not only the probe results', () {
      // referencedByModel is learned by importing a model and finding which
      // images it asks for. Dropping it meant re-importing the library, and
      // it is the only link between a texture and the models that use it.
      final fresh = [asset(id: 'a')];
      final result = carryClassification(fresh, {
        'a': asset(id: 'a', referencedByModel: true),
      });
      expect(result.single.referencedByModel, isTrue);
    });

    test('a fresh true is not undone by a remembered false', () {
      final fresh = [asset(id: 'a', referencedByModel: true)];
      final result = carryClassification(fresh, {
        'a': asset(id: 'a', referencedByModel: false),
      });
      expect(result.single.referencedByModel, isTrue);
    });

    test('an ignore is kept even when the file changed', () {
      // That is the user's decision about a path, not a fact about the
      // bytes. Re-exporting a file they hid is no reason to show it again.
      final fresh = [asset(id: 'a', size: 2000)];
      final result = carryClassification(fresh, {
        'a': asset(id: 'a', size: 1000, ignored: true),
      });
      expect(result.single.ignored, isTrue);
    });

    test('a file nothing remembers is left alone', () {
      final result = carryClassification([asset(id: 'new')], {
        'a': asset(id: 'a', modelKind: 'mesh'),
      });
      expect(result.single.modelKind, isNull);
    });

    test('force re-derives even an unchanged file', () {
      // For when the derivation changed rather than the files, which no
      // comparison of timestamps can detect.
      final result = carryClassification(
        [asset(id: 'a')],
        {'a': asset(id: 'a', modelKind: 'mesh', rigFamily: 'polygon')},
        force: true,
      );
      expect(result.single.modelKind, isNull);
      expect(result.single.rigFamily, isNull);
    });

    test('force still keeps the ignore', () {
      final result = carryClassification(
        [asset(id: 'a')],
        {'a': asset(id: 'a', ignored: true)},
        force: true,
      );
      expect(result.single.ignored, isTrue);
    });

    test('a probed answer already on the fresh item is not overwritten', () {
      final result = carryClassification(
        [asset(id: 'a', modelKind: 'animation')],
        {'a': asset(id: 'a', modelKind: 'mesh')},
      );
      expect(result.single.modelKind, 'animation');
    });
  });

  group('tallyCarry', () {
    test('it separates unchanged, changed and new', () {
      final tally = tallyCarry(
        [
          asset(id: 'same', size: 10, modifiedMs: 1),
          asset(id: 'grown', size: 20, modifiedMs: 1),
          asset(id: 'fresh'),
        ],
        {
          'same': asset(id: 'same', size: 10, modifiedMs: 1),
          'grown': asset(id: 'grown', size: 10, modifiedMs: 1),
        },
      );
      expect(tally.unchanged, 1);
      expect(tally.changed, 1);
      expect(tally.added, 1);
    });

    test('force counts everything remembered as changed', () {
      final tally = tallyCarry(
        [asset(id: 'same')],
        {'same': asset(id: 'same')},
        force: true,
      );
      expect(tally.unchanged, 0);
      expect(tally.changed, 1);
    });

    test('the summary says what happened', () {
      // "4 changed" is the difference between a rescan that cost nothing and
      // one that has just thrown away a day of probing, so it is reported
      // rather than left to be inferred.
      final tally = tallyCarry(
        [asset(id: 'a'), asset(id: 'b', size: 99)],
        {'a': asset(id: 'a'), 'b': asset(id: 'b')},
      );
      expect(tally.summary, contains('1 unchanged'));
      expect(tally.summary, contains('1 changed'));
    });

    test('an empty scan says so rather than reading as a success', () {
      expect(tallyCarry([], {}).summary, 'nothing to compare');
    });
  });
}
