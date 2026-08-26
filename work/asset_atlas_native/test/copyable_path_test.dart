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
          body: SizedBox(width: 200, child: CopyablePathText(path: _longPath)),
        ),
      ),
    );

    // The label itself is clipped at this width, so the whole path has to be
    // reachable some other way.
    final text = tester.widget<Text>(find.text(_longPath));
    expect(text.overflow, TextOverflow.ellipsis);

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
          body: SizedBox(width: 200, child: CopyablePathText(path: _longPath)),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pumpAndSettle();

    expect(copied, _longPath);
    expect(find.textContaining('Copied:'), findsOneWidget);
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
