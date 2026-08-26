import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probe an animation-only fbx', () async {
    const zip =
        r'K:\Misc Downloads To Keep\Assets for Creation\Synty\ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
    const entry =
        'SourceFiles/Animations/Polygon/Feminine/Idle/A_Idle_Standing_Femn.fbx';
    final virtual = buildZipVirtualPath(zip, entry);
    final bytes = await readZipVirtualAssetBytesByPath(virtual);
    // ignore: avoid_print
    print('PROBE bytes=${bytes?.length}');

    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    ).absolute.path;
    final sw = Stopwatch()..start();
    final result = await runMeshImporter(
      helper,
      virtual,
      inputBytes: bytes,
    );
    sw.stop();
    // ignore: avoid_print
    print('PROBE exit=${result.exitCode} in ${sw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print('PROBE stderr=${result.stderr.trim()}');
    if (result.exitCode == 0) {
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      // ignore: avoid_print
      print('PROBE kind=${json['kind']} stacks=${json['animationStacks']} '
          'bones=${json['bones']} duration=${json['durationSeconds']} '
          'names=${json['animationNames']}');
    }
  });
}
