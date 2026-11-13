import 'dart:convert';
import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cube with a material that names a texture nothing will resolve.
const _cube = '''
mtllib crate.mtl
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
usemtl Crate_Wood
f 1 2 3
f 1 3 4
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
''';

AssetItem _asset(
  String path, {
  String type = 'model',
  String source = r'C:\library',
  String pack = 'CityPack',
}) {
  final name = path.split(Platform.pathSeparator).last;
  return AssetItem(
    id: 'test:$path',
    name: name,
    path: path,
    relativePath: name,
    sourceRoot: source,
    sourceName: pack,
    ext: name.contains('.') ? name.split('.').last.toLowerCase() : '',
    type: type,
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

/// Reads a bridge route the way the MCP client does.
Future<({int status, Map<String, Object?> body})> _ask(
  String route, {
  required int port,
  String? token,
  Map<String, Object?>? payload,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      payload == null ? 'GET' : 'POST',
      Uri.parse('http://127.0.0.1:$port$route'),
    );
    if (token != null) request.headers.set(atlasBridgeTokenHeader, token);
    if (payload != null) request.write(jsonEncode(payload));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      body: body.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(body) as Map<String, Object?>,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('bridgeFindAsset', () {
    final assets = [
      _asset(r'C:\library\CityPack\SM_Door_01.fbx'),
      _asset(r'C:\library\OfficePack\SM_Door_01.fbx'),
      _asset(r'C:\library\CityPack\SM_Wall_01.fbx'),
    ];

    test('finds an asset by its full path', () {
      final found = bridgeFindAsset(r'C:\library\CityPack\SM_Door_01.fbx', assets);
      expect(found.path, r'C:\library\CityPack\SM_Door_01.fbx');
    });

    test('finds an asset by a path ending', () {
      expect(
        bridgeFindAsset(r'OfficePack\SM_Door_01.fbx', assets).sourceRoot,
        r'C:\library',
      );
    });

    test('finds an asset by a name only one file has', () {
      expect(bridgeFindAsset('SM_Wall_01.fbx', assets).name, 'SM_Wall_01.fbx');
    });

    test('refuses to guess between two files of the same name', () {
      // Picking the first of these would answer confidently about the wrong
      // pack, and the caller would have no way to tell.
      expect(
        () => bridgeFindAsset('SM_Door_01.fbx', assets),
        throwsA(
          isA<BridgeRequestException>().having(
            (e) => e.message,
            'message',
            allOf(contains('matches 2 assets'), contains('OfficePack')),
          ),
        ),
      );
    });

    test('says so when nothing matches', () {
      expect(
        () => bridgeFindAsset('SM_Nothing.fbx', assets),
        throwsA(isA<BridgeRequestException>()),
      );
    });

    test('says the catalog is not loaded rather than that nothing matches', () {
      expect(
        () => bridgeFindAsset('SM_Door_01.fbx', const []),
        throwsA(
          isA<BridgeRequestException>().having(
            (e) => e.message,
            'message',
            contains('no catalog loaded'),
          ),
        ),
      );
    });
  });

  group('the bridge server', () {
    late Directory temp;
    late int port;
    late String token;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('atlas-bridge-test');
      await AtlasBridge.instance.start(descriptorDirectory: temp);
      final descriptor =
          File('${temp.path}${Platform.pathSeparator}$atlasBridgeFileName');
      final json = jsonDecode(descriptor.readAsStringSync()) as Map<String, Object?>;
      port = json['port'] as int;
      token = json['token'] as String;
    });

    tearDown(() async {
      await AtlasBridge.instance.stop();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('writes a descriptor the client can find it by', () {
      expect(port, greaterThan(0));
      expect(token, hasLength(48), reason: '24 random bytes as hex');
    });

    test('answers health with the running version', () async {
      final answer = await _ask('/health', port: port, token: token);
      expect(answer.status, 200);
      expect(answer.body['version'], appVersion);
    });

    test('refuses a request with no token', () async {
      // Any process on this machine can reach a listening socket, and this
      // one reads and rasterises files on request.
      final answer = await _ask('/health', port: port);
      expect(answer.status, 403);
    });

    test('refuses a request with the wrong token', () async {
      final answer = await _ask('/health', port: port, token: 'nope');
      expect(answer.status, 403);
    });

    test('a route it does not have is a 404, not a crash', () async {
      final answer = await _ask('/nonsense', port: port, token: token);
      expect(answer.status, 404);
    });

    test('a bad request is a sentence, not a stack trace', () async {
      final answer = await _ask(
        '/inspect',
        port: port,
        token: token,
        payload: {'path': 'nothing_by_this_name.fbx'},
      );
      expect(answer.status, 400);
      expect(answer.body['error'], isA<String>());
      expect(answer.body['error'], isNot(contains('#0')));
    });

    test('stopping takes the descriptor away with it', () async {
      final descriptor =
          File('${temp.path}${Platform.pathSeparator}$atlasBridgeFileName');
      expect(descriptor.existsSync(), isTrue);
      await AtlasBridge.instance.stop();
      expect(
        descriptor.existsSync(),
        isFalse,
        reason: 'a descriptor left behind points the client at a dead port',
      );
    });
  });

  group('inspect', () {
    late Directory temp;
    late AssetItem cube;
    late List<AssetItem> assets;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('atlas-inspect-test');
      final path = '${temp.path}${Platform.pathSeparator}SM_Crate_01.obj';
      File(path).writeAsStringSync(_cube);
      cube = _asset(path);
      assets = [cube];
    });

    tearDown(() {
      // Nothing here opens an archive, but a zip left open would block this.
      closeCachedArchives();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('reads the geometry and calls it one model', () async {
      final report = await bridgeInspect({'path': cube.path}, assets);
      expect(report['shape'], 'model');
      expect(report['faces'], 6);
      expect(report['vertices'], greaterThan(0));
    });

    test('reports the material and that its texture did not resolve', () async {
      final report = await bridgeInspect({'path': cube.path}, assets);
      final materials = report['materials'] as List<Object?>;
      expect(materials, hasLength(1));
      expect(
        (materials.single as Map<String, Object?>)['name'],
        'Crate_Wood',
      );
      expect(report['texturesResolved'], 0);
    });

    test('warns that an OBJ carries no units', () async {
      // The trap this exists for: these packs ship an OBJ in centimetres
      // beside an FBX in metres, with nothing in the OBJ to say so.
      final report = await bridgeInspect({'path': cube.path}, assets);
      final warnings = (report['warnings'] as List<Object?>).join(' ');
      expect(warnings, contains('no units'));
    });

    test('refuses a file that is not a model', () async {
      final texture = _asset(
        r'C:\library\CityPack\T_Crate.png',
        type: 'image',
      );
      expect(
        () => bridgeInspect({'path': texture.path}, [texture]),
        throwsA(isA<BridgeRequestException>()),
      );
    });

    test('every number it reports survives being turned into JSON', () async {
      // An empty mesh has infinite bounds and a rig with nothing in common
      // scores an infinite difference. Neither is JSON, and encoding one
      // throws rather than producing a wrong answer.
      final report = await bridgeInspect({'path': cube.path}, assets);
      expect(() => jsonEncode(report), returnsNormally);
    });
  });

  group('render', () {
    late Directory temp;
    late AssetItem cube;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('atlas-render-test');
      final path = '${temp.path}${Platform.pathSeparator}SM_Crate_01.obj';
      File(path).writeAsStringSync(_cube);
      cube = _asset(path);
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('hands back a PNG of the size asked for', () async {
      final answer = await bridgeRender({'path': cube.path, 'size': 128}, [cube]);
      expect(answer['width'], 128);
      expect(answer['height'], 128);
      final png = base64Decode(answer['png'] as String);
      expect(
        png.sublist(0, 8),
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        reason: 'the PNG signature',
      );
    });

    test('draws the faces it was given', () async {
      final answer = await bridgeRender({'path': cube.path, 'size': 64}, [cube]);
      expect(answer['totalFaces'], 6);
      expect(
        answer['drawnFaces'],
        lessThan(6),
        reason: 'a closed cube has its back half culled',
      );
      expect(
        answer['capped'],
        isFalse,
        reason: 'culling the back half is not the face limit being hit',
      );
    });

    test('refuses a size that would cost more than it is worth', () async {
      expect(
        () => bridgeRender({'path': cube.path, 'size': 8192}, [cube]),
        throwsA(isA<BridgeRequestException>()),
      );
    });
  });
}
