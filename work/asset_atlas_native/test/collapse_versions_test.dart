import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row per model, not one per engine build.
///
/// `war_robot_01` is in this library seven times: `SK_Chr_BR_War_Robot_01.fbx`
/// in `POLYGON_SciFiSpace_SourceFiles.zip` and six `.uasset` builds of it, in
/// the Unreal 4.19, 4.25, 4.26, 5.0, 5.1 and 5.4 zips. Searching for it
/// returned seven rows of the same robot.
AssetItem _asset(String path, {String type = 'model', bool ignored = false}) {
  final name = path.split(RegExp(r'[\\/:]+')).last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return AssetItem(
    id: path,
    name: name,
    path: path,
    relativePath: name,
    sourceRoot: r'Z:\Assets',
    sourceName: 'Assets',
    ext: ext,
    type: type,
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
    ignored: ignored,
  );
}

AssetItem _unrealBuild(String version) => _asset(
  r'zip:Z:\Assets\Synty\POLYGON_SciFi_Space_Unreal_$version.zip'
          .replaceAll(r'$version', version) +
      '::Content/PolygonSciFiSpace/Meshes/Characters/'
          'SK_Chr_BR_War_Robot_01.uasset',
  type: 'unreal',
);

final _sourceFbx = _asset(
  r'zip:Z:\Assets\Synty\POLYGON_SciFiSpace_SourceFiles.zip'
  '::_SourceFiles/Characters/SK_Chr_BR_War_Robot_01.fbx',
);

void main() {
  setUp(resetTwinProductKeyCache);

  group('collapsing the copies of one model', () {
    test('the war robot is one row, not seven', () {
      final rows = [
        _sourceFbx,
        for (final version in ['4_19', '4_25', '4_26', '5_0', '5_1', '5_4'])
          _unrealBuild(version),
      ];
      final collapsed = collapseAssetVersions(rows);

      expect(collapsed.rows.length, 1);
      expect(collapsed.membersById[collapsed.rows.first.id]?.length, 7);
    });

    test('the row shown is the one that can be drawn', () {
      // The uassets come first in the input, so taking the first member
      // would have shown a file Atlas cannot draw.
      final collapsed = collapseAssetVersions([
        _unrealBuild('4_19'),
        _unrealBuild('5_0'),
        _sourceFbx,
      ]);
      expect(collapsed.rows.single.ext, 'fbx');
    });

    test('a group takes the position of its first member', () {
      final before = _asset(r'Z:\Assets\aaa\barrel.fbx');
      final after = _asset(r'Z:\Assets\zzz\crate.fbx');
      final collapsed = collapseAssetVersions([
        before,
        _unrealBuild('4_19'),
        after,
        _sourceFbx,
      ]);
      // The robot's group appeared second, so it stays second even though
      // the row shown for it is the FBX that came last.
      expect(
        collapsed.rows.map((row) => row.name),
        ['barrel.fbx', 'SK_Chr_BR_War_Robot_01.fbx', 'crate.fbx'],
      );
    });

    test('two models of the same name in different packs stay two rows', () {
      // The whole reason the key carries the product: `pipe_end` in a Kenney
      // kit is not the `pipe_end` in a Synty pack.
      final collapsed = collapseAssetVersions([
        _asset(r'zip:Z:\Assets\Kenney\KenneyPipes.zip::pipe_end.fbx'),
        _asset(r'zip:Z:\Assets\Synty\POLYGON_Town.zip::pipe_end.fbx'),
      ]);
      expect(collapsed.rows.length, 2);
      expect(collapsed.membersById, isEmpty);
    });

    test('a file that cannot pair is its own row and carries no badge', () {
      // A texture, a material and a skeleton are not other formats of the
      // model, which is `twinEligible`'s rule, not this function's.
      final rows = [
        _asset(r'Z:\Assets\Synty\POLYGON_Town.zip::T_Town_01.png',
            type: 'image'),
        _asset(r'Z:\Assets\Synty\POLYGON_Town.zip::T_Town_01.tga',
            type: 'image'),
      ];
      final collapsed = collapseAssetVersions(rows);
      expect(collapsed.rows.length, 2);
      expect(collapsed.membersById, isEmpty);
    });

    test('a lone model is a row with no members recorded', () {
      final collapsed = collapseAssetVersions([_sourceFbx]);
      expect(collapsed.rows.single.id, _sourceFbx.id);
      expect(collapsed.membersById[_sourceFbx.id], isNull);
    });

    test('an empty list collapses to an empty list', () {
      expect(collapseAssetVersions(const []).rows, isEmpty);
    });

    test('the key is computed once per asset', () {
      // The cached key is what makes this affordable twice per rebuild over
      // a 480,826-row catalog.
      final asset = _sourceFbx;
      expect(asset.twinKey, isNotEmpty);
      expect(asset.twinKey, same(asset.twinKey));
    });
  });

  group('what the badge says', () {
    testWidgets('it counts the files and names the formats', (tester) async {
      final members = [
        _sourceFbx,
        _unrealBuild('4_19'),
        _unrealBuild('5_0'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VersionCountBadge(members: members)),
        ),
      );

      expect(find.text('x3'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('3 files of this model'));
      expect(tooltip.message, contains('2 x UASSET'));
      expect(tooltip.message, contains('FBX'));
      // Every member's path, so it is clear which builds are behind the row.
      for (final member in members) {
        expect(tooltip.message, contains(member.path));
      }
    });
  });
}
