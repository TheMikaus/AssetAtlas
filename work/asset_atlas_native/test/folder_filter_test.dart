// Narrowing the folder tree by name.
import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FolderNode _tree() {
  final synty = FolderNode(name: 'Synty', path: 'Synty');
  final empire = FolderNode(name: 'POLYGON_AncientEmpire', path: 'Synty/POLYGON_AncientEmpire');
  final farm = FolderNode(name: 'POLYGON_Farm', path: 'Synty/POLYGON_Farm');
  final chars = FolderNode(name: 'Characters', path: 'Synty/POLYGON_AncientEmpire/Characters');
  empire.childrenByName['Characters'] = chars;
  synty.childrenByName['POLYGON_AncientEmpire'] = empire;
  synty.childrenByName['POLYGON_Farm'] = farm;
  return synty;
}

void main() {
  test('a folder matches through its descendants', () {
    expect(folderTreeMatches(_tree(), 'characters'), isTrue);
    expect(folderTreeMatches(_tree(), 'farm'), isTrue);
    expect(folderTreeMatches(_tree(), 'zombie'), isFalse);
    expect(folderTreeMatches(_tree(), ''), isTrue);
  });

  testWidgets('the tree shows only the path to a match, held open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FolderTreeView(
              roots: [_tree()],
              selectedFolder: null,
              expandedFolders: const {},
              onSelect: (_) {},
              onToggleExpanded: (_) {},
              filter: 'characters',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Characters'), findsOneWidget);
    expect(find.text('POLYGON_AncientEmpire'), findsOneWidget);
    expect(find.text('POLYGON_Farm'), findsNothing);
  });

  testWidgets('no match says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FolderTreeView(
            roots: [_tree()],
            selectedFolder: null,
            expandedFolders: const {},
            onSelect: (_) {},
            onToggleExpanded: (_) {},
            filter: 'zombie',
          ),
        ),
      ),
    );
    expect(find.textContaining('No folder'), findsOneWidget);
  });
}
