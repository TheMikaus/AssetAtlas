@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:asset_atlas_native/main.dart';

/// What the library's materials actually ask for, and what each asks resolves
/// to. Written to a file so a change to the relink scoring can be measured:
/// run it, change the scoring, run it again, diff.
///
/// A scoring change moves which texture wins, and a model whose texture moved
/// renders differently -- so its embedding is stale. The size of that re-tag
/// is what this measures.
///
/// The references come from the importer, not from the catalog. The first
/// version of this built them from the texture names inside each archive,
/// which every model then resolved exactly, so the tie this is meant to
/// measure never arose and the diff was a confident zero. The references that
/// matter are the ones naming a file that is *not* there -- an artist's
/// absolute path into a Dropbox folder, or another pack's atlas.
///
/// Run with:
///   ATLAS_BENCH=1 ATLAS_CATALOG_DB=`copy of the db` \
///   ATLAS_RELINK_DUMP=`path to write` \
///     flutter test test/relink_blast_radius_test.dart
void main() {
  final dbPath = Platform.environment['ATLAS_CATALOG_DB'];
  final dumpPath = Platform.environment['ATLAS_RELINK_DUMP'];
  final enabled = Platform.environment['ATLAS_BENCH'] == '1' &&
      dbPath != null &&
      dumpPath != null;

  test('resolve the references the materials really name', () async {
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

    final perArchive = <String, List<AssetItem>>{};
    for (final asset in catalog) {
      if (asset.ext != 'fbx') continue;
      final zip = parseZipVirtualPath(asset.path);
      if (zip == null) continue;
      (perArchive[zip.zipPath] ??= <AssetItem>[]).add(asset);
    }

    final helper = meshImporterPath();
    final archives = perArchive.keys.toList()..sort();
    final lines = <String>[];
    var modelsRead = 0;
    var referencesSeen = 0;
    var verbatim = 0;

    for (final archive in archives) {
      final models = perArchive[archive]!
        ..sort((a, b) => a.path.compareTo(b.path));
      // Four per archive: enough to catch a pack's material conventions,
      // across all 341 archives rather than deeply into a few.
      for (final model in models.take(4)) {
        List<dynamic> materials;
        try {
          final bytes = await readZipVirtualAssetBytesByPath(model.path);
          if (bytes == null || bytes.isEmpty) continue;
          final result = await runMeshImporter(
            helper,
            model.path,
            inputBytes: bytes,
          );
          if (result.exitCode != 0) continue;
          final parsed = jsonDecode(result.stdout) as Map<String, dynamic>;
          materials = (parsed['materials'] as List<dynamic>?) ?? const [];
        } catch (_) {
          continue;
        }
        modelsRead += 1;
        for (final entry in materials) {
          final material = entry as Map<String, dynamic>;
          final references = <String>[
            ...((material['textures'] as List<dynamic>?) ?? const [])
                .cast<String>(),
            ((material['normalTexture'] as String?) ?? ''),
            ((material['emissiveTexture'] as String?) ?? ''),
          ].where((reference) => reference.trim().isNotEmpty).toSet().toList();
          for (final reference in references) {
            referencesSeen += 1;
            final answer = findDeterministicTextureRelink(
              model.path,
              reference,
              catalog,
            );
            lines.add('${model.path}|$reference|${answer ?? ""}');
          }
        }
      }
    }

    // How many of these were an exact hit anyway, which the scoring change
    // cannot move. A sweep where that is all of them measures nothing.
    for (final line in lines) {
      final parts = line.split('|');
      if (parts.length < 3 || parts[2].isEmpty) continue;
      final asked = parts[1].split(RegExp(r'[\\/]')).last.toLowerCase();
      final got = parts[2].split(RegExp(r'[\\/]')).last.toLowerCase();
      if (asked == got) verbatim += 1;
    }

    final dump = File(dumpPath!);
    await dump.writeAsString('${lines.join("\n")}\n');
    stdout.writeln('');
    stdout.writeln('  archives           ${archives.length}');
    stdout.writeln('  models read        $modelsRead');
    stdout.writeln('  references         $referencesSeen');
    stdout.writeln('  resolved           '
        '${lines.where((line) => !line.endsWith("|")).length}');
    stdout.writeln('  of those, exact    $verbatim  '
        '(a scoring change cannot move these)');
    stdout.writeln('  written to         ${dump.path}');
    expect(referencesSeen, greaterThan(500),
        reason: 'too small a sweep to measure anything with');
    expect(verbatim, lessThan(referencesSeen),
        reason: 'if every reference is an exact hit, this sweep cannot see a '
            'scoring change at all -- which is how the first version of it '
            'reported a confident zero');
  }, skip: enabled ? null : 'set ATLAS_BENCH=1, ATLAS_CATALOG_DB, ATLAS_RELINK_DUMP', timeout: const Timeout(Duration(minutes: 60)));
}
