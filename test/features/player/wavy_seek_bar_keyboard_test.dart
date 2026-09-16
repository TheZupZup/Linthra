import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/player/widgets/wavy_seek_bar.dart';
import 'package:linthra/shared/widgets/wavy_progress_indicator.dart';

/// The seek bar replaces a real [Slider], so it has to replace the keyboard
/// support a [Slider] would have brought with it: reachable with Tab, seekable
/// with the arrow keys, and honest about being focused. Without this there is
/// no way to seek at all on a desktop window without a pointer.
void main() {
  const Duration total = Duration(minutes: 4);
  final double maxMs = total.inMilliseconds.toDouble();
  // 5% of a four-minute track.
  const double stepMs = 12000;

  String formatMs(double ms) {
    final Duration d = Duration(milliseconds: ms.round());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  Future<List<double>> pumpBar(
    WidgetTester tester, {
    required double value,
    double max = 0,
    bool enabled = true,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    final List<double> seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: textDirection,
          child: Scaffold(
            body: Column(
              children: <Widget>[
                // A neighbour before the bar, so Tab order can be observed.
                TextButton(onPressed: () {}, child: const Text('before')),
                WavySeekBar(
                  value: value,
                  max: max,
                  onChanged: enabled ? (_) {} : null,
                  onChangeEnd: enabled ? seeks.add : null,
                  semanticFormatter: formatMs,
                ),
                TextButton(onPressed: () {}, child: const Text('after')),
              ],
            ),
          ),
        ),
      ),
    );
    return seeks;
  }

  /// The bar's own focus node, read the way the widget itself reads it.
  FocusNode barFocusNode(WidgetTester tester) => Focus.of(
        tester.element(
          find.descendant(
            of: find.byType(WavySeekBar),
            matching: find.byType(WavyProgressIndicator),
          ),
        ),
      );

  testWidgets('takes keyboard focus in visual order between its neighbours',
      (tester) async {
    await pumpBar(tester, value: 60000, max: maxMs);

    // Start on the button above the bar, then walk forward.
    Focus.of(tester.element(find.text('before'))).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(barFocusNode(tester).hasFocus, isTrue,
        reason: 'Tab should reach the seek bar after the control above it');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(barFocusNode(tester).hasFocus, isFalse);
    expect(
      Focus.of(tester.element(find.text('after'))).hasFocus,
      isTrue,
      reason: 'and continue to the control below it',
    );

    // Shift+Tab comes back the same way.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(barFocusNode(tester).hasFocus, isTrue);
  });

  testWidgets('arrow keys seek by one step in each direction', (tester) async {
    final List<double> seeks = await pumpBar(tester, value: 60000, max: maxMs);
    barFocusNode(tester).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.single, 60000 + stepMs);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(seeks.last, 60000 - stepMs);
  });

  testWidgets('a modified arrow belongs to whoever bound it', (tester) async {
    // Ctrl+→ is a shortcut (#391). Seeking on it here would both move the
    // track and swallow the chord, leaving the binding dead for as long as the
    // bar held focus.
    final List<double> seeks = await pumpBar(tester, value: 60000, max: maxMs);
    barFocusNode(tester).requestFocus();
    await tester.pump();

    for (final LogicalKeyboardKey modifier in <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(seeks, isEmpty, reason: '$modifier should have been left alone');
    }

    // Unmodified, it is the bar's key again.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.single, 60000 + stepMs);
  });

  testWidgets('arrow keys are mirrored under right-to-left', (tester) async {
    final List<double> seeks = await pumpBar(
      tester,
      value: 60000,
      max: maxMs,
      textDirection: TextDirection.rtl,
    );
    barFocusNode(tester).requestFocus();
    await tester.pump();

    // "Right" is earlier when the track runs right-to-left.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.single, 60000 - stepMs);
  });

  testWidgets('a seek never leaves the track', (tester) async {
    final List<double> seeks = await pumpBar(tester, value: 0, max: maxMs);
    barFocusNode(tester).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(seeks.single, 0);
  });

  testWidgets('an unseekable bar is skipped by the keyboard entirely',
      (tester) async {
    // No duration yet: nothing to seek to, so it must not swallow a Tab stop.
    await pumpBar(tester, value: 0, enabled: false);

    final FocusNode node = barFocusNode(tester);
    expect(node.canRequestFocus, isFalse);
    expect(node.skipTraversal, isTrue);

    Focus.of(tester.element(find.text('before'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(node.hasFocus, isFalse);
    expect(Focus.of(tester.element(find.text('after'))).hasFocus, isTrue);
  });

  testWidgets('reports focus, and the focus action, to assistive tech',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpBar(tester, value: 60000, max: maxMs);

    final Finder bar = find.byType(WavySeekBar);
    expect(
      tester.getSemantics(bar),
      matchesSemantics(
        label: 'Playback position',
        value: '1:00 of 4:00',
        isSlider: true,
        isFocusable: true,
        hasIncreaseAction: true,
        hasDecreaseAction: true,
        hasFocusAction: true,
      ),
    );

    // The focus action is what a screen reader uses to hand it the keyboard.
    tester.semantics.performAction(
      find.semantics.byLabel('Playback position'),
      SemanticsAction.focus,
    );
    await tester.pump();
    expect(barFocusNode(tester).hasFocus, isTrue);
    expect(
      tester.getSemantics(bar).flagsCollection.isFocused,
      Tristate.isTrue,
    );

    handle.dispose();
  });
}
