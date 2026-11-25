@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:asset_atlas_native/main.dart';

/// Why the turret and the mining laser draw as black silhouettes.
///
/// Both report their textures as found, and both are wrong about what was
/// found. The mining laser asks for a colour map and an emissive map and
/// resolves only the emissive -- which is black but for a few bright spots.
/// The turret asks for a city texture and resolves the *signs* atlas of
/// another pack, which is mostly dark.
///
/// The first question is whether the index that replaced the relink walk
/// yesterday caused it, so every reference is resolved both ways and the
/// answers compared. `byScan: true` is the walk as it was.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=<a copy of asset_atlas_native.db> \
///     flutter test test/black_render_diagnosis_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' && dbPath != null;

  const subjects = <String, List<String>>{
    // model path -> the texture references its materials ask for
    r'zip:Z:\Assets\Synty\POLYGON_SciFi_Horror_SourceFiles_v2.zip::SourceFiles/SciFiHorror/FBX/Weapons/SM_Wep_Mining_Laser_01.fbx':
        [
          r'..\..\..\..\..\..\Dropbox\SyntyStudios\PolygonHorrorSpace\Working\_Textures\Alts\PolygonHorrorSpace_Texture_01_A.png',
          r'..\..\..\..\..\..\Dropbox\SyntyStudios\PolygonHorrorSpace\Working\_Textures\Emissive\PolygonHorrorSpace_Emissive_01_A.png',
        ],
    r'zip:Z:\Assets\Synty\POLYGON_SciFiSpace_SourceFiles.zip::_SourceFiles/FBX/SM_Prop_Turret_Base_Double_01.fbx':
        [
          r'U:\Dropbox\SyntyStudios\PolygonSciFiSpace\Working\_Textures\PolygonSciFiCity_Texture_01_A.psd',
        ],
    // A control that draws correctly.
    r'zip:Z:\Assets\Synty\POLYGON_SciFi_Horror_SourceFiles_v2.zip::SourceFiles/SciFiHorror/FBX/Props/SM_Prop_Crate_01_Alt_01.fbx':
        [
          r'..\..\..\..\..\..\Dropbox\SyntyStudios\PolygonHorrorSpace\Working\_Textures\PolygonHorrorSpace_Texture_01.psd',
        ],
  };

  test('what each reference resolves to, indexed and by scan', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      dbPath!,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await database.rawQuery(
      'select id, name, path, relative_path, source_root, source_name, ext, '
      'type, size, modified_ms from catalog_assets',
    );
    final catalog = [
      for (final row in rows)
        AssetItem(
          id: (row['id'] as String?) ?? (row['path'] as String),
          name: row['name'] as String,
          path: row['path'] as String,
          relativePath: (row['relative_path'] as String?) ?? '',
          sourceRoot: (row['source_root'] as String?) ?? '',
          sourceName: (row['source_name'] as String?) ?? '',
          ext: ((row['ext'] as String?) ?? '').toLowerCase(),
          type: (row['type'] as String?) ?? '',
          size: (row['size'] as int?) ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch(
            (row['modified_ms'] as int?) ?? 0,
          ),
          tags: const [],
        ),
    ];
    await database.close();
    expect(catalog.length, greaterThan(1000));

    var disagreements = 0;
    subjects.forEach((modelPath, references) {
      stdout.writeln('');
      stdout.writeln(modelPath.split('/').last);
      for (final reference in references) {
        final asked = reference.split(RegExp(r'[\\/]')).last;
        final indexed = findDeterministicTextureRelink(
          modelPath,
          reference,
          catalog,
        );
        final scanned = findDeterministicTextureRelink(
          modelPath,
          reference,
          catalog,
          byScan: true,
        );
        if (indexed != scanned) disagreements += 1;
        stdout.writeln('  asks     $asked');
        stdout.writeln(
          '  indexed  ${indexed?.split(RegExp(r"[\\/]")).last ?? "(nothing)"}',
        );
        stdout.writeln(
          '  by scan  ${scanned?.split(RegExp(r"[\\/]")).last ?? "(nothing)"}'
          '${indexed == scanned ? "   (same)" : "   <-- DIFFERS"}',
        );
      }
    });

    stdout.writeln('');
    stdout.writeln('$disagreements of the references resolve differently');
    expect(
      disagreements,
      0,
      reason: 'the index and the walk must agree; if they do not, the index '
          'caused this and the equivalence claim was wrong',
    );
  }, skip: enabled ? null : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB', timeout: const Timeout(Duration(minutes: 10)));

  /// The two candidates the turret chooses between score identically, and the
  /// tie-break is alphabetical on path -- which puts the signs sheet ahead of
  /// the atlas the model wants. Printed rather than asserted, because the fix
  /// for it changes which texture wins across the library.
  test('what the turret scores, and why the wrong one wins', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      dbPath!,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await database.rawQuery(
      'select name, path, relative_path, source_root, source_name, ext, '
      'type, size, modified_ms from catalog_assets '
      "where lower(path) like '%polygon_scifispace_sourcefiles.zip%' "
      "and lower(name) like '%texture_01_a%'",
    );
    stdout.writeln('');
    stdout.writeln('  candidates the turret picks between:');
    for (final row in rows) {
      stdout.writeln(
        '    ${(row['name'] as String).padRight(44)}'
        '${((row['size'] as int?) ?? 0) ~/ 1024} KB',
      );
    }
    await database.close();
    expect(rows.length, greaterThanOrEqualTo(2),
        reason: 'both the signs sheet and the atlas must be present for this '
            'to be the tie it looks like');
  }, skip: enabled ? null : 'set ATLAS_BENCH=1 and ATLAS_CATALOG_DB', timeout: const Timeout(Duration(minutes: 10)));
}
