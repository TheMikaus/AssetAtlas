// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:asset_atlas_native/main.dart';

void main() {
  testWidgets('Asset Atlas shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const AssetAtlasApp(enablePersistence: false));
    await tester.pumpAndSettle();

    expect(find.text('Asset Atlas Native · v$appVersion'), findsOneWidget);
    expect(find.text('Scan folder'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Hide ZIP contents'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Hide ZIP contents'), findsOneWidget);
  });
}
