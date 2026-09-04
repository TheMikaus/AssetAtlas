// A diagnostic, not an assertion: renders the chosen character posed by a clip
// and writes PNGs so the result can be looked at. Skips unless the Synty
// corpus and a Windows build are both present.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = r'K:\Misc Downloads To Keep\Assets for Creation\Synty';
const _pack = '$_root\\ANIMATION_Base_Locomotion_SourceFiles_v3.zip';
const _outDir =
    r'C:\Users\white\AppData\Local\Temp\claude\C--Users-white-Documents-Codex-2026-07-08\17de5ce3-eb0a-4df9-b9d3-32ac8607bca4\scratchpad';

Future<Map<String, dynamic>> _import(String entry) async {
  final bytes = File(_pack).readAsBytesSync();
  final zip = ZipDecoder().decodeBytes(bytes);
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

Future<void> _writePng(RasterResult raster, String name) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    raster.pixels,
    raster.width,
    raster.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$_outDir\\$name').writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render the posed character', () async {
    final characterJson = await _import(
      'SourceFiles/Character/PolygonSyntyCharacter.fbx',
    );
    final clipJson = await _import(
      'SourceFiles/Animations/Polygon/Feminine/Idle/A_Idle_Standing_Femn.fbx',
    );

    final character = await meshModelFromImporterJson(
      characterJson,
      modelPath: buildZipVirtualPath(
        _pack,
        'SourceFiles/Character/PolygonSyntyCharacter.fbx',
      ),
      name: 'PolygonSyntyCharacter.fbx',
    );
    final clip = SkeletonAnimation.fromJson(
      clipJson['skeleton'] as Map<String, dynamic>?,
    )!;

    // ignore: avoid_print
    print(
      'character: ${character.vertices.length} verts, '
      'skin ${character.skin != null}, '
      'materials ${character.materials.length}, '
      'textured ${character.materials.where((m) => m.texturePixels != null).length}, '
      'rest bones ${character.skeleton?.bones.length}',
    );
    for (final m in character.materials) {
      // ignore: avoid_print
      print('  material ${m.name}: ${materialSummaryLine(m)} '
          'textures=${m.textures} resolved=${m.resolvedTextures}');
    }
    // ignore: avoid_print
    print('clip: ${clip.bones.length} bones, ${clip.frameCount} frames');
    // ignore: avoid_print
    print('vertexColors kept: ${character.vertexColors.length} '
        '(vertices ${character.vertices.length})');
    final m0 = character.materials.first;
    // ignore: avoid_print
    print('base flat=${character.colorForMaterial(0, textured: false)} '
        'textured=${character.colorForMaterial(0, textured: true)} '
        'opacity=${character.opacityForMaterial(0)} '
        'color=${m0.color} textureColor=${m0.textureColor}');

    final missing = character.skin!.boneNames
        .where((n) => clip.indexOfBone(n) < 0)
        .toList();
    // ignore: avoid_print
    print('skin bones missing from clip: $missing');

    for (final frame in [0, clip.frameCount ~/ 3]) {
      final posed = character.withVertices(
        poseSkinnedVertices(
          character: character,
          clip: clip,
          frame: frame,
        ),
      );
      final ys = posed.vertices.map((v) => v.y).toList()..sort();
      // ignore: avoid_print
      print('frame $frame: y ${ys.first.toStringAsFixed(2)}'
          '..${ys.last.toStringAsFixed(2)}');
      await _writePng(
        rasterizeMesh(
          mesh: posed,
          yaw: 0,
          pitch: 0,
          zoom: 1,
          width: 360,
          height: 360,
          renderMode: RenderMode.textured,
          lightingMode: LightingMode.corner,
          cullBackFaces: false,
        ),
        'pose_$frame.png',
      );
    }

    await _writePng(
      rasterizeMesh(
        mesh: character,
        yaw: 0,
        pitch: 0,
        zoom: 1,
        width: 360,
        height: 360,
        renderMode: RenderMode.textured,
        lightingMode: LightingMode.corner,
        cullBackFaces: false,
      ),
      'pose_bind.png',
    );
  }, skip: !Directory(_root).existsSync());
}
