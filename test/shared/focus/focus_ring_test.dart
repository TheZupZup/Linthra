import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/shared/focus/focus_ring.dart';

/// The focus ring is what makes "where is the keyboard" answerable at a glance
/// (#390), and it has exactly one rule that keeps mobile out of it: it is drawn
/// for the input mode, not for the platform. Touch never shows one; a keyboard
/// always does, on Linux and on an Android tablet with a keyboard case alike.

BoxDecoration? _ring(WidgetTester tester) {
  final Finder drawn = find.byKey(focusRingKey);
  if (drawn.evaluate().isEmpty) return null;
  return tester.widget<DecoratedBox>(drawn.first).decoration as BoxDecoration;
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(BrandPalettes.classic),
      home: Scaffold(
        body: Column(
          children: <Widget>[
            FocusRing(
              child: ListTile(title: const Text('row'), onTap: () {}),
            ),
            TextButton(onPressed: () {}, child: const Text('after')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a keyboard-driven focus draws the ring', (tester) async {
    await _pump(tester);
    expect(_ring(tester), isNull, reason: 'nothing is focused yet');

    // Tab is what puts the focus manager into keyboard mode in the first place.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final BoxDecoration? ring = _ring(tester);
    expect(ring, isNotNull);
    expect(
      (ring!.border! as Border).top.color,
      AppTheme.dark(BrandPalettes.classic).colorScheme.secondary,
      reason: 'focus speaks with the accent, not with hover neutral or the '
          'identity tint selection uses',
    );
    expect((ring.border! as Border).top.width, focusRingWidth);
  });

  testWidgets('moving on takes the ring with it', (tester) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_ring(tester), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(find.text('after'), findsOneWidget);
    expect(_ring(tester), isNull);
  });

  testWidgets('a touch never draws one', (tester) async {
    await _pump(tester);
    // What a phone does: the app is driven by taps, so the focus manager stays
    // in touch mode and a tap that happens to focus a row must not light it up.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });
    await tester.pump();

    await tester.tap(find.text('row'));
    await tester.pumpAndSettle();

    expect(_ring(tester), isNull);
  });

  testWidgets('the ring is not a stop of its own', (tester) async {
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    final FocusNode? first = FocusManager.instance.primaryFocus;

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final FocusNode? second = FocusManager.instance.primaryFocus;

    // Two stops for two controls: the wrapper never inserts a third.
    expect(first, isNot(second));
    expect(
      second?.context?.findAncestorWidgetOfExactType<TextButton>(),
      isNotNull,
    );
  });
}
