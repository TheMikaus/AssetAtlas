// A modular kit: one model with interchangeable parts, every option shipped
// in the same file at the joint it hangs from.
//
// The Polygon mech is 215 nodes in 70 name families -- eight heads, ten
// shoulder plates a side, twelve chest weapons a side -- all at their joints
// at once. It renders as a mech, but as eight mechs' worth of parts
// interpenetrating.
//
// Names alone cannot sort this out. `geo_c_head_01..08` are eight whole heads
// and `geo_l_index_01..03` are the three segments of one finger, and nothing
// in either name says which. So the test is spatial, the same way
// objectsAreStackedVariants is: variants of a slot all contain the joint, so
// their boxes overlap each other, while a row of parts is laid end to end.
import 'dart:io';
import 'dart:typed_data';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One axis-aligned box as a single triangle-pair-free stand-in: three corners
/// spanning the box, which is all the slot test reads.
void _addBox(
  List<Vec3> vertices,
  List<MeshFace> faces,
  int object, {
  required double minX,
  required double maxX,
  required double minY,
  required double maxY,
  double minZ = -0.1,
  double maxZ = 0.1,
}) {
  final base = vertices.length;
  vertices.addAll([
    Vec3(minX, minY, minZ),
    Vec3(maxX, minY, maxZ),
    Vec3(maxX, maxY, minZ),
  ]);
  faces.add(MeshFace([base, base + 1, base + 2], 0, const [], const {}, object));
}

MeshModel _model(List<String> names, void Function(List<Vec3>, List<MeshFace>) build) {
  final vertices = <Vec3>[];
  final faces = <MeshFace>[];
  build(vertices, faces);
  return MeshModel(
    name: 'kit',
    vertices: vertices,
    faces: faces,
    materials: const [
      MeshMaterial(name: 'only', color: Color(0xff888888), textures: []),
    ],
    objectNames: names,
  );
}

/// Three slots of three variants each, stacked at three different joints,
/// plus one chassis part in no slot -- the shape of a kit.
MeshModel _kit() => _model(
  [
    'geo_c_head_01', 'geo_c_head_02', 'geo_c_head_03',
    'geo_l_shoulder_armor_01', 'geo_l_shoulder_armor_02',
    'geo_l_shoulder_armor_03',
    'geo_c_hips_armor_01', 'geo_c_hips_armor_02', 'geo_c_hips_armor_03',
    'geo_c_chest',
  ],
  (vertices, faces) {
    for (var i = 0; i < 3; i += 1) {
      // Each variant a slightly different size, all at the same joint.
      final grow = i * 0.05;
      _addBox(vertices, faces, i,
          minX: -0.2 - grow, maxX: 0.2 + grow, minY: 1.6 - grow, maxY: 2.0 + grow);
      _addBox(vertices, faces, 3 + i,
          minX: -0.8 - grow, maxX: -0.4 + grow, minY: 1.2 - grow, maxY: 1.5 + grow);
      _addBox(vertices, faces, 6 + i,
          minX: -0.3 - grow, maxX: 0.3 + grow, minY: 0.6 - grow, maxY: 0.9 + grow);
    }
    _addBox(vertices, faces, 9, minX: -0.4, maxX: 0.4, minY: 1.0, maxY: 1.6);
  },
);

/// Three numbered parts laid end to end: a finger, not a slot.
MeshModel _finger() => _model(
  ['geo_l_index_01', 'geo_l_index_02', 'geo_l_index_03'],
  (vertices, faces) {
    for (var i = 0; i < 3; i += 1) {
      _addBox(vertices, faces, i,
          minX: i * 0.1, maxX: i * 0.1 + 0.1, minY: 0, maxY: 0.08);
    }
  },
);

void main() {
  group('the family a name belongs to', () {
    test('is everything before the last number', () {
      expect(objectSlotFamily('geo_c_head_01'), 'geo_c_head');
      expect(objectSlotFamily('geo_l_shoulder_armor_07'),
          'geo_l_shoulder_armor');
    });

    test('keeps a variant with a word after its number in the family', () {
      // The mech names two of the ten shoulder plates this way, and they are
      // plates like the other eight.
      expect(objectSlotFamily('geo_l_shoulder_armor_07_energyShields'),
          'geo_l_shoulder_armor');
      expect(objectSlotFamily('geo_l_chest_attach_weapon_03_Empty'),
          'geo_l_chest_attach_weapon');
    });

    test('ignores case, because one pack does not', () {
      // geo_L_elbow_armor_01 sits beside geo_l_elbow_armor_05 in the mech.
      expect(objectSlotFamily('geo_L_elbow_armor_01'),
          objectSlotFamily('geo_l_elbow_armor_05'));
    });

    test('leaves a number that belongs to a prefix alone', () {
      expect(objectSlotFamily('SM_Mech_Cockpit_01_Monitor_04'),
          'sm_mech_cockpit_01_monitor');
    });

    test('a name with no number is its own family', () {
      expect(objectSlotFamily('geo_c_neck'), 'geo_c_neck');
    });
  });

  group('reading a slot', () {
    test('finds one slot per joint, in file order', () {
      final slots = objectSlotsOf(_kit());
      expect(slots.map((slot) => slot.key), [
        'geo_c_head',
        'geo_l_shoulder_armor',
        'geo_c_hips_armor',
      ]);
      expect(slots.map((slot) => slot.objects), [
        [0, 1, 2],
        [3, 4, 5],
        [6, 7, 8],
      ]);
    });

    test('a chassis part in no family is in no slot', () {
      final slots = objectSlotsOf(_kit());
      expect(slots.expand((slot) => slot.objects), isNot(contains(9)));
    });

    test('numbered parts laid end to end are not a slot', () {
      expect(objectSlotsOf(_finger()), isEmpty);
    });

    test('a kit is a kit; a finger is not', () {
      expect(modelIsModularKit(_kit()), isTrue);
      expect(modelIsModularKit(_finger()), isFalse);
    });

    test('a character sheet is not a kit, however it reads by name', () {
      // Eleven whole bodies in one place pass the slot test -- they are
      // eleven variants of one place -- but they are a sheet, and the viewer
      // already shows them one at a time. Three families so the slot count
      // alone would not settle it.
      final sheet = _model(
        [
          for (final kind in ['nomad_male', 'nomad_female', 'skeleton'])
            for (var i = 1; i <= 3; i += 1) 'chr_${kind}_0$i',
        ],
        (vertices, faces) {
          for (var i = 0; i < 9; i += 1) {
            _addBox(vertices, faces, i, minX: -1, maxX: 1, minY: -1, maxY: 1);
          }
        },
      );
      expect(objectSlotsOf(sheet).length, greaterThanOrEqualTo(3));
      expect(objectsAreStackedVariants(sheet), isTrue);
      expect(modelIsModularKit(sheet), isFalse);
    });

    test('a model with one node has no slots to pick', () {
      final single = _model(['SM_Prop_Anvil_01'], (vertices, faces) {
        _addBox(vertices, faces, 0, minX: -1, maxX: 1, minY: -1, maxY: 1);
      });
      expect(objectSlotsOf(single), isEmpty);
      expect(modelIsModularKit(single), isFalse);
    });
  });

  group('the mask', () {
    test('hides every variant but the chosen one, and no chassis', () {
      final kit = _kit();
      final slots = objectSlotsOf(kit);
      final hidden = hiddenObjectsFor(
        objectCount: kit.objectNames.length,
        slots: slots,
        choice: const [0, 2, 1],
      );
      expect(hidden.toList(), [0, 1, 1, 1, 1, 0, 1, 0, 1, 0]);
    });

    test('an empty slot hides all of its variants', () {
      final kit = _kit();
      final hidden = hiddenObjectsFor(
        objectCount: kit.objectNames.length,
        slots: objectSlotsOf(kit),
        choice: const [slotChoiceNone, 0, 0],
      );
      expect(hidden.sublist(0, 3), [1, 1, 1]);
      expect(hidden[3], 0);
    });

    test('a short choice list falls back to the first variant', () {
      final kit = _kit();
      final hidden = hiddenObjectsFor(
        objectCount: kit.objectNames.length,
        slots: objectSlotsOf(kit),
        choice: const [],
      );
      expect(hidden.toList(), [0, 1, 1, 0, 1, 1, 0, 1, 1, 0]);
    });

    test('tells one assembly from another for the frame cache', () {
      final kit = _kit();
      final slots = objectSlotsOf(kit);
      Uint8List maskFor(List<int> choice) => hiddenObjectsFor(
        objectCount: kit.objectNames.length,
        slots: slots,
        choice: choice,
      );
      expect(hiddenObjectsDigest(null), 0);
      expect(
        hiddenObjectsDigest(maskFor(const [0, 0, 0])),
        isNot(hiddenObjectsDigest(maskFor(const [1, 0, 0]))),
      );
      expect(
        hiddenObjectsDigest(maskFor(const [0, 1, 2])),
        hiddenObjectsDigest(maskFor(const [0, 1, 2])),
      );
    });
  });

  group('drawing an assembly', () {
    RasterResult render(MeshModel mesh, {Uint8List? hidden}) => rasterizeMesh(
      mesh: mesh,
      yaw: 0,
      pitch: 0,
      zoom: 1,
      width: 64,
      height: 64,
      renderMode: RenderMode.solid,
      lightingMode: LightingMode.unlit,
      cullBackFaces: false,
      hiddenObjects: hidden,
    );

    test('the whole file draws every face', () {
      final kit = _kit();
      expect(render(kit).drawnFaces, kit.faces.length);
    });

    test('one variant per slot draws four of ten', () {
      final kit = _kit();
      final hidden = hiddenObjectsFor(
        objectCount: kit.objectNames.length,
        slots: objectSlotsOf(kit),
        choice: const [0, 0, 0],
      );
      // Three slots contribute one each; the chassis part is always there.
      expect(render(kit, hidden: hidden).drawnFaces, 4);
    });

    test('a mask outside the object range is ignored, not fatal', () {
      final kit = _kit();
      expect(render(kit, hidden: Uint8List(2)).drawnFaces, kit.faces.length);
    });

    test('the face count per node adds up to the file', () {
      final kit = _kit();
      final counts = objectFaceCounts(kit);
      expect(counts.length, kit.objectNames.length);
      expect(counts.reduce((a, b) => a + b), kit.faces.length);
    });
  });

  group('what the panel says', () {
    test('a slot is named without the modelling boilerplate', () {
      expect(slotDisplayName('geo_c_head'), 'head');
      expect(slotDisplayName('geo_l_shoulder_armor'), 'left shoulder armor');
      expect(slotDisplayName('geo_r_lowerleg_knee_armor'),
          'right lowerleg knee armor');
    });

    test('a variant is named by what it does not share', () {
      expect(
        slotVariantLabel(key: 'geo_c_head', objectName: 'geo_c_head_03'),
        '03',
      );
      expect(
        slotVariantLabel(
          key: 'geo_l_shoulder_armor',
          objectName: 'geo_l_shoulder_armor_07_energyShields',
        ),
        '07 energyShields',
      );
    });

    test('a variant whose name is only the family keeps its name', () {
      expect(
        slotVariantLabel(key: 'geo_c_head', objectName: 'geo_c_head'),
        'geo_c_head',
      );
    });
  });

  group('the real kit', () {
    // Set ASSET_ATLAS_KIT_FBX to a modular-kit FBX to run these. Not
    // hard-coded: it points at a personal asset library, not a fixture that
    // can live in the repo.
    final path = Platform.environment['ASSET_ATLAS_KIT_FBX'];
    final skip = (path == null || path.isEmpty || !File(path).existsSync())
        ? 'set ASSET_ATLAS_KIT_FBX to a modular-kit FBX'
        : null;

    late MeshModel mesh;

    setUpAll(() async {
      if (skip != null) return;
      mesh = await importFbxWithUfbx(path!, 'kit');
    });

    test('is a kit, and its slots are the interchangeable parts', () async {
      expect(modelIsModularKit(mesh), isTrue);
      final slots = objectSlotsOf(mesh);
      final byKey = {for (final slot in slots) slot.key: slot.objects.length};

      // Eight heads for one neck, ten plates for each shoulder.
      expect(byKey['geo_c_head'], 8);
      expect(byKey['geo_l_shoulder_armor'], 10);
      expect(byKey['geo_r_shoulder_armor'], 10);

      // Three segments of a finger, four flaps around an exhaust and four
      // monitors in a cockpit are parts, not choices.
      expect(byKey.containsKey('geo_l_index'), isFalse);
      expect(byKey.containsKey('exhaustflap_c'), isFalse);
      expect(byKey.containsKey('sm_mech_cockpit_01_monitor'), isFalse);
    }, skip: skip);

    test('assembles to a fraction of the faces the file holds', () async {
      final slots = objectSlotsOf(mesh);
      final hidden = hiddenObjectsFor(
        objectCount: mesh.objectNames.length,
        slots: slots,
        choice: [for (var i = 0; i < slots.length; i += 1) 0],
      );
      final counts = objectFaceCounts(mesh);
      var shown = mesh.faces.length;
      for (var i = 0; i < hidden.length; i += 1) {
        if (hidden[i] != 0) shown -= counts[i];
      }
      expect(shown, lessThan(mesh.faces.length ~/ 2));
      expect(shown, greaterThan(0));
    }, skip: skip);
  });
}
