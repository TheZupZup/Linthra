import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/onboarding/onboarding_screen.dart';

/// Onboarding is the first thing a new user meets, and for a TalkBack user it
/// was the first thing Linthra said twice (#90): each source card carried an
/// explicit "Title. Subtitle" label *and* the two Text widgets underneath, so
/// every card read its own name and description, then read both again.

Future<void> _pumpChooser(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const OnboardingScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Get started'));
  await tester.pumpAndSettle();
}

/// Every label in the tree, so a duplicate can be counted rather than guessed
/// at.
List<String> _labels(WidgetTester tester) {
  final List<String> found = <String>[];
  void walk(SemanticsNode node) {
    final String label = node.getSemanticsData().label;
    if (label.isNotEmpty) found.add(label);
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  // Walked from the app's own node rather than the binding's semantics
  // owner, which is deprecated.
  walk(tester.getSemantics(find.byType(MaterialApp)));
  return found;
}

void main() {
  testWidgets('a source card is one button, read once', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpChooser(tester);

    const String expected = 'Local music. A folder on this phone or an SD card';
    final List<String> labels = _labels(tester);

    expect(
      labels.where((String l) => l == expected).length,
      1,
      reason: 'the card should announce itself exactly once',
    );
    // The old shape: the same words again, off the Text widgets underneath.
    expect(
      labels.where((String l) => l.contains('A folder on this phone')).length,
      1,
      reason: 'no second node may repeat the description',
    );

    handle.dispose();
  });

  testWidgets('every source card reads once, not just the first',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpChooser(tester);

    final List<String> labels = _labels(tester);
    for (final String name in <String>[
      'Local music',
      'Jellyfin',
      'Navidrome / Subsonic',
      'Plex',
    ]) {
      expect(
        labels.where((String l) => l.startsWith('$name.')).length,
        1,
        reason: '$name announces itself more than once',
      );
    }

    handle.dispose();
  });

  testWidgets('a card is still a button that can be pressed', (tester) async {
    // Excluding the subtree to stop the double announcement also drops the
    // InkWell's tap action, which would leave a button a screen reader can
    // name and cannot press.
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpChooser(tester);

    final SemanticsNode card = tester.getSemantics(
      find.bySemanticsLabel(
          'Local music. A folder on this phone or an SD card'),
    );

    expect(card.flagsCollection.isButton, isTrue);
    expect(
      card.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the card must still be activatable by a screen reader',
    );

    handle.dispose();
  });

  testWidgets('the card that is working says so', (tester) async {
    // Picking a source disables all four while it runs, so without this the
    // card actually doing the work sounds exactly like the three waiting on
    // it.
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pumpChooser(tester);

    await tester.tap(find.text('Local music'));
    await tester.pump();

    final List<String> labels = _labels(tester);
    expect(
      labels.where((String l) => l.endsWith('Setting up')).length,
      1,
      reason: 'exactly the busy card should say it is working',
    );

    handle.dispose();
  });
}
