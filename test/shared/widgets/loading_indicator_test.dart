import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/loading_indicator.dart';

/// A loading screen that announces nothing is indistinguishable from an empty
/// one (#90). Flutter builds no semantics node for a progress indicator unless
/// it is given a label, which is exactly how Linthra's blocking spinners came
/// to be silent.

void main() {
  testWidgets('a bare progress indicator really is silent', (tester) async {
    // The behaviour this widget exists to fix, pinned so nobody "simplifies"
    // it back to a plain CircularProgressIndicator.
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );

    expect(find.bySemanticsLabel('Loading'), findsNothing);
    handle.dispose();
  });

  testWidgets('the shared indicator names what is loading', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LoadingIndicator(label: 'Loading your library')),
      ),
    );

    expect(find.bySemanticsLabel('Loading your library'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('it still draws the ring a sighted user expects', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoadingIndicator())),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the default label is usable on its own', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoadingIndicator())),
    );

    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    handle.dispose();
  });
}
