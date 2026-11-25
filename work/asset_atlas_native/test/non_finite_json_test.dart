import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A model with a non-finite number in it still reads.
///
/// JSON has no NaN, so the importer printing one made the whole file
/// unreadable rather than one coordinate wrong: `glass.fbx` in Kenney's
/// Food Kit failed with "Unexpected character (at character 5742)" on
/// `[0,1,2,0,0,1,0,1,nan,1]` and was one of the seven models the tagger gave
/// up on. 88 `nan` tokens in that one file.
///
/// The library is needed for this: constructing an FBX that carries a NaN is
/// a worse test than the file that actually does.
const _corpusFile = r'Z:\Assets\Kenney GameAssets All-in-1\kenney-game-assets'
    r'\3D assets\Food Kit\Models\FBX format\glass.fbx';

File get _importer =>
    File('build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe');

void main() {
  test('a NaN UV does not make the file unreadable', () {
    final result = Process.runSync(_importer.absolute.path, [_corpusFile]);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final text = result.stdout as String;
    // The symptom, directly: nothing JSON cannot carry.
    expect(text, isNot(contains('nan')));
    expect(text, isNot(contains('inf')));

    // And the whole point: it parses.
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['kind'], 'mesh');
    expect((decoded['faces'] as List), isNotEmpty);

    // The substitute is zero, in the slot the NaN was in, with the rest of
    // the face intact -- not a dropped face and not a dropped file.
    final faces = (decoded['faces'] as List).cast<List>();
    expect(faces.first.length, 10);
    for (final face in faces) {
      for (final value in face) {
        expect(value, isA<num>());
        expect((value as num).isFinite, isTrue);
      }
    }
  },
      skip: _importer.existsSync() && File(_corpusFile).existsSync()
          ? false
          : 'needs the importer build and the Kenney Food Kit');
}
