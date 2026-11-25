import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rig signature and the bone-level match rule, against the fixtures the
/// MCP is also tested on.
///
/// A signature is how two files are known to be on the same rig, and it is
/// computed in Dart by Atlas and in Python by the backfill and the MCP. If
/// the two ever disagreed, half the catalog would carry keys the other half
/// could not match -- silently, because a hash that differs is not an error,
/// it is just a rig nobody shares. So neither side owns the definition:
/// `work/atlas_mcp/fixtures/` does, and both suites read it.
Map<String, dynamic> loadFixture(String name) {
  final file = File('../atlas_mcp/fixtures/$name');
  if (!file.existsSync()) {
    throw StateError(
      '$name is not beside this checkout at ${file.absolute.path}. The rule '
      'is shared with the MCP and this suite is meaningless without it.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<String> _names(dynamic value) =>
    (value as List).map((entry) => entry as String).toList();

void main() {
  final signatures = loadFixture('rig_signatures.json')['cases'] as List;
  final matches = loadFixture('rig_match.json')['cases'] as List;

  group('the fixtures', () {
    test('are loaded and not stubs', () {
      expect(signatures.length, greaterThan(8));
      expect(matches.length, greaterThan(6));
    });
  });

  group('rigSignatureOf, against the shared fixture', () {
    for (final entry in signatures) {
      final row = entry as Map<String, dynamic>;
      final bones = _names(row['bones']);
      test('${bones.length} bones: ${row['why']}', () {
        expect(
          rigSignatureOf(bones),
          row['signature'],
          reason: 'Python computes this one; Dart must agree exactly',
        );
      });
    }

    test('case and order do not change a rig', () {
      final one = rigSignatureOf(['Hips', 'Spine_01', 'Head']);
      expect(rigSignatureOf(['head', 'HIPS', 'spine_01']), one);
      expect(rigSignatureOf(['Spine_01', 'Head', 'Hips']), one);
    });

    test('a different set is a different rig', () {
      expect(
        rigSignatureOf(['Hips', 'Spine_01']),
        isNot(rigSignatureOf(['Hips', 'Spine_01', 'Head'])),
      );
    });

    test('a rig with no bones has no signature', () {
      expect(rigSignatureOf(const []), isEmpty);
      expect(rigSignatureOf(const ['', '']), isEmpty);
    });

    test('the signature is twelve hex digits', () {
      final signature = rigSignatureOf(['Hips']);
      expect(signature, hasLength(12));
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(signature), isTrue);
    });
  });

  group('rigMatchNames, against the shared fixture', () {
    for (final entry in matches) {
      final row = entry as Map<String, dynamic>;
      final character = _names(row['character']);
      final clip = _names(row['clip']);
      test('${character.length} vs ${clip.length} bones: ${row['why']}', () {
        expect(
          rigMatchNames(character, clip),
          row['compatible'],
          reason: row['why'] as String?,
        );
      });
    }
  });

  group('the two forms of the rule agree', () {
    test('counts decide, whoever counted them', () {
      // The skeleton form can only find more than the name form -- it has
      // paths as well -- so anything the names accept, the skeletons must.
      expect(
        rigMatchFromCounts(characterBones: 48, exact: 19, folded: 28),
        isTrue,
      );
      expect(
        rigMatchFromCounts(characterBones: 48, exact: 0, folded: 14),
        isFalse,
      );
      expect(
        rigMatchFromCounts(characterBones: 60, exact: 5, folded: 5),
        isTrue,
        reason: 'the old four-bone rule, kept',
      );
      expect(
        rigMatchFromCounts(characterBones: 0, exact: 0, folded: 0),
        isFalse,
      );
    });
  });
}
