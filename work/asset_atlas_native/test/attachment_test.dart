// Putting a helmet on a head.
//
// An attachment FBX says nothing about where it goes: it is a bare mesh at the
// origin with no skeleton, no socket and no metadata. So unlike every other rig
// question, this one is answered from the name -- and the guessing is kept in
// one table so it can be read and corrected, rather than spread through the
// code pretending to be inference.
//
// The placement itself is not guesswork. The artist built the helmet at the
// head joint's origin at the character's own scale; undoing the importer's
// framing, carrying the result through the bone, and applying the character's
// framing simply puts it back.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _asset(
  String path, {
  String type = 'model',
  String ext = 'fbx',
  String? rigFamily,
  String? modelKind,
}) => AssetItem(
  id: path,
  name: path.split(RegExp(r'[/\\]')).last,
  path: path,
  relativePath: path,
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: ext,
  type: type,
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
  modelKind: modelKind,
  rigFamily: rigFamily,
);

/// A rig with one bone per name, each a metre above the last, all upright.
SkeletonAnimation _rig(List<String> names) {
  final rest = <double>[];
  for (var i = 0; i < names.length; i += 1) {
    rest.addAll([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, i.toDouble(), 0]);
  }
  return SkeletonAnimation.fromJson({
    'bones': [
      for (var i = 0; i < names.length; i += 1)
        {'name': names[i], 'parent': i == 0 ? -1 : i - 1, 'path': names[i]},
    ],
    'stride': 12,
    'frameRate': 30.0,
    'rest': rest,
    'frames': [rest],
  })!;
}

const _polygonRig = ['Root', 'Hips', 'Spine_01', 'Spine_03', 'Head', 'Jaw'];
const _sidekickRig = [
  'root',
  'pelvis',
  'spine_01',
  'thigh_l',
  'hipAttachFront',
  'head',
  'headAttach',
  'faceAttach',
  'backAttach',
];

MeshModel _box({
  required String name,
  SkeletonAnimation? skeleton,
  MeshFraming? framing,
}) => MeshModel(
  name: name,
  vertices: const [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(0, 1, 0)],
  faces: const [MeshFace([0, 1, 2])],
  materials: [
    MeshMaterial(name: name, color: const Color(0xffffffff), textures: const []),
  ],
  skeleton: skeleton,
  framing: framing,
);

void main() {
  final root = Platform.environment['ASSET_ATLAS_SYNTY_CORPUS'];
  final pack = root == null || root.isEmpty
      ? null
      : '$root${Platform.pathSeparator}'
            'POLYGON_AncientEmpire_SourceFiles_v1.zip';
  final skipReason = pack == null || !File(pack).existsSync()
      ? 'set ASSET_ATLAS_SYNTY_CORPUS to the folder holding the Synty packs'
      : null;

  group('reading an attachment name', () {
    test('a helmet, a crown and hair all go on the head', () {
      for (final name in [
        'SM_Chr_Attach_Helmet_01.fbx',
        'SM_Chr_Attach_Crown_Leaf_02.fbx',
        'SM_Chr_Hair_Male_03.fbx',
      ]) {
        expect(attachPointFor(name)?.name, 'Head', reason: name);
      }
    });

    test('a beard goes on the face, not the head', () {
      // Both words are in `SM_Chr_Hair_Beard_01`, so the order of the table is
      // what decides this one.
      expect(attachPointFor('SM_Chr_Hair_Beard_01.fbx')?.name, 'Face');
      expect(attachPointFor('SM_Chr_Attach_Dwarf_Beard_04.fbx')?.name, 'Face');
      expect(attachPointFor('SM_Chr_Attach_Dwarf_Gasmask_01.fbx')?.name, 'Face');
    });

    test('a cape goes on the back and a pauldron on the shoulder', () {
      expect(attachPointFor('SK_Chr_Attach_Cape_01.fbx')?.name, 'Back');
      expect(attachPointFor('SM_Chr_Attach_Bone_Shoulder_01.fbx')?.name,
          'Shoulder');
    });

    test('a name with no body part in it places nothing', () {
      expect(attachPointFor('SM_Bld_Barn_01.fbx'), isNull);
    });
  });

  group('choosing the bone', () {
    test('Sidekick uses its own socket, which it names outright', () {
      expect(
        attachmentBoneFor(
          attachmentName: 'SM_Chr_Attach_Helmet_01.fbx',
          skeleton: _rig(_sidekickRig),
        ),
        'headAttach',
        reason: 'the rig ships a socket; using `head` instead would ignore it',
      );
      expect(
        attachmentBoneFor(
          attachmentName: 'SM_Chr_Attach_Beard_01.fbx',
          skeleton: _rig(_sidekickRig),
        ),
        'faceAttach',
      );
    });

    test('Polygon has no sockets, so the anatomical bone is used', () {
      expect(
        attachmentBoneFor(
          attachmentName: 'SM_Chr_Attach_Helmet_01.fbx',
          skeleton: _rig(_polygonRig),
        ),
        'Head',
      );
      expect(
        attachmentBoneFor(
          attachmentName: 'SM_Chr_Hair_Beard_01.fbx',
          skeleton: _rig(_polygonRig),
        ),
        'Jaw',
      );
      expect(
        attachmentBoneFor(
          attachmentName: 'SK_Chr_Attach_Cape_01.fbx',
          skeleton: _rig(_polygonRig),
        ),
        'Spine_03',
      );
    });

    test('a name that picks a side gets that side', () {
      // hipAttachFront is what makes this Sidekick rather than a plain
      // mannequin, and the family decides which bone list is consulted.
      final rig = _rig([
        'root',
        'pelvis',
        'spine_01',
        'thigh_l',
        'hipAttachFront',
        'shoulderAttach_l',
        'shoulderAttach_r',
      ]);
      expect(
        attachmentBoneFor(attachmentName: 'Pauldron_L.fbx', skeleton: rig),
        'shoulderAttach_l',
        reason: 'the table lists the right shoulder first',
      );
      expect(
        attachmentBoneFor(attachmentName: 'Pauldron_R.fbx', skeleton: rig),
        'shoulderAttach_r',
      );
    });

    test('a rig missing every bone for that point attaches nothing', () {
      expect(
        attachmentBoneFor(
          attachmentName: 'SM_Chr_Attach_Helmet_01.fbx',
          skeleton: _rig(const ['Root', 'Hips', 'Spine_01', 'UpperLeg_R']),
        ),
        isNull,
        reason: 'better unattached than stuck somewhere wrong',
      );
    });
  });

  group('finding what a character can wear', () {
    const character = r'C:\Packs\Empire\FBX\Characters\Captain.fbx';

    test('the Attachments folder and the named pieces both count', () {
      final found = findAttachmentCandidates(
        character: _asset(character, rigFamily: 'polygon'),
        allAssets: [
          _asset(character, rigFamily: 'polygon'),
          _asset(r'C:\Packs\Empire\FBX\Attachments\SM_Chr_Attach_Helmet_01.fbx'),
          _asset(r'C:\Packs\Empire\FBX\Attachments\SM_Chr_Hair_Beard_01.fbx'),
          _asset(r'C:\Packs\Empire\FBX\Props\SM_Prop_Barrel_01.fbx'),
        ],
      );
      expect(found.map((a) => a.name), [
        'SM_Chr_Attach_Helmet_01.fbx',
        'SM_Chr_Hair_Beard_01.fbx',
      ]);
    });

    test('another rigged character is not a hat', () {
      final found = findAttachmentCandidates(
        character: _asset(character, rigFamily: 'polygon'),
        allAssets: [
          _asset(character, rigFamily: 'polygon'),
          _asset(
            r'C:\Packs\Empire\FBX\Characters\Attach_Soldier.fbx',
            rigFamily: 'polygon',
          ),
        ],
      );
      expect(found, isEmpty);
    });

    test('another pack is out of reach', () {
      final found = findAttachmentCandidates(
        character: _asset(character, rigFamily: 'polygon'),
        allAssets: [
          _asset(character, rigFamily: 'polygon'),
          _asset(r'C:\Packs\Other\Attachments\SM_Chr_Attach_Helmet_01.fbx'),
        ],
      );
      expect(found, isEmpty);
    });
  });

  group('placing it', () {
    test('the piece lands on the bone, at the character scale', () {
      // Head sits at y=4 in this rig. The attachment was authored around its
      // joint origin and framed to a unit box; put back, it must straddle y=4.
      final character = _box(
        name: 'character',
        skeleton: _rig(_polygonRig),
        framing: const MeshFraming(center: Vec3(0, 2, 0), scale: 0.5),
      );
      final helmet = _box(
        name: 'helmet',
        framing: const MeshFraming(center: Vec3(0, 0.1, 0), scale: 4),
      );

      final worn = attachToCharacter(
        character: character,
        attachment: helmet,
        boneName: 'Head',
      )!;

      expect(worn.vertices, hasLength(6));
      expect(worn.materials.map((m) => m.name), ['character', 'helmet']);
      expect(
        worn.faces.last.materialIndex,
        1,
        reason: 'the attachment keeps its own material, not the character one',
      );
      expect(worn.faces.last.indices, [3, 4, 5]);

      // Vertex (0,1,0) of the helmet: undo framing -> (0, 0.35, 0); through
      // the Head bone -> (0, 4.35, 0); into the character's box -> (0, 1.175).
      final tip = worn.vertices[5];
      expect(tip.x, closeTo(0, 1e-6));
      expect(tip.y, closeTo(1.175, 1e-6));
    });

    test('a character with no rest pose wears nothing', () {
      expect(
        attachToCharacter(
          character: _box(name: 'character'),
          attachment: _box(
            name: 'helmet',
            framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
          ),
          boneName: 'Head',
        ),
        isNull,
      );
    });

    test('a mesh with no recorded framing wears nothing', () {
      expect(
        attachToCharacter(
          character: _box(
            name: 'character',
            skeleton: _rig(_polygonRig),
            framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
          ),
          attachment: _box(name: 'helmet'),
          boneName: 'Head',
        ),
        isNull,
        reason: 'guessing the scale would place it wrong, which is worse',
      );
    });
  });

  group('a real helmet on a real captain', () {
    Future<Map<String, dynamic>> importEntry(String entry) async {
      final zip = ZipDecoder().decodeBytes(File(pack!).readAsBytesSync());
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

    late MeshModel captain;
    late MeshModel helmet;

    setUpAll(() async {
      if (pack == null) return;
      const captainEntry =
          'SourceFiles/FBX/Characters/Individual/SM_Chr_Captain_Male_01.fbx';
      const helmetEntry = 'SourceFiles/FBX/Attachments/SM_Chr_Attach_Helmet_01.fbx';
      captain = await meshModelFromImporterJson(
        await importEntry(captainEntry),
        modelPath: buildZipVirtualPath(pack, captainEntry),
        name: 'SM_Chr_Captain_Male_01.fbx',
      );
      helmet = await meshModelFromImporterJson(
        await importEntry(helmetEntry),
        modelPath: buildZipVirtualPath(pack, helmetEntry),
        name: 'SM_Chr_Attach_Helmet_01.fbx',
      );
    });

    test('the importer records framing for an unskinned mesh too', () {
      expect(
        helmet.framing,
        isNotNull,
        reason: 'a helmet has no skin to carry it on',
      );
      expect(helmet.skin, isNull);
    });

    test('it lands on the head and not through it', () {
      final bone = attachmentBoneFor(
        attachmentName: helmet.name,
        skeleton: captain.skeleton!,
      );
      expect(bone, 'Head');

      final worn = attachToCharacter(
        character: captain,
        attachment: helmet,
        boneName: bone!,
      )!;
      final placed = worn.vertices.sublist(captain.vertices.length);

      double top(List<Vec3> v) => v.map((p) => p.y).reduce((a, b) => a > b ? a : b);
      double bottom(List<Vec3> v) =>
          v.map((p) => p.y).reduce((a, b) => a < b ? a : b);
      double widest(List<Vec3> v) =>
          v.map((p) => p.x.abs()).reduce((a, b) => a > b ? a : b);

      final headTop = top(captain.vertices);
      // A helmet sits on the head: near the top of the character, never down
      // at the waist, and no wider than a head.
      expect(bottom(placed), greaterThan(headTop * 0.5));
      expect(top(placed), greaterThan(headTop * 0.9));
      expect(top(placed), lessThan(headTop * 1.3));
      expect(
        widest(placed),
        lessThan(widest(captain.vertices) * 0.3),
        reason: 'a head is much narrower than an arm span',
      );
    });
  }, skip: skipReason);
}
