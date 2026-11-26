import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Reading what the embedding store already holds.
///
/// The strip claimed "visual tagging has not been started" over a store with
/// 138,747 vectors in it, every launch, because it only knew about runs in
/// its own process. This is the read that replaces the claim. It is a read:
/// `tagging.py` owns the store (DECISIONS.md EMB-001) and nothing here
/// writes to it or recomputes what counts as outstanding.
void main() {
  late Directory folder;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    folder = Directory.systemTemp.createTempSync('atlas-tagged-counts-');
  });

  tearDown(() {
    try {
      folder.deleteSync(recursive: true);
    } catch (_) {
      // Windows can hold the file open a moment longer; the temp directory
      // is not worth failing a test over.
    }
  });

  String indexPath() =>
      '${folder.path}${Platform.pathSeparator}embeddings_index.sqlite';

  Future<void> writeIndex(Map<String, int> rowsBySource) async {
    final database = await databaseFactory.openDatabase(indexPath());
    await database.execute(
      'create table embedding_index ('
      'asset_id text primary key, row integer, source text, '
      'computed_ms integer)',
    );
    var written = 0;
    for (final entry in rowsBySource.entries) {
      for (var index = 0; index < entry.value; index += 1) {
        written += 1;
        await database.insert('embedding_index', {
          'asset_id': 'asset-$written',
          'row': written,
          'source': entry.key,
          'computed_ms': 0,
        });
      }
    }
    await database.close();
  }

  test('it reports models and textures separately', () async {
    // The two things a run embeds: a render of the model's geometry, and a
    // texture the model references. Lumping them would overstate how much of
    // the library can be found by looking like something.
    await writeIndex({'render': 4, 'image': 7});
    final counts = await readTaggedCounts(folder.path);
    expect(counts?.models, 4);
    expect(counts?.textures, 7);
    expect(counts?.any, isTrue);
  });

  test('a source it does not know is counted as a model', () async {
    // Anything that is not an image is a render of something; a source added
    // later should read high rather than vanish.
    await writeIndex({'render': 2, 'geometry': 3});
    expect((await readTaggedCounts(folder.path))?.models, 5);
  });

  test('an empty store is empty, not absent', () async {
    await writeIndex(const {});
    final counts = await readTaggedCounts(folder.path);
    expect(counts, isNotNull);
    expect(counts!.any, isFalse);
  });

  test('no store at all reports nothing rather than zero', () async {
    // The difference matters to the strip: nothing read is not the same
    // claim as nothing tagged.
    expect(await readTaggedCounts(folder.path), isNull);
  });

  test('a store without the table reports nothing', () async {
    final database = await databaseFactory.openDatabase(indexPath());
    await database.execute('create table something_else (id integer)');
    await database.close();
    expect(await readTaggedCounts(folder.path), isNull);
  });

  test('no catalog directory yet reports nothing', () async {
    expect(await readTaggedCounts(null), isNull);
  });

  test('it leaves the store alone', () async {
    // Read-only by construction: one writer across two files is what makes
    // the store crash-safe, and it is not this one.
    await writeIndex({'render': 1});
    final before = File(indexPath()).lengthSync();
    await readTaggedCounts(folder.path);
    expect(File(indexPath()).lengthSync(), before);
    expect(
      Directory(folder.path).listSync().map((entry) => entry.path),
      [indexPath()],
    );
  });
}
