import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The index that answers "which clips drive this model" and the mirror of
/// it, built from rig signatures rather than from pairs.
///
/// Pairs would be 2,147 characters x 796 clips, about 1.7 million verdicts,
/// every one of them wrong the day the rule changes. Rigs repeat instead: 224
/// clips sampled from this library hold 12 distinct rigs, 800 characters 42.
///
/// The rigs below are the real ones, read out of the real files with the
/// importer and committed as `test/fixtures/rig_bone_names.json`. A toy rig
/// is not good enough here: the question is how much two rigs overlap once
/// case is folded, and an invented pair of ten-bone rigs overlaps far more
/// than Synty's real ones do.
Map<String, List<String>> loadRigs() {
  final file = File('test/fixtures/rig_bone_names.json');
  if (!file.existsSync()) {
    throw StateError('rig_bone_names.json is missing at ${file.absolute.path}');
  }
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in json.entries)
      if (entry.value is List)
        entry.key: (entry.value as List).map((v) => v as String).toList(),
  };
}

AssetItem _asset(
  String path, {
  required String modelKind,
  required List<String> bones,
  required String family,
  String container = r'C:\Packs\PackA.zip',
}) {
  return AssetItem(
    id: path + container,
    name: path.split('/').last,
    path: 'zip:$container::$path',
    relativePath: path,
    sourceRoot: r'C:\Packs',
    sourceName: 'Packs',
    ext: 'fbx',
    type: 'model',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
    modelKind: modelKind,
    rigFamily: family,
    rigSignature: rigSignatureOf(bones),
  );
}

void main() {
  setUp(resetRigIndex);
  tearDown(resetRigIndex);

  final rigs = loadRigs();
  final mannequin = rigs['warRobotCharacter']!;
  final sidekick = rigs['sidekickClip']!;
  final polygon = rigs['polygonCharacter']!;
  final polygonMotion = rigs['polygonClip']!;

  final robot = _asset(
    'Characters/SK_Robot.fbx',
    modelKind: 'mesh',
    bones: mannequin,
    family: 'unreal',
  );
  final knight = _asset(
    'Characters/SK_Knight.fbx',
    modelKind: 'mesh',
    bones: polygon,
    family: 'polygon',
  );
  final idle = _asset(
    'Clips/A_Idle.fbx',
    modelKind: 'animation',
    bones: sidekick,
    family: 'sidekick',
  );
  final walk = _asset(
    'Clips/A_Walk.fbx',
    modelKind: 'animation',
    bones: sidekick,
    family: 'sidekick',
    container: r'C:\Packs\PackB.zip',
  );
  final swing = _asset(
    'Clips/A_Swing.fbx',
    modelKind: 'animation',
    bones: polygonMotion,
    family: 'polygon',
  );
  final prop = _asset(
    'Props/SM_Crate.fbx',
    modelKind: 'mesh',
    bones: const [],
    family: 'none',
  );

  final bones = {
    rigSignatureOf(mannequin): mannequin,
    rigSignatureOf(sidekick): sidekick,
    rigSignatureOf(polygon): polygon,
    rigSignatureOf(polygonMotion): polygonMotion,
  };
  final catalog = [robot, knight, idle, walk, swing, prop];

  group('signatures', () {
    test('every rig here is its own', () {
      expect(bones.keys.toSet(), hasLength(4));
    });

    test('case alone does not make a new rig', () {
      // The point of lower-casing: the robot writes Pelvis and the clip
      // writes pelvis, and an export that differed only in case would
      // otherwise look like a rig nobody else is on.
      expect(
        rigSignatureOf(mannequin),
        rigSignatureOf(mannequin.map((b) => b.toUpperCase()).toList()),
      );
    });

    test('a file with no bones has no signature', () {
      expect(prop.rigSignature, isEmpty);
    });
  });

  group('clips for a model', () {
    test('the mannequin character gets the Sidekick clips, not the Polygon one',
        () {
      final index = rigIndexFor(catalog, bones);
      expect(
        index.clipsFor(robot).map((a) => a.name),
        ['A_Idle.fbx', 'A_Walk.fbx'],
      );
    });

    test('its own container comes first', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.clipsFor(robot).first.name, 'A_Idle.fbx');
    });

    test('the Polygon character gets only the Polygon clip', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.clipsFor(knight).map((a) => a.name), ['A_Swing.fbx']);
    });

    test('a prop gets nothing', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.clipsFor(prop), isEmpty);
    });

    test('the order does not depend on the order of the catalog', () {
      final forward = rigIndexFor(catalog, bones).clipsFor(robot);
      resetRigIndex();
      final shuffled = rigIndexFor(
        catalog.reversed.toList(),
        bones,
      ).clipsFor(robot);
      expect(shuffled.map((a) => a.name), forward.map((a) => a.name));
    });
  });

  group('models for a clip', () {
    test('a Sidekick clip drives the mannequin character', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.modelsFor(walk).map((a) => a.name), ['SK_Robot.fbx']);
    });

    test('a Polygon clip drives the Polygon character and nothing else', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.modelsFor(swing).map((a) => a.name), ['SK_Knight.fbx']);
    });

    test('a clip is never offered as a model for another clip', () {
      final index = rigIndexFor(catalog, bones);
      expect(
        index.modelsFor(walk).map((a) => a.name),
        isNot(contains('A_Idle.fbx')),
      );
    });
  });

  group('the verdict cache', () {
    test('unknown bones give no answer rather than a wrong one', () {
      final index = rigIndexFor(catalog, const {});
      expect(index.compatible(robot.rigSignature, walk.rigSignature), isNull);
      expect(index.clipsFor(robot), isEmpty);
    });

    test('an unsigned file has no answer either', () {
      final index = rigIndexFor(catalog, bones);
      expect(index.compatible(null, walk.rigSignature), isNull);
      expect(index.compatible(robot.rigSignature, ''), isNull);
    });

    test('the answer is the bone rule, and asking twice gives it again', () {
      final index = rigIndexFor(catalog, bones);
      // A Sidekick clip drives the 48-bone mannequin character: 19 of those
      // 48 names match exactly and 28 once case is folded, which is 58%.
      expect(index.compatible(robot.rigSignature, idle.rigSignature), isTrue);
      expect(index.compatible(robot.rigSignature, idle.rigSignature), isTrue);
      expect(index.compatible(knight.rigSignature, idle.rigSignature), isFalse);
      expect(index.compatible(knight.rigSignature, idle.rigSignature), isFalse);
    });

    test('the two directions are asked separately', () {
      // The fraction half of the rule is not symmetric -- 28 of the robot's
      // 48 bones is 58%, while 28 of the clip rig's 121 is 23% -- so the
      // index must ask in the character-to-clip direction. This pair is
      // compatible both ways only because 19 names match exactly, which is
      // over the four the older rule asked for and is symmetric.
      final index = rigIndexFor(catalog, bones);
      final characterBones = bones[robot.rigSignature]!;
      final clipBones = bones[idle.rigSignature]!;
      expect(rigNameMatches(characterBones, clipBones).exact, 19);
      expect(rigNameMatches(characterBones, clipBones).folded, 28);
      expect(index.compatible(robot.rigSignature, idle.rigSignature), isTrue);
    });
  });

  group('the filter', () {
    bool passes(AssetItem asset, AssetItem character) => assetPassesRigFilter(
      asset: asset,
      rigFilter: 'compatible',
      characterRig: character.rigFamily,
      characterSignature: character.rigSignature,
      rigIndex: rigIndexFor(catalog, bones),
    );

    test('bones decide, not the family name', () {
      expect(passes(walk, robot), isTrue);
      expect(passes(swing, robot), isFalse);
      expect(passes(swing, knight), isTrue);
      expect(passes(walk, knight), isFalse);
    });

    test('a file with no signature falls back to the family rule', () {
      final unsigned = AssetItem(
        id: 'u',
        name: 'A_Old.fbx',
        path: r'C:\Packs\A_Old.fbx',
        relativePath: 'A_Old.fbx',
        sourceRoot: r'C:\Packs',
        sourceName: 'Packs',
        ext: 'fbx',
        type: 'model',
        size: 1,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
        tags: const [],
        modelKind: 'animation',
        rigFamily: 'sidekick',
      );
      expect(
        passes(unsigned, robot),
        isTrue,
        reason: 'unreal character, sidekick clip, by family',
      );
    });
  });
}
