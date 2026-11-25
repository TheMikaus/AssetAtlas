import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rig rule, against the fixture the MCP is also tested on.
///
/// Two implementations of one rule in two languages is the arrangement that
/// always drifts, and this one had: graded against which clip rig actually
/// names each character's bones, over 800 rigged characters, the Python rule
/// was right 786 times and this one 480 -- it called 303 rigged characters
/// rigless. So neither side owns the rule now:
/// `work/atlas_mcp/fixtures/rig_families.json` does, and both suites read it.
/// A case added there fails on whichever side has not caught up.
Map<String, dynamic> loadRigFixture() {
  // The test's working directory is the package root.
  final file = File('../atlas_mcp/fixtures/rig_families.json');
  if (!file.existsSync()) {
    throw StateError(
      'rig_families.json is not beside this checkout at '
      '${file.absolute.path}. The rule is shared with the MCP and this suite '
      'is meaningless without it.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fixture = loadRigFixture();
  final families = fixture['families'] as List;
  final compatible = fixture['compatible'] as List;

  group('the fixture', () {
    test('is loaded and not a stub', () {
      // A fixture that silently stopped loading would pass every loop below.
      expect(families.length, greaterThan(12));
      expect(compatible.length, greaterThan(8));
    });

    test('names a family this code knows for every case', () {
      for (final row in families) {
        final name = (row as Map<String, dynamic>)['family'] as String;
        expect(
          RigFamily.values.map((f) => f.name),
          contains(name),
          reason: 'the fixture expects a family called $name',
        );
      }
    });
  });

  group('rigFamilyFromMarkers, against the shared fixture', () {
    for (final entry in families) {
      final row = entry as Map<String, dynamic>;
      final markers = (row['markers'] as List).map((m) => m as String).toList();
      final bones = row['bones'] as int;
      final expected = row['family'] as String;
      test('${markers.isEmpty ? 'no markers' : markers.join(', ')} '
          'with $bones bones is $expected', () {
        expect(
          rigFamilyFromMarkers(markers, bones: bones).name,
          expected,
          reason: row['why'] as String?,
        );
      });
    }
  });

  group('rigFamiliesCompatible, against the shared fixture', () {
    for (final entry in compatible) {
      final row = entry as Map<String, dynamic>;
      final character = rigFamilyByName(row['character'] as String);
      final clip = rigFamilyByName(row['clip'] as String);
      final same = row['sameContainer'] as bool;
      final expected = row['expected'] as bool;
      test('${row['character']} character, ${row['clip']} clip, '
          '${same ? 'same' : 'different'} pack: $expected', () {
        expect(
          rigFamiliesCompatible(
            character,
            clip,
            containerA: 'pack-a.zip',
            containerB: same ? 'pack-a.zip' : 'pack-b.zip',
          ),
          expected,
          reason: row['why'] as String?,
        );
      });
    }

    test('an unnamed rig with no container to compare drives nothing', () {
      // The caller that cannot say where the files came from gets the
      // conservative answer rather than a guess.
      expect(
        rigFamiliesCompatible(RigFamily.other, RigFamily.other),
        isFalse,
      );
    });
  });

  group('the rule, in its own words', () {
    test('Sidekick is checked before the mannequin it extends', () {
      // Every mannequin bone appears in a Sidekick rig, so testing for
      // `pelvis` first would classify every Sidekick file as Unreal.
      const sidekick = [
        'pelvis',
        'thigh_l',
        'clavicle_l',
        'spine_01',
        'hipAttachFront',
        'ik_hand_root',
      ];
      expect(
        rigFamilyFromMarkers(sidekick, bones: 121),
        RigFamily.sidekick,
      );
    });

    test('a prop with no bones has no rig', () {
      expect(rigFamilyFromMarkers(const [], bones: 0), RigFamily.none);
    });

    test('a skeleton with no known markers is a rig, not a prop', () {
      // Changed on 2026-11-24, with Mike's approval: `none` used to mean both
      // "no skeleton" and "a skeleton we cannot name", and the second kind
      // could never be animated. 91 of the library's 796 clips are here.
      expect(rigFamilyFromMarkers(const ['Bone_01'], bones: 24), RigFamily.other);
      expect(rigFamilyFromMarkers(const ['Bone_01'], bones: 0), RigFamily.none);
    });

    test('one generic marker does not name a family', () {
      expect(rigFamilyFromMarkers(const ['Hips'], bones: 58), RigFamily.other);
    });

    test('the SK_ prefix does not decide it', () {
      // SK_Chr_MilitaryMale_01 carries the Polygon markers despite the name.
      expect(
        rigFamilyFromMarkers(const [
          'Hips',
          'UpperLeg_R',
          'Clavicle_L',
          'Spine_01',
        ], bones: 52),
        RigFamily.polygon,
      );
    });
  });

  group('labels', () {
    test('each family has one for the filter menu', () {
      expect(RigFamily.polygon.label, 'Polygon');
      expect(RigFamily.sidekick.label, 'Sidekick');
      expect(RigFamily.unreal.label, 'Unreal');
      expect(RigFamily.other.label, 'Other rig');
      expect(RigFamily.none.label, 'No rig');
    });

    test('every family has a label, including any added later', () {
      for (final family in RigFamily.values) {
        expect(family.label, isNotEmpty);
      }
    });
  });
}
