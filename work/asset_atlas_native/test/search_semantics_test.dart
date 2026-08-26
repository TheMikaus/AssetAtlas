import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _asset(String relativePath, {List<String> tags = const []}) {
  final name = relativePath.split('/').last;
  return AssetItem(
    id: relativePath,
    name: name,
    path: r'C:\Packs\' + relativePath.replaceAll('/', r'\'),
    relativePath: relativePath,
    sourceRoot: r'C:\Packs',
    sourceName: 'Packs',
    ext: name.split('.').last,
    type: 'model',
    size: 10,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: tags,
  );
}

/// The predicate the catalog screen uses, so these assertions describe the
/// behaviour users actually get.
bool _matches(AssetItem asset, String query) =>
    asset.searchText.contains(query.trim().toLowerCase());

void main() {
  group('searchText', () {
    test('folds name, relative path and tags into one lowercase haystack', () {
      final asset = _asset('Synty/FBX/SM_Airport_01.FBX', tags: ['prop']);
      expect(asset.searchText, contains('sm_airport_01.fbx'));
      expect(asset.searchText, contains('synty/fbx/'));
      expect(asset.searchText, contains('prop'));
      expect(asset.searchText, asset.searchText.toLowerCase());
    });

    test('is computed once and reused', () {
      final asset = _asset('Synty/a.fbx');
      expect(identical(asset.searchText, asset.searchText), isTrue);
    });

    test('does not let a name run into a path and create phantom matches', () {
      final asset = _asset('Synty/wall.fbx');
      // name ends "wall.fbx", path begins "Synty"; without a separator the
      // concatenation would match "wall.fbxsynty".
      expect(_matches(asset, 'wall.fbxsynty'), isFalse);
    });
  });

  group('substring matching is preserved', () {
    final airport = _asset('Synty/FBX/SM_Airport_Building01.fbx');

    test('a mid-word substring still matches', () {
      // A word-prefix index would miss this: "port" is not a token prefix of
      // "airport". Searching "port" for airport assets has to keep working.
      expect(_matches(airport, 'port'), isTrue);
    });

    test('a separator-bearing prefix still matches', () {
      // "sm_" spans a token boundary, so a token index would return nothing.
      expect(_matches(airport, 'sm_'), isTrue);
    });

    test('search is case insensitive in both directions', () {
      expect(_matches(airport, 'AIRPORT'), isTrue);
      expect(_matches(airport, 'airport'), isTrue);
    });

    test('a folder name matches assets beneath it', () {
      expect(_matches(airport, 'synty/fbx'), isTrue);
    });

    test('an unrelated query does not match', () {
      expect(_matches(airport, 'helicopter'), isFalse);
    });
  });

  group('filtering a pre-sorted list', () {
    test('preserves order, so no re-sort is needed after filtering', () {
      final assets = [
        _asset('Synty/c_airport.fbx'),
        _asset('Synty/a_airport.fbx'),
        _asset('Synty/b_other.fbx'),
        _asset('Synty/d_airport.fbx'),
      ];

      final sorted = sortAssets(assets, AssetSortMode.path);
      final filtered = sorted
          .where((asset) => _matches(asset, 'airport'))
          .toList();

      expect(
        filtered.map((asset) => asset.name),
        ['a_airport.fbx', 'c_airport.fbx', 'd_airport.fbx'],
      );
      expect(
        filtered.map((asset) => asset.name),
        sortAssets(filtered, AssetSortMode.path).map((asset) => asset.name),
        reason: 'filtering a sorted list must already be sorted',
      );
    });
  });
}
