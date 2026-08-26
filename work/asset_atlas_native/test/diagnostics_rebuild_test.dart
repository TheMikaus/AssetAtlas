import 'dart:io';

import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _fbxAsset(String path, {String id = 'asset-a'}) {
  final name = path.split(Platform.pathSeparator).last;
  return AssetItem(
    id: id,
    name: name,
    path: path,
    relativePath: name,
    sourceRoot: File(path).parent.path,
    sourceName: 'fixtures',
    ext: 'fbx',
    type: 'model',
    size: 1,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    tags: const [],
  );
}

/// Rebuilds its child on demand without changing anything the child depends on.
class _Rebuilder extends StatefulWidget {
  const _Rebuilder({required this.builder, super.key});

  final Widget Function(int tick) builder;

  @override
  State<_Rebuilder> createState() => _RebuilderState();
}

class _RebuilderState extends State<_Rebuilder> {
  int tick = 0;

  void bump() => setState(() => tick += 1);

  @override
  Widget build(BuildContext context) => widget.builder(tick);
}

void main() {
  testWidgets('unrelated rebuilds do not re-run the FBX importer', (
    tester,
  ) async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    MeshLoadCache.clear();
    MeshLoadCache.importCount = 0;
    textureReferenceScanCount = 0;

    final asset = _fbxAsset(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
    );
    final key = GlobalKey<_RebuilderState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Rebuilder(
            key: key,
            builder: (tick) => ModelTextureDiagnostics(
              asset: asset,
              allAssets: [asset],
              catalogRevision: 0,
              onActivateAsset: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(MeshLoadCache.importCount, 1);
    expect(textureReferenceScanCount, 1);

    // Stand-in for typing in the search box, toggling a checkbox, dragging the
    // splitter: state changes that rebuild the panel but change nothing it
    // depends on. Each of these used to spawn an importer process.
    for (var i = 0; i < 5; i += 1) {
      key.currentState!.bump();
      await tester.pumpAndSettle();
    }

    expect(
      MeshLoadCache.importCount,
      1,
      reason: 'rebuilds must reuse the cached import',
    );
    expect(
      textureReferenceScanCount,
      1,
      reason:
          'the panel must hold its future in state, not rebuild it in build()',
    );
  });

  testWidgets('a catalog revision change does re-run the import', (
    tester,
  ) async {
    final helper = File(
      'build/windows/x64/runner/Release/asset_atlas_mesh_importer.exe',
    );
    if (!helper.existsSync()) {
      markTestSkipped('Build the Windows app before running native FBX tests.');
      return;
    }

    MeshLoadCache.clear();
    MeshLoadCache.importCount = 0;
    textureReferenceScanCount = 0;

    final asset = _fbxAsset(
      File('test/fixtures/fbx/transformed_uv_embedded.fbx').absolute.path,
    );

    Widget panelAt(int revision) => MaterialApp(
      home: Scaffold(
        body: ModelTextureDiagnostics(
          asset: asset,
          allAssets: [asset],
          catalogRevision: revision,
          onActivateAsset: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(panelAt(0));
    await tester.pumpAndSettle();
    expect(MeshLoadCache.importCount, 1);

    // A re-scan invalidates the cache, because relink depends on catalog
    // contents.
    MeshLoadCache.clear();
    await tester.pumpWidget(panelAt(1));
    await tester.pumpAndSettle();
    expect(MeshLoadCache.importCount, 2);
  });
}
