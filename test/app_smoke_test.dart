import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon/app/halcyon_app.dart';

void main() {
  testWidgets('App boots to the Library screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HalcyonApp()));
    await tester.pumpAndSettle();

    // The persistent shell and its bottom navigation render.
    expect(find.byType(NavigationBar), findsOneWidget);

    // The initial route is the Library tab. With no folder selected yet, the
    // empty state invites the user to choose one.
    expect(find.text('No music folder selected'), findsOneWidget);
  });
}
