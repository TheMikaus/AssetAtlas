import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Twins: the same model shipped in another format or another engine build.
///
/// Half this library is duplicates of that kind. 120,481 .uasset files carry
/// 48,282 distinct names, and 15,928 of those names also exist as an FBX or
/// an OBJ -- 67,999 uassets, 56% of them. A Synty pack ships one FBX zip and
/// up to seven Unreal zips of the same models, under container names that
/// agree about the pack and differ about everything else.

AssetItem _asset(String name, String container, {String? type}) {
  final ext = name.split('.').last.toLowerCase();
  return AssetItem(
    id: '$container|$name',
    name: name,
    path: 'zip:Z:/Assets/$container::Files/$name',
    relativePath: 'Assets/$container/$name',
    sourceRoot: r'Z:\Assets',
    sourceName: 'Assets',
    ext: ext,
    type: type ?? (ext == 'uasset' ? 'unreal' : 'model'),
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

void main() {
  setUp(resetTwinIndex);
  tearDown(resetTwinIndex);

  group('twinProductKey', () {
    test('every build of one pack reduces to one product', () {
      const builds = [
        'POLYGON_SciFiSpace_SourceFiles.zip',
        'POLYGON_SciFiSpace_Unreal_4_19.zip',
        'POLYGON_SciFi_Space_Unreal_4_25_v1_13.zip',
        'POLYGON_SciFi_Space_Unreal_5_4_v1_14_0.zip',
      ];
      for (final build in builds) {
        expect(twinProductKey(build), 'polygonscifispace', reason: build);
      }
    });

    test('two packs do not share one', () {
      expect(
        twinProductKey('POLYGON_SciFiSpace_SourceFiles.zip'),
        isNot(twinProductKey('POLYGON_SciFi_Horror_SourceFiles_v2.zip')),
      );
    });

    test('a year or a version is not part of the name', () {
      expect(
        twinProductKey('POLYGONTown_Unity_2019_4_28.unitypackage'),
        twinProductKey('POLYGON_Town_SourceFiles.zip'),
      );
    });

    test('a plain folder name survives', () {
      expect(twinProductKey('KayKit Dungeon Pack 1.0'), 'kaykitdungeonpack');
    });
  });

  group('twinStem', () {
    test('drops the extension and the case', () {
      expect(twinStem('SM_Prop_Crate_01.FBX'), 'sm_prop_crate_01');
      expect(twinStem('no_extension'), 'no_extension');
    });
  });

  group('what may pair', () {
    test('a texture, a material or a blueprint uasset never pairs', () {
      for (final name in [
        'T_Crate_01.uasset',
        'M_Stone.uasset',
        'MI_Stone_Red.uasset',
        'MAT_Wood.uasset',
        'MF_Blend.uasset',
        'BP_Door.uasset',
      ]) {
        expect(twinEligible(_asset(name, 'Pack_Unreal.zip')), isFalse,
            reason: name);
      }
    });

    test('a physics asset or a skeleton never pairs', () {
      expect(
        twinEligible(_asset('SK_Chr_X_01_PhysicsAsset.uasset', 'P_Unreal.zip')),
        isFalse,
      );
      expect(
        twinEligible(_asset('SK_Chr_X_01_Skeleton.uasset', 'P_Unreal.zip')),
        isFalse,
      );
    });

    test('a model uasset pairs', () {
      expect(
        twinEligible(_asset('SM_Prop_Crate_01.uasset', 'P_Unreal.zip')),
        isTrue,
      );
    });

    test('an image or a sound never pairs', () {
      expect(
        twinEligible(_asset('T_Crate.png', 'P.zip', type: 'image')),
        isFalse,
      );
      expect(
        twinEligible(_asset('step.wav', 'P.zip', type: 'audio')),
        isFalse,
      );
    });
  });

  group('the index', () {
    final fbx = _asset('SM_Prop_Crate_01.fbx', 'POLYGON_Pack_SourceFiles.zip');
    final obj = _asset('SM_Prop_Crate_01.obj', 'POLYGON_Pack_SourceFiles.zip');
    final unreal = _asset('SM_Prop_Crate_01.uasset', 'POLYGON_Pack_Unreal_4_19.zip');
    final unreal5 = _asset(
      'SM_Prop_Crate_01.uasset',
      'POLYGON_Pack_Unreal_5_4_v1_14_0.zip',
    );
    final other = _asset('SM_Prop_Crate_01.fbx', 'POLYGON_Other_SourceFiles.zip');
    final texture = _asset('T_Prop_Crate_01.uasset', 'POLYGON_Pack_Unreal_4_19.zip');
    final catalog = [fbx, obj, unreal, unreal5, other, texture];

    test('three formats of one model are one group', () {
      final twins = twinIndexFor(catalog).twinsOf(fbx);
      expect(
        twins.same.map((a) => a.name),
        ['SM_Prop_Crate_01.obj', 'SM_Prop_Crate_01.uasset',
         'SM_Prop_Crate_01.uasset'],
      );
      expect(twins.same.map((a) => a.ext).toSet(), {'obj', 'uasset'});
    });

    test('the uasset finds the fbx', () {
      expect(
        twinIndexFor(catalog).twinsOf(unreal).same.map((a) => a.ext),
        contains('fbx'),
      );
    });

    test('a texture uasset joins nothing', () {
      expect(twinIndexFor(catalog).twinsOf(texture).isEmpty, isTrue);
    });

    test('the groups do not depend on the order of the catalog', () {
      final forward = twinIndexFor(catalog).twinsOf(fbx).same.map((a) => a.id);
      resetTwinIndex();
      final backward = twinIndexFor(catalog.reversed.toList())
          .twinsOf(fbx)
          .same
          .map((a) => a.id);
      expect(backward, forward);
    });

    test('a name two packs both ship is nobody\'s twin', () {
      // SM_Prop_Crate_01.fbx exists in this pack and in POLYGON_Pack, so
      // the uassets could belong to either and the weaker tier declines.
      final twins = twinIndexFor(catalog).twinsOf(other);
      expect(twins.same, isEmpty);
      expect(twins.possible, isEmpty);
    });
  });

  group('the weaker tier is guarded', () {
    test('a short stem is never a maybe', () {
      final a = _asset('pipe.fbx', 'KayKit_Dungeon.zip');
      final b = _asset('pipe.uasset', 'Some_Other_Unreal.zip');
      final twins = twinIndexFor([a, b]).twinsOf(a);
      expect(twins.same, isEmpty);
      expect(twins.possible, isEmpty);
    });

    test('a stem with no underscore is never a maybe', () {
      final a = _asset('crateandbarrel.fbx', 'PackOne.zip');
      final b = _asset('crateandbarrel.uasset', 'PackTwo_Unreal.zip');
      expect(twinIndexFor([a, b]).twinsOf(a).possible, isEmpty);
    });

    test('a stem that two products both ship is never a maybe', () {
      // Two models with the same name in different packs: whichever uasset
      // this is, there is no way to tell which one it belongs to.
      final one = _asset('SM_Prop_Crate_01.fbx', 'PackOne_SourceFiles.zip');
      final two = _asset('SM_Prop_Crate_01.fbx', 'PackTwo_SourceFiles.zip');
      final unreal = _asset('SM_Prop_Crate_01.uasset', 'PackThree_Unreal.zip');
      final twins = twinIndexFor([one, two, unreal]).twinsOf(unreal);
      expect(twins.same, isEmpty);
      expect(twins.possible, isEmpty);
    });

    test('a long distinctive stem under one product is a maybe', () {
      final model = _asset(
        'SM_Bld_Dungeon_Wall_01.fbx',
        'Polygon_Dungeons_Realms_SourceFiles.zip',
      );
      final unreal = _asset(
        'SM_Bld_Dungeon_Wall_01.uasset',
        'DungeonRealms_Unreal_5_1.zip',
      );
      final twins = twinIndexFor([model, unreal]).twinsOf(unreal);
      expect(twins.same, isEmpty);
      expect(twins.possible.single.ext, 'fbx');
    });
  });

  group('the twin to draw', () {
    test('FBX is preferred to OBJ', () {
      final fbx = _asset('SM_Crate_01.fbx', 'Pack_SourceFiles.zip');
      final obj = _asset('SM_Crate_01.obj', 'Pack_SourceFiles.zip');
      final unreal = _asset('SM_Crate_01.uasset', 'Pack_Unreal_5_1.zip');
      final catalog = [obj, fbx, unreal];
      expect(previewableTwinOf(unreal, catalog)?.ext, 'fbx');
    });

    test('a format the importer cannot read is not offered', () {
      final dae = _asset('SM_Crate_01.dae', 'Pack_SourceFiles.zip');
      final unreal = _asset('SM_Crate_01.uasset', 'Pack_Unreal_5_1.zip');
      expect(previewableTwinOf(unreal, [dae, unreal]), isNull);
    });

    test('a maybe is never drawn', () {
      final model = _asset('SM_Bld_Wall_Long_01.fbx', 'PackOne_SourceFiles.zip');
      final unreal = _asset('SM_Bld_Wall_Long_01.uasset', 'PackTwo_Unreal.zip');
      final catalog = [model, unreal];
      expect(twinIndexFor(catalog).twinsOf(unreal).possible, isNotEmpty);
      expect(previewableTwinOf(unreal, catalog), isNull);
    });

    test('nothing to draw gives nothing', () {
      final unreal = _asset('SM_Crate_01.uasset', 'Pack_Unreal_5_1.zip');
      expect(previewableTwinOf(unreal, [unreal]), isNull);
    });
  });

  group('the borrowed picture', () {
    Future<void> pumpPreview(
      WidgetTester tester,
      AssetItem item,
      List<AssetItem> catalog,
    ) async {
      ModelThumbnailCache.enabled = false;
      addTearDown(() => ModelThumbnailCache.enabled = true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 760,
              child: PreviewPanel(
                asset: item,
                allAssets: catalog,
                catalogRevision: 1,
                onActivateAsset: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a uasset with an FBX twin shows the twin and says so', (
      tester,
    ) async {
      final fbx = _asset('SM_Crate_01.fbx', 'POLYGON_Pack_SourceFiles.zip');
      final unreal = _asset('SM_Crate_01.uasset', 'POLYGON_Pack_Unreal_5_1.zip');
      await pumpPreview(tester, unreal, [fbx, unreal]);

      expect(find.byType(ModelPreview), findsOneWidget);
      expect(
        find.textContaining('Showing the FBX twin: SM_Crate_01.fbx'),
        findsOneWidget,
      );
      expect(
        find.textContaining('can only be opened in Unreal Engine'),
        findsOneWidget,
      );
      // The panel still describes the file that is selected.
      expect(find.text('SM_Crate_01.uasset'), findsWidgets);
    });

    testWidgets('a uasset with no twin keeps the plain panel', (tester) async {
      final unreal = _asset('SM_Alone_01.uasset', 'POLYGON_Pack_Unreal_5_1.zip');
      await pumpPreview(tester, unreal, [unreal]);

      expect(find.byType(PlainPreview), findsOneWidget);
      expect(find.byType(ModelPreview), findsNothing);
      expect(find.textContaining('Showing the'), findsNothing);
    });
  });

  group('the formats section', () {
    final fbx = _asset('SM_Crate_01.fbx', 'POLYGON_Pack_SourceFiles.zip');
    final obj = _asset('SM_Crate_01.obj', 'POLYGON_Pack_SourceFiles.zip');
    final unreal4 = _asset(
      'SM_Crate_01.uasset',
      'POLYGON_Pack_Unreal_4_19.zip',
    );
    final unreal5 = _asset(
      'SM_Crate_01.uasset',
      'POLYGON_Pack_Unreal_5_4_v1_14_0.zip',
    );
    final lonely = _asset('SM_Alone_01.uasset', 'POLYGON_Pack_Unreal_4_19.zip');
    final catalog = [fbx, obj, unreal4, unreal5, lonely];

    Future<void> pump(
      WidgetTester tester,
      AssetItem item, {
      ValueChanged<AssetItem>? onActivate,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: TwinFormatsList(
                item: item,
                allAssets: catalog,
                onActivateAsset: onActivate ?? (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('one line per format, and a count where there are several', (
      tester,
    ) async {
      await pump(tester, fbx);
      expect(find.text('Same model, other formats'), findsOneWidget);
      expect(find.text('OBJ'), findsOneWidget);
      expect(find.text('UASSET x2'), findsOneWidget);
    });

    testWidgets('a single twin links straight to its container', (
      tester,
    ) async {
      final opened = <AssetItem>[];
      await pump(tester, fbx, onActivate: opened.add);
      await tester.tap(find.text('POLYGON_Pack_SourceFiles.zip').first);
      expect(opened.single.ext, 'obj');
    });

    testWidgets('the several expand to their containers', (tester) async {
      final opened = <AssetItem>[];
      await pump(tester, fbx, onActivate: opened.add);
      await tester.tap(find.text('UASSET x2'));
      await tester.pumpAndSettle();
      expect(find.text('POLYGON_Pack_Unreal_4_19.zip'), findsOneWidget);
      await tester.tap(find.text('POLYGON_Pack_Unreal_5_4_v1_14_0.zip'));
      expect(opened.single.ext, 'uasset');
    });

    testWidgets('a file with no twin shows nothing', (tester) async {
      await pump(tester, lonely);
      expect(find.textContaining('Same model'), findsNothing);
      expect(find.textContaining('Possibly'), findsNothing);
    });

    testWidgets('the weaker tier is labelled and separate', (tester) async {
      final model = _asset(
        'SM_Bld_Wall_Long_01.fbx',
        'Polygon_Dungeons_Realms_SourceFiles.zip',
      );
      final other = _asset(
        'SM_Bld_Wall_Long_01.uasset',
        'DungeonRealms_Unreal_5_1.zip',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: TwinFormatsList(
                item: other,
                allAssets: [model, other],
                onActivateAsset: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Possibly the same model'), findsOneWidget);
      expect(find.text('Same model, other formats'), findsNothing);
    });
  });
}
