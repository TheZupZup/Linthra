import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/app/sonara_app.dart';

void main() {
  testWidgets('App boots to the Library screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SonaraApp()));
    await tester.pumpAndSettle();

    // The persistent shell and its bottom navigation render.
    expect(find.byType(NavigationBar), findsOneWidget);

    // The initial route is the Library tab, showing its empty state.
    expect(find.text('Your library is empty'), findsOneWidget);
  });
}
