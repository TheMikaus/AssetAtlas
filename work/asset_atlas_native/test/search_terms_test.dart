import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assetMatchesSearch', () {
    // Search text is already lowercased by the caller.
    const clip = 'a_jump_running_femn.fbx animations/polygon/feminine/inair';

    test('a single term is a plain substring match', () {
      expect(assetMatchesSearch(clip, 'jump'), isTrue);
      expect(assetMatchesSearch(clip, 'crouch'), isFalse);
    });

    test('a space means and, in any order', () {
      expect(assetMatchesSearch(clip, 'jump fem'), isTrue);
      expect(assetMatchesSearch(clip, 'fem jump'), isTrue);
    });

    test('every term has to be present', () {
      expect(assetMatchesSearch(clip, 'jump masc'), isFalse);
    });

    test('terms need not be adjacent', () {
      expect(
        assetMatchesSearch(clip, 'a_jump femn'),
        isTrue,
        reason: 'the whole point is matching two remembered pieces of a name',
      );
    });

    test('runs of spaces do not create empty terms that match nothing', () {
      expect(assetMatchesSearch(clip, 'jump    fem'), isTrue);
      expect(assetMatchesSearch(clip, '   '), isTrue);
    });

    test('an empty query matches', () {
      expect(assetMatchesSearch(clip, ''), isTrue);
    });

    test('a term can match the path as well as the name', () {
      expect(assetMatchesSearch(clip, 'polygon jump'), isTrue);
    });
  });
}
