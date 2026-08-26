import 'package:asset_atlas_native/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _longPath =
    r'K:\Misc Downloads To Keep\Assets for Creation\Synty\Simple_Airport_SourceFiles\SourceFiles\FBX\Airport_Building01.fbx';

void main() {
  testWidgets('a truncated path still exposes the full value on hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 340, child: CopyablePathText(path: _longPath)),
        ),
      ),
    );

    // The label is shortened to fit, so the whole path has to stay reachable
    // some other way: the tooltip carries it in full.
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .map((value) => value.replaceAll('​', ''))
        .firstWhere((value) => value.startsWith('...'));
    expect(rendered.length, lessThan(_longPath.length));
    // The file name is the part worth keeping.
    expect(rendered, endsWith('Airport_Building01.fbx'));

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip).first);
    expect(tooltip.message, _longPath);
  });

  testWidgets('the copy button puts the full path on the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 340, child: CopyablePathText(path: _longPath)),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pumpAndSettle();

    expect(copied, _longPath);
    expect(find.textContaining('Copied:'), findsOneWidget);
  });

  testWidgets('two paths differing only at the end stay distinguishable', (
    tester,
  ) async {
    const shared = r'K:\Misc Downloads To Keep\Assets for Creation\Synty';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: Column(
              children: [
                CopyablePathText(path: shared + r'\Airport', maxLines: 2),
                CopyablePathText(path: shared + r'\City', maxLines: 2),
              ],
            ),
          ),
        ),
      ),
    );

    // Assert on the string actually handed to Text, not on the widget's
    // original data: find.textContaining would match the full path either way
    // and prove nothing.
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        // Zero-width spaces are inserted so paths can wrap at separators.
        .map((value) => value.replaceAll('​', ''))
        .where((value) => value.startsWith('...'))
        .toList();

    expect(rendered, hasLength(2));
    for (final value in rendered) {
      expect(
        value.startsWith('...'),
        isTrue,
        reason: 'the head is what gets dropped',
      );
    }
    // The distinguishing tails survive.
    expect(rendered.where((v) => v.endsWith('Airport')), hasLength(1));
    expect(rendered.where((v) => v.endsWith('City')), hasLength(1));
  });

  testWidgets('a path that fits is left alone', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, child: CopyablePathText(path: 'C:/a.png')),
        ),
      ),
    );
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .map((value) => value.replaceAll('​', ''))
        .toList();
    expect(rendered, contains('C:/a.png'));
  });

  testWidgets('DetailRow renders path values as copyable', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DetailRow(label: 'Folder', value: _longPath, isPath: true),
              DetailRow(label: 'Size', value: '12 KB'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CopyablePathText), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });
}
