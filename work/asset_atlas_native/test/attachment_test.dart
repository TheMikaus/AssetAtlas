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
import 'dart:typed_data';

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

    test('the OBJ twin of a piece is left out', () {
      // Every piece ships as FBX and OBJ. The OBJ is in centimetres with
      // nothing in the file to say so, so it cannot be placed -- and listing
      // it put two identical chips in the panel, one of which did nothing.
      final found = findAttachmentCandidates(
        character: _asset(character, rigFamily: 'polygon'),
        allAssets: [
          _asset(character, rigFamily: 'polygon'),
          _asset(r'C:\Packs\Empire\FBX\Attachments\SM_Chr_Attach_Helmet_01.fbx'),
          _asset(
            r'C:\Packs\Empire\OBJ\SM_Chr_Attach_Helmet_01.obj',
            ext: 'obj',
          ),
        ],
      );
      expect(found.map((a) => a.name), ['SM_Chr_Attach_Helmet_01.fbx']);
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

    test('the bone position places it; the bone orientation does not', () {
      // Spine_03 on these rigs is cycled x->y->z, which swung a cape out
      // sideways when the whole bone transform was applied. A piece hangs the
      // way it hangs in its own file; the socket is a place, not a direction.
      final turned = <double>[];
      for (var i = 0; i < 2; i += 1) {
        turned.addAll([0, 1, 0, -1, 0, 0, 0, 0, 1, 0, i * 3.0, 0]);
      }
      final rig = SkeletonAnimation.fromJson({
        'bones': [
          {'name': 'Root', 'parent': -1, 'path': 'Root'},
          {'name': 'Spine_03', 'parent': 0, 'path': 'Root/Spine_03'},
        ],
        'stride': 12,
        'frameRate': 30.0,
        'rest': turned,
        'frames': [turned],
      })!;
      final character = _box(
        name: 'character',
        skeleton: rig,
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );
      final cape = _box(
        name: 'cape',
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );
      final worn = attachToCharacter(
        character: character,
        attachment: cape,
        boneName: 'Spine_03',
      )!;
      // The cape's tip (0,1,0) lands straight above the socket at (0,3,0):
      // (0,4,0), not turned onto the x axis.
      final tip = worn.vertices[5];
      expect(tip.x, closeTo(0, 1e-6));
      expect(tip.y, closeTo(4, 1e-6));
    });

    test('a held piece points along the arm, a worn one keeps its way up', () {
      // Elbow at (0,1,0), hand at (1,1,0): the forearm runs along +x. A sword
      // is authored standing on its grip with the blade along +y.
      final rest = <double>[
        1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, // Root
        1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, // Elbow_R
        1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, // Hand_R
      ];
      final rig = SkeletonAnimation.fromJson({
        'bones': [
          {'name': 'Root', 'parent': -1, 'path': 'Root'},
          {'name': 'Elbow_R', 'parent': 0, 'path': 'Root/Elbow_R'},
          {'name': 'Hand_R', 'parent': 1, 'path': 'Root/Elbow_R/Hand_R'},
        ],
        'stride': 12,
        'frameRate': 30.0,
        'rest': rest,
        'frames': [rest],
      })!;
      final character = _box(
        name: 'character',
        skeleton: rig,
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );
      final sword = _box(
        name: 'sword',
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );

      final held = attachToCharacter(
        character: character,
        attachment: sword,
        boneName: 'Hand_R',
        alongBone: true,
      )!;
      // The blade tip (0,1,0) now lies along +x from the hand: (2,1,0).
      final tip = held.vertices[5];
      expect(tip.x, closeTo(2, 1e-5));
      expect(tip.y, closeTo(1, 1e-5));

      final worn = attachToCharacter(
        character: character,
        attachment: sword,
        boneName: 'Hand_R',
      )!;
      // Not held: it stands straight up out of the hand, which is the bug
      // that made every mini-fantasy weapon poke past the head.
      expect(worn.vertices[5].x, closeTo(1, 1e-5));
      expect(worn.vertices[5].y, closeTo(2, 1e-5));
    });

    test('the hand point is held and the head point is worn', () {
      expect(attachPointFor('Prop_Sword_Broken_01.fbx')?.held, isTrue);
      expect(attachPointFor('SM_Chr_Attach_Helmet_01.fbx')?.held, isFalse);
    });

    test('the piece is skinned to its socket, so it follows the clip', () {
      final character = _box(
        name: 'character',
        skeleton: _rig(_polygonRig),
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );
      // A skin with one bone the body uses, and no Head: the head has to be
      // added with a bind matrix of its own.
      final skinned = MeshModel(
        name: character.name,
        vertices: character.vertices,
        faces: character.faces,
        materials: character.materials,
        skeleton: character.skeleton,
        framing: character.framing,
        skin: SkinBinding(
          boneNames: const ['Hips'],
          bonePaths: const ['Hips'],
          bindInverse: Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -1, 0]),
          influences: Float32List.fromList([0, 1, 0, 0, 0, 0, 0, 0]),
          vertexSkin: Int32List.fromList([0, 0, 0]),
        ),
      );
      final helmet = _box(
        name: 'helmet',
        framing: const MeshFraming(center: Vec3(0, 0, 0), scale: 1),
      );
      final worn = attachToCharacter(
        character: skinned,
        attachment: helmet,
        boneName: 'Head',
      )!;
      final skin = worn.skin!;
      expect(skin.boneNames.last, 'Head');
      expect(skin.vertexSkin, hasLength(6));
      // Each helmet vertex has one influence, weight 1, on the Head bone.
      final block = skin.vertexSkin[5];
      expect(skin.influences[block * 8], skin.boneNames.length - 1);
      expect(skin.influences[block * 8 + 1], 1);

      // Posed against its own rest, the character -- helmet included -- must
      // come back where it was. That is the identity test, and it is what
      // proves the added bind matrix is right.
      final posed = poseSkinnedVertices(
        character: worn,
        clip: character.skeleton!,
        frame: 0,
      );
      for (var i = 0; i < worn.vertices.length; i += 1) {
        expect(posed[i].x, closeTo(worn.vertices[i].x, 1e-4), reason: 'v$i');
        expect(posed[i].y, closeTo(worn.vertices[i].y, 1e-4), reason: 'v$i');
        expect(posed[i].z, closeTo(worn.vertices[i].z, 1e-4), reason: 'v$i');
      }
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
