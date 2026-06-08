import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/now_playing_indicator.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool animating,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Center(
              child: SizedBox.square(
                dimension: 48,
                child: NowPlayingIndicator(animating: animating),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('NowPlayingIndicator', () {
    testWidgets('renders the indicator', (WidgetTester tester) async {
      await _pump(tester, animating: false);
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingIndicator), findsOneWidget);
    });

    testWidgets('animates while playing', (WidgetTester tester) async {
      await _pump(tester, animating: true);
      await tester.pump(const Duration(milliseconds: 100));
      // A running equalizer keeps requesting frames.
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('is static while paused', (WidgetTester tester) async {
      await _pump(tester, animating: false);
      // Settling at all proves nothing is animating perpetually.
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('does not animate when reduce-motion is requested',
        (WidgetTester tester) async {
      await _pump(tester, animating: true, reduceMotion: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('exposes a now-playing semantics label while playing',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, animating: true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.bySemanticsLabel('Now playing'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('exposes a paused semantics label while paused',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, animating: false);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Now playing, paused'), findsOneWidget);
      handle.dispose();
    });
  });
}
