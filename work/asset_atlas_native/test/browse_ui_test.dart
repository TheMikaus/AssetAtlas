import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AssetItem _asset({
  required String relativePath,
  String type = 'image',
  int size = 100,
  int modifiedMs = 1000,
  String? modelKind,
  bool ignored = false,
}) {
  final name = relativePath.split('/').last;
  final asset = AssetItem(
    id: relativePath,
    name: name,
    path: r'C:\Packs\' + relativePath.replaceAll('/', r'\'),
    relativePath: relativePath,
    sourceRoot: r'C:\Packs',
    sourceName: 'Packs',
    ext: name.contains('.') ? name.split('.').last : '',
    type: type,
    size: size,
    modified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
    tags: const [],
    ignored: ignored,
  );
  asset.modelKind = modelKind;
  return asset;
}

void main() {
  setUp(() {
    // These tests are about layout, not about importing models.
    ModelThumbnailCache.enabled = false;
  });
  tearDown(() => ModelThumbnailCache.enabled = true);

  group('sortAssets', () {
    final assets = [
      _asset(relativePath: 'Pack/b.png', size: 300, modifiedMs: 3000),
      _asset(relativePath: 'Pack/a.png', size: 100, modifiedMs: 1000),
      _asset(relativePath: 'Pack/c.png', size: 200, modifiedMs: 2000),
    ];

    test('by path is the default order', () {
      expect(
        sortAssets(assets, AssetSortMode.path).map((a) => a.name),
        ['a.png', 'b.png', 'c.png'],
      );
    });

    test('by size puts the biggest first', () {
      expect(
        sortAssets(assets, AssetSortMode.size).map((a) => a.name),
        ['b.png', 'c.png', 'a.png'],
      );
    });

    test('by modified puts the newest first', () {
      expect(
        sortAssets(assets, AssetSortMode.modified).map((a) => a.name),
        ['b.png', 'c.png', 'a.png'],
      );
    });

    test('does not mutate the input list', () {
      final input = [...assets];
      sortAssets(input, AssetSortMode.size);
      expect(input.map((a) => a.name), assets.map((a) => a.name));
    });

    test('ties fall back to path, so the order is stable', () {
      final tied = [
        _asset(relativePath: 'Pack/z.png', size: 100),
        _asset(relativePath: 'Pack/a.png', size: 100),
        _asset(relativePath: 'Pack/m.png', size: 100),
      ];
      final first = sortAssets(tied, AssetSortMode.size).map((a) => a.name);
      final second = sortAssets(
        tied.reversed.toList(),
        AssetSortMode.size,
      ).map((a) => a.name);
      expect(first, second);
      expect(first, ['a.png', 'm.png', 'z.png']);
    });
  });

  group('buildFolderTree', () {
    final assets = [
      _asset(relativePath: 'Packs/Airport/FBX/tower.fbx'),
      _asset(relativePath: 'Packs/Airport/FBX/hangar.fbx'),
      _asset(relativePath: 'Packs/Airport/Textures/atlas.png'),
      _asset(relativePath: 'Packs/City/FBX/road.fbx'),
      _asset(relativePath: 'loose.png'),
    ];

    test('nests folders and counts everything beneath them', () {
      final roots = buildFolderTree(assets);
      expect(roots.map((node) => node.name), ['Packs']);

      final packs = roots.single;
      expect(packs.assetCount, 4, reason: 'the loose file has no folder');

      final children = packs.sortedChildren;
      expect(children.map((node) => node.name), ['Airport', 'City']);

      final airport = children.first;
      expect(airport.assetCount, 3);
      expect(airport.path, 'Packs/Airport');
      expect(
        airport.sortedChildren.map((node) => node.name),
        ['FBX', 'Textures'],
      );
      expect(airport.sortedChildren.first.assetCount, 2);
    });

    test('a file at the root contributes no folder', () {
      expect(buildFolderTree([_asset(relativePath: 'loose.png')]), isEmpty);
    });
  });

  group('isUnderFolder', () {
    test('matches the folder itself and everything below', () {
      expect(isUnderFolder('Packs/Airport/FBX/a.fbx', 'Packs/Airport'), isTrue);
      expect(isUnderFolder('Packs/Airport/FBX/a.fbx', 'Packs'), isTrue);
    });

    test('does not match a sibling with a shared prefix', () {
      expect(
        isUnderFolder('Packs/AirportOld/a.fbx', 'Packs/Airport'),
        isFalse,
        reason: 'prefix matching must respect folder boundaries',
      );
    });

    test('an empty filter matches everything', () {
      expect(isUnderFolder('anything/at/all.png', ''), isTrue);
    });
  });

  group('SearchAndSummary', () {
    Widget host(TextEditingController controller, int visibleCount) {
      return MaterialApp(
        home: Scaffold(
          body: SearchAndSummary(
            controller: controller,
            visibleCount: visibleCount,
            totalCount: 40,
            selectedCount: 0,
            sortMode: AssetSortMode.path,
            gridMode: false,
            onChanged: (_) {},
            onSortChanged: (_) {},
            onGridModeChanged: (_) {},
            onSelectAllVisible: () {},
            onClearSelection: () {},
          ),
        ),
      );
    }

    testWidgets('an empty list under an active query says so', (tester) async {
      final controller = TextEditingController(text: 'door');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(controller, 0));
      await tester.pump();

      expect(
        find.textContaining('Still searching for "door"'),
        findsOneWidget,
      );
      expect(find.text('Clear search'), findsOneWidget);
    });

    testWidgets('Clear search empties the box and reports it', (tester) async {
      final controller = TextEditingController(text: 'door');
      addTearDown(controller.dispose);
      var reported = 'not called';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchAndSummary(
              controller: controller,
              visibleCount: 0,
              totalCount: 40,
              selectedCount: 0,
              sortMode: AssetSortMode.path,
              gridMode: false,
              onChanged: (value) => reported = value,
              onSortChanged: (_) {},
              onGridModeChanged: (_) {},
              onSelectAllVisible: () {},
              onClearSelection: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Clear search'));
      expect(controller.text, isEmpty);
      expect(reported, '');
    });

    testWidgets('an empty list with no query stays quiet', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(controller, 0));
      await tester.pump();

      expect(find.textContaining('Still searching'), findsNothing);
      expect(find.text('Clear search'), findsNothing);
    });

    testWidgets('a list with results stays quiet too', (tester) async {
      final controller = TextEditingController(text: 'door');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(controller, 7));
      await tester.pump();

      expect(find.textContaining('Still searching'), findsNothing);
    });
  });

  group('the type filter and the search box are independent', () {
    Finder searchField() {
      return find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            (widget.decoration?.hintText ?? '').startsWith('Search'),
      );
    }

    testWidgets('changing the type keeps what was typed', (tester) async {
      await tester.pumpWidget(const AssetAtlasApp(enablePersistence: false));
      await tester.pumpAndSettle();

      await tester.enterText(searchField(), 'door');
      // The query is debounced by 120ms.
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<TextField>(searchField()).controller?.text, 'door');

      await tester.scrollUntilVisible(
        find.textContaining('MODEL ('),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.textContaining('MODEL ('));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.widget<TextField>(searchField()).controller?.text, 'door');
    });
  });

  group('AssetGrid', () {
    testWidgets('renders a tile per asset with a type icon fallback', (
      tester,
    ) async {
      final assets = [
        _asset(relativePath: 'Packs/a.wav', type: 'audio'),
        _asset(relativePath: 'Packs/b.fbx', type: 'model'),
        _asset(
          relativePath: 'Packs/c.fbx',
          type: 'model',
          modelKind: 'animation',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssetGrid(
              assets: assets,
              active: assets.first,
              selectedIds: const {},
              onActivate: (_) {},
              onSelect: (_, _, {bool range = false}) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AssetGridTile), findsNWidgets(3));
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      expect(find.byIcon(Icons.view_in_ar_outlined), findsOneWidget);
      // The animation clip must not look like a mesh.
      expect(find.byIcon(Icons.directions_run), findsOneWidget);
    });

    testWidgets('tapping a tile activates, ticking its box selects', (
      tester,
    ) async {
      AssetItem? activated;
      AssetItem? selected;
      final assets = [_asset(relativePath: 'Packs/a.png')];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssetGrid(
              assets: assets,
              active: null,
              selectedIds: const {},
              onActivate: (asset) => activated = asset,
              onSelect: (asset, value, {bool range = false}) =>
                  selected = asset,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(Checkbox));
      expect(selected, isNotNull);

      await tester.tap(find.text('a.png'));
      expect(activated, isNotNull);
    });
  });

  group('AssetList', () {
    testWidgets('select and ignore are visually distinct controls', (
      tester,
    ) async {
      final assets = [_asset(relativePath: 'Packs/a.png')];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssetList(
              assets: assets,
              active: null,
              selectedIds: const {},
              onActivate: (_) {},
              onSelect: (_, _, {bool range = false}) {},
              onIgnoredChanged: (_, _) {},
            ),
          ),
        ),
      );

      // One checkbox (select) plus an eye toggle (ignore), rather than two
      // unlabelled checkboxes.
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });

    testWidgets('an ignored asset reads as ignored', (tester) async {
      final assets = [_asset(relativePath: 'Packs/a.png', ignored: true)];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssetList(
              assets: assets,
              active: null,
              selectedIds: const {},
              onActivate: (_) {},
              onSelect: (_, _, {bool range = false}) {},
              onIgnoredChanged: (_, _) {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
      final label = tester.widget<Text>(find.text('a.png'));
      expect(label.style?.decoration, TextDecoration.lineThrough);
    });
  });
}
