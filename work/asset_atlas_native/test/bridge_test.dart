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

  /// The exact lookup used to be a walk of the whole catalog, normalizing
  /// every path on the way past, and it ran on every MCP call that names an
  /// asset. These hold the index to the walk's answer rather than to its
  /// implementation, which is why the walk is still there to compare against.
  group('bridgeFindAsset answers the same way indexed as it did by scan', () {
    List<AssetItem> catalogWith(List<AssetItem> extra) => [
      _asset(r'C:\library\CityPack\SM_Door_01.fbx'),
      _asset(r'C:\library\OfficePack\SM_Door_01.fbx'),
      _asset(r'C:\library\CityPack\SM_Wall_01.fbx'),
      ...extra,
    ];

    void bothAgree(String needle, List<AssetItem> assets) {
      final scanned = bridgeFindAsset(needle, assets, byScan: true);
      final indexed = bridgeFindAsset(needle, assets);
      expect(
        indexed.path,
        scanned.path,
        reason: 'the index answered $needle differently from the walk',
      );
      expect(indexed.id, scanned.id);
    }

    test('on a full path', () {
      bothAgree(r'C:\library\CityPack\SM_Door_01.fbx', catalogWith(const []));
    });

    test('on a path spelled with the other separator', () {
      bothAgree('C:/library/CityPack/SM_Door_01.fbx', catalogWith(const []));
    });

    test('on a path in the wrong case', () {
      bothAgree(r'c:\LIBRARY\citypack\sm_door_01.FBX', catalogWith(const []));
    });

    test('on an asset id', () {
      bothAgree(
        r'test:C:\library\CityPack\SM_Wall_01.fbx',
        catalogWith(const []),
      );
    });

    test('on a path ending, which neither indexes', () {
      bothAgree(r'OfficePack\SM_Door_01.fbx', catalogWith(const []));
    });

    test('on a bare name only one file has', () {
      bothAgree('SM_Wall_01.fbx', catalogWith(const []));
    });

    test('when two assets share a path, the earlier one wins both ways', () {
      // The catalog can hold the same path twice -- a rescan mid-flight, or
      // nested source roots -- and the walk returned the first.
      final twice = catalogWith([
        _asset(r'C:\library\CityPack\SM_Door_01.fbx', pack: 'Duplicate'),
      ]);
      bothAgree(r'C:\library\CityPack\SM_Door_01.fbx', twice);
      expect(
        bridgeFindAsset(
          r'C:\library\CityPack\SM_Door_01.fbx',
          twice,
        ).sourceName,
        'CityPack',
      );
    });

    test('an id that is also another asset\'s path takes the earlier', () {
      // The case the position in the index exists for. The walk checked the
      // path before the id *within* one asset, but returned the first asset
      // matching either way -- so an id on an earlier asset beats a path on
      // a later one, and two separate maps would have got this backwards.
      final collides = [
        _asset(r'C:\library\CityPack\SM_Odd_01.fbx', pack: 'First'),
        _asset(r'C:\library\CityPack\SM_Other_01.fbx', pack: 'Second'),
      ];
      // The first asset's id is literally the second asset's path.
      final shadowing = [
        AssetItem(
          id: r'C:\library\CityPack\SM_Other_01.fbx',
          name: 'SM_Odd_01.fbx',
          path: r'C:\library\CityPack\SM_Odd_01.fbx',
          relativePath: 'SM_Odd_01.fbx',
          sourceRoot: r'C:\library',
          sourceName: 'First',
          ext: 'fbx',
          type: 'model',
          size: 1,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          tags: const [],
        ),
        collides[1],
      ];
      bothAgree(r'C:\library\CityPack\SM_Other_01.fbx', shadowing);
      expect(
        bridgeFindAsset(
          r'C:\library\CityPack\SM_Other_01.fbx',
          shadowing,
        ).sourceName,
        'First',
      );
    });

    test('both refuse to choose between two files of the same name', () {
      for (final byScan in [true, false]) {
        expect(
          () => bridgeFindAsset(
            'SM_Door_01.fbx',
            catalogWith(const []),
            byScan: byScan,
          ),
          throwsA(isA<BridgeRequestException>()),
          reason: 'byScan: $byScan',
        );
      }
    });

    test('the index notices the catalog being replaced', () {
      // It is cached on the identity of the list it was built from, so a
      // rescan that hands over a new list must not be answered out of the
      // old one.
      final before = catalogWith(const []);
      expect(bridgeFindAsset('SM_Wall_01.fbx', before).sourceName, 'CityPack');
      final after = [
        _asset(r'C:\library\NewPack\SM_Wall_01.fbx', pack: 'NewPack'),
      ];
      expect(bridgeFindAsset('SM_Wall_01.fbx', after).sourceName, 'NewPack');
      expect(
        () => bridgeFindAsset(r'C:\library\CityPack\SM_Door_01.fbx', after),
        throwsA(isA<BridgeRequestException>()),
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
