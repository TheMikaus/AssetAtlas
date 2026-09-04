// End-to-end skinning against a real Synty pack: importer -> mesh -> pose.
//
// Set ASSET_ATLAS_SYNTY_CORPUS to the folder holding the Synty .zip packs to
// run these; without it they skip, so CI and a fresh clone stay green. The
// path is not hard-coded because it points at a personal asset library, not a
// fixture that can live in the repo.
//
// The extent check is the one that matters. Posing a character with its own
// rest skeleton cancels the importer's framing transform out, so an identity
// test passes at 7e-6 while the render is visibly wrong -- which is exactly
// how a 0.89m offset between a character's mesh and its own skeleton went
// unnoticed through several rounds of looking in the wrong place. A posed
// character must not change height.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

const _corpusVariable = 'ASSET_ATLAS_SYNTY_CORPUS';
const _packName = 'ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
const _characterEntry = 'SourceFiles/Character/PolygonSyntyCharacter.fbx';
const _clipEntry =
    'SourceFiles/Animations/Polygon/Feminine/Idle/A_Idle_Standing_Femn.fbx';
const _sidekickClipEntry =
    'SourceFiles/Animations/Sidekick/Feminine/Idles/'
    'A_MOD_BL_Idle_Standing_Femn.fbx';
const _sidekickReference = 'SourceFiles/Character/SidekickSyntyCharacter.fbx';
const _royalePack = 'POLYGON_BattleRoyale_Source_Files_v4 (1).zip';
const _royaleCharacter = 'Source Files/Characters/SK_Chr_MilitaryMale_01.fbx';

String? get _packPath {
  final root = Platform.environment[_corpusVariable];
  if (root == null || root.isEmpty) return null;
  final pack = '$root${Platform.pathSeparator}$_packName';
  return File(pack).existsSync() ? pack : null;
}

Future<Map<String, dynamic>> _import(String pack, String entry) async {
  final zip = ZipDecoder().decodeBytes(File(pack).readAsBytesSync());
  final file = zip.files.firstWhere((f) => f.name == entry);
  final process = await Process.start(meshImporterPath(), [
    '--stdin',
    entry.split('/').last,
  ]);
  process.stdin.add(file.content as List<int>);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  await process.exitCode;
  return jsonDecode(out) as Map<String, dynamic>;
}

({double width, double height}) _extent(List<Vec3> vertices) {
  var minX = double.infinity;
  var maxX = -double.infinity;
  var minY = double.infinity;
  var maxY = -double.infinity;
  for (final v in vertices) {
    if (v.x < minX) minX = v.x;
    if (v.x > maxX) maxX = v.x;
    if (v.y < minY) minY = v.y;
    if (v.y > maxY) maxY = v.y;
  }
  return (width: maxX - minX, height: maxY - minY);
}

void main() {
  final pack = _packPath;
  final skipReason = pack == null
      ? 'set $_corpusVariable to the folder holding the Synty packs'
      : null;

  group('skinning a real character with a real clip', () {
    late MeshModel character;
    late SkeletonAnimation clip;

    setUpAll(() async {
      if (pack == null) return;
      character = await meshModelFromImporterJson(
        await _import(pack, _characterEntry),
        modelPath: buildZipVirtualPath(pack, _characterEntry),
        name: 'PolygonSyntyCharacter.fbx',
      );
      clip = SkeletonAnimation.fromJson(
        (await _import(pack, _clipEntry))['skeleton'] as Map<String, dynamic>?,
      )!;
    });

    test('the character imports with skin weights and a rest pose', () {
      expect(character.skin, isNotNull);
      expect(character.skeleton, isNotNull);
      expect(character.skin!.boneNames, isNotEmpty);
      expect(
        character.skin!.normalizeScale,
        greaterThan(0),
        reason: 'the framing transform has to survive the importer',
      );
    });

    test('every skin bone is found in the clip', () {
      final skin = character.skin!;
      final missing = [
        for (var i = 0; i < skin.boneNames.length; i += 1)
          if (clip.indexOfBone(skin.boneNames[i], path: skin.bonePaths[i]) < 0)
            skin.bonePaths[i],
      ];
      expect(missing, isEmpty);
    });

    test('posing does not change the character height', () {
      final bind = _extent(character.vertices);
      for (final frame in [0, clip.frameCount ~/ 3, clip.frameCount - 1]) {
        final posed = _extent(
          poseSkinnedVertices(character: character, clip: clip, frame: frame),
        );
        expect(
          posed.height,
          closeTo(bind.height, bind.height * 0.05),
          reason:
              'frame $frame is ${posed.height.toStringAsFixed(2)} tall against '
              'a bind of ${bind.height.toStringAsFixed(2)}: a posed character '
              'that grows means the framing transform was dropped',
        );
      }
    });

    test('an idle brings the arms in from the T-pose', () {
      final bind = _extent(character.vertices);
      final posed = _extent(
        poseSkinnedVertices(character: character, clip: clip, frame: 0),
      );
      expect(
        posed.width,
        lessThan(bind.width * 0.75),
        reason: 'the bind is a T-pose and the clip is a standing idle',
      );
    });

    test('the pose actually moves, frame to frame', () {
      final first = poseSkinnedVertices(
        character: character,
        clip: clip,
        frame: 0,
      );
      final later = poseSkinnedVertices(
        character: character,
        clip: clip,
        frame: clip.frameCount ~/ 2,
      );
      var moved = 0.0;
      for (var i = 0; i < first.length; i += 1) {
        final d = (first[i].y - later[i].y).abs();
        if (d > moved) moved = d;
      }
      expect(moved, greaterThan(0.0005));
    });
  }, skip: skipReason);
  group('rig families do not mix', () {
    // The pack ships clips for two skeletons side by side. They share 52 and
    // 121 bones respectively and not one name between them, so a clip from one
    // family cannot drive a character from the other -- and must be reported
    // as such rather than quietly producing a bind pose.
    late SkeletonAnimation polygonClip;
    late SkeletonAnimation sidekickClip;
    late MeshModel polygonReference;
    late MeshModel sidekickReference;

    setUpAll(() async {
      if (pack == null) return;
      polygonClip = SkeletonAnimation.fromJson(
        (await _import(pack, _clipEntry))['skeleton'] as Map<String, dynamic>?,
      )!;
      sidekickClip = SkeletonAnimation.fromJson(
        (await _import(pack, _sidekickClipEntry))['skeleton']
            as Map<String, dynamic>?,
      )!;
      polygonReference = await meshModelFromImporterJson(
        await _import(pack, _characterEntry),
        modelPath: buildZipVirtualPath(pack, _characterEntry),
        name: 'PolygonSyntyCharacter.fbx',
      );
      sidekickReference = await meshModelFromImporterJson(
        await _import(pack, _sidekickReference),
        modelPath: buildZipVirtualPath(pack, _sidekickReference),
        name: 'SidekickSyntyCharacter.fbx',
      );
    });

    test('each reference shares every bone with its own family', () {
      expect(
        rigBoneOverlap(polygonReference.skeleton!, polygonClip),
        polygonReference.skeleton!.bones.length,
      );
      expect(
        rigBoneOverlap(sidekickReference.skeleton!, sidekickClip),
        sidekickReference.skeleton!.bones.length,
      );
    });

    test('and none at all with the other', () {
      expect(rigBoneOverlap(sidekickReference.skeleton!, polygonClip), 0);
      expect(rigBoneOverlap(polygonReference.skeleton!, sidekickClip), 0);
    });

    test('an unrelated rig is infinitely far, not perfectly aligned', () {
      // Zero shared bones used to score 0 degrees, which read as a flawless
      // match and made the wrong reference win.
      expect(
        rigAxisDifference(sidekickReference.skeleton!, polygonClip),
        double.infinity,
      );
      expect(
        rigAxisDifference(polygonReference.skeleton!, polygonClip),
        lessThan(90),
      );
    });
  }, skip: skipReason);

  group('a character whose joints point elsewhere', () {
    late MeshModel character;
    late SkeletonAnimation clip;
    late MeshModel reference;

    setUpAll(() async {
      if (pack == null) return;
      final royale =
          '${File(pack).parent.path}${Platform.pathSeparator}$_royalePack';
      character = await meshModelFromImporterJson(
        await _import(royale, _royaleCharacter),
        modelPath: buildZipVirtualPath(royale, _royaleCharacter),
        name: 'SK_Chr_MilitaryMale_01.fbx',
      );
      clip = SkeletonAnimation.fromJson(
        (await _import(pack, _clipEntry))['skeleton'] as Map<String, dynamic>?,
      )!;
      reference = await meshModelFromImporterJson(
        await _import(pack, _characterEntry),
        modelPath: buildZipVirtualPath(pack, _characterEntry),
        name: 'PolygonSyntyCharacter.fbx',
      );
    });

    test('shares the clip rig but not its joint angles', () {
      expect(rigBoneOverlap(character.skeleton!, clip), greaterThan(40));
      expect(
        rigAxisDifference(character.skeleton!, clip),
        greaterThan(maxDirectPoseAngle),
        reason: 'this is what makes direct posing invalid',
      );
    });

    test('posing it directly wrecks it', () {
      final bind = _extent(character.vertices);
      final posed = _extent(
        poseSkinnedVertices(character: character, clip: clip, frame: 10),
      );
      expect(
        posed.width,
        lessThan(bind.width * 0.6),
        reason: 'the mesh collapses inward: this is the bug being guarded',
      );
    });

    test('retargeting through the reference keeps it intact', () {
      final plan = RetargetPlan.build(
        characterRest: character.skeleton!,
        clip: clip,
        sourceReference: reference.skeleton,
      );
      expect(plan, isNotNull);

      final bind = _extent(character.vertices);
      final posed = _extent(
        poseSkinnedVertices(
          character: character,
          clip: clip,
          frame: 10,
          plan: plan,
        ),
      );
      expect(posed.height, closeTo(bind.height, bind.height * 0.05));
      expect(
        posed.width,
        lessThan(bind.width * 0.5),
        reason: 'a T-pose adopting a standing idle brings its arms in',
      );
    });
  }, skip: skipReason);
}
