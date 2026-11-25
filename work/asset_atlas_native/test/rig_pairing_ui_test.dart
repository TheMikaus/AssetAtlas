import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pairing lists on the details panel, and auditioning from them.
///
/// The rule the audition tests pin: trying a clip on a model must not change
/// the character chosen for animations. That choice drives every clip
/// preview in the app and is saved to the database; a list of 346 clips with
/// a play button beside each would otherwise overwrite it on a single click.

const _mannequin = [
  'root',
  'pelvis',
  'spine_01',
  'spine_02',
  'clavicle_l',
  'clavicle_r',
  'thigh_l',
  'thigh_r',
  'hand_l',
  'hand_r',
];

const _polygon = [
  'Root',
  'Hips',
  'UpperLeg_L',
  'UpperLeg_R',
  'Foot_L',
  'Foot_R',
  'Chest',
  'Neck',
  'Finger_01',
  'Toe_L',
];

AssetItem _asset(
  String path, {
  required String modelKind,
  required List<String> bones,
}) => AssetItem(
  id: path,
  name: path.split('/').last,
  path: 'zip:C:/Packs/PackA.zip::$path',
  relativePath: path,
  sourceRoot: r'C:\Packs',
  sourceName: 'Packs',
  ext: 'fbx',
  type: 'model',
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
  tags: const [],
  modelKind: modelKind,
  rigFamily: bones.isEmpty ? 'none' : 'other',
  rigSignature: rigSignatureOf(bones),
);

void main() {
  setUp(resetRigIndex);
  tearDown(resetRigIndex);

  final robot = _asset(
    'Characters/SK_Robot.fbx',
    modelKind: 'mesh',
    bones: _mannequin,
  );
  final knight = _asset(
    'Characters/SK_Knight.fbx',
    modelKind: 'mesh',
    bones: _polygon,
  );
  final walk = _asset(
    'Clips/A_Walk.fbx',
    modelKind: 'animation',
    bones: _mannequin,
  );
  final idle = _asset(
    'Clips/A_Idle.fbx',
    modelKind: 'animation',
    bones: _mannequin,
  );
  final crate = _asset(
    'Props/SM_Crate.fbx',
    modelKind: 'mesh',
    bones: const [],
  );
  final catalog = [robot, knight, walk, idle, crate];
  final bones = {
    rigSignatureOf(_mannequin): _mannequin,
    rigSignatureOf(_polygon): _polygon,
  };

  Future<void> pump(
    WidgetTester tester,
    AssetItem item, {
    AssetItem? audition,
    ValueChanged<AssetItem?>? onAudition,
    ValueChanged<AssetItem>? onActivate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 700,
            child: RigPairingList(
              item: item,
              allAssets: catalog,
              rigBones: bones,
              audition: audition,
              onAudition: onAudition ?? (_) {},
              onActivateAsset: onActivate ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a rigged model lists the clips that drive it', (tester) async {
    await pump(tester, robot);
    expect(find.text('Animations for this model (2)'), findsOneWidget);
    expect(find.text('A_Idle.fbx'), findsOneWidget);
    expect(find.text('A_Walk.fbx'), findsOneWidget);
  });

  testWidgets('a clip lists the models it drives', (tester) async {
    await pump(tester, walk);
    expect(find.text('Models this clip drives (1)'), findsOneWidget);
    expect(find.text('SK_Robot.fbx'), findsOneWidget);
    expect(find.text('SK_Knight.fbx'), findsNothing);
  });

  testWidgets('a prop shows no heading at all', (tester) async {
    await pump(tester, crate);
    expect(find.textContaining('Animations for'), findsNothing);
    expect(find.textContaining('Models this clip'), findsNothing);
  });

  testWidgets('a rig with nothing to pair with shows no heading', (
    tester,
  ) async {
    // The Polygon character is alone on its rig here.
    await pump(tester, knight);
    expect(find.textContaining('Animations for'), findsNothing);
  });

  testWidgets('pressing play asks for an audition, and pressing it again '
      'stops', (tester) async {
    final asked = <AssetItem?>[];
    await pump(tester, robot, onAudition: asked.add);
    await tester.tap(find.byIcon(Icons.play_circle_outline).first);
    expect(asked, hasLength(1));
    expect(asked.first?.name, 'A_Idle.fbx');

    await pump(tester, robot, audition: idle, onAudition: asked.add);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    expect(asked.last, isNull, reason: 'the second press stops it');
  });

  testWidgets('auditioning does not touch the chosen character', (
    tester,
  ) async {
    final before = AnimationCharacter.instance.path.value;
    await pump(tester, robot, onAudition: (_) {});
    await tester.tap(find.byIcon(Icons.play_circle_outline).first);
    await tester.pump();
    expect(AnimationCharacter.instance.path.value, before);
  });

  testWidgets('tapping the name opens that asset', (tester) async {
    final opened = <AssetItem>[];
    await pump(tester, robot, onActivate: opened.add);
    await tester.tap(find.text('A_Walk.fbx'));
    expect(opened.single.name, 'A_Walk.fbx');
  });

  testWidgets('without a catalog of bone names, nothing is claimed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RigPairingList(
            item: robot,
            allAssets: catalog,
            rigBones: const {},
            onActivateAsset: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Animations for'), findsNothing);
  });
}
