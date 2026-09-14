import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/scroll/app_scroll_behavior.dart';
import 'package:linthra/shared/scroll/pointer_scroll_adjust.dart';
import 'package:linthra/shared/scroll/pointer_scroll_policy.dart';

/// A control inside a scrolling page, which is where seek and volume live
/// (#396).
///
/// The bug this covers is that a `Listener` reading a scroll signal does not
/// take it: before this, one notch over the volume slider changed the volume
/// *and* scrolled the library out from under the pointer.

const Key _control = Key('control');
const Key _elsewhere = Key('elsewhere');

/// Sends one scroll signal over [target], the way a wheel or a trackpad would.
Future<void> _scrollOver(
  WidgetTester tester,
  Finder target,
  Offset delta, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  Duration at = Duration.zero,
}) async {
  final TestPointer pointer = TestPointer(1, kind);
  pointer.hover(tester.getCenter(target));
  await tester.sendEventToBinding(pointer.scroll(delta, timeStamp: at));
  await tester.pump();
}

class _Harness extends StatefulWidget {
  const _Harness({this.enabled = true});

  final bool enabled;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final ScrollController page = ScrollController();
  final List<int> notches = <int>[];
  bool adjusting = false;

  /// Starts or ends the "control is being held" state, the way a slider's own
  /// drag callbacks do.
  void setAdjusting(bool value) => setState(() => adjusting = value);

  @override
  void dispose() {
    page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        controller: page,
        children: <Widget>[
          const SizedBox(key: _elsewhere, height: 200, child: Text('above')),
          PointerScrollAdjust(
            enabled: widget.enabled,
            adjusting: adjusting,
            onNotch: notches.add,
            child: const SizedBox(key: _control, height: 60, child: Text('c')),
          ),
          for (int i = 0; i < 30; i++)
            SizedBox(height: 100, child: Text('row $i')),
        ],
      ),
    );
  }
}

Future<_HarnessState> _pump(WidgetTester tester, {bool enabled = true}) async {
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      home: _Harness(enabled: enabled),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HarnessState>(find.byType(_Harness));
}

void main() {
  testWidgets('a notch over the control adjusts it and leaves the page put',
      (tester) async {
    final _HarnessState state = await _pump(tester);

    await _scrollOver(tester, find.byKey(_control), const Offset(0, 53));

    expect(state.notches, <int>[-1], reason: 'scrolling down asks for less');
    expect(
      state.page.offset,
      0,
      reason: 'the page must not move because the pointer was on a control',
    );
  });

  testWidgets('scrolling up over the control asks for more', (tester) async {
    final _HarnessState state = await _pump(tester);
    await _scrollOver(tester, find.byKey(_control), const Offset(0, -53));
    expect(state.notches, <int>[1]);
  });

  testWidgets('a sideways wheel over the control counts too', (tester) async {
    final _HarnessState state = await _pump(tester);
    // A horizontal wheel, or a sideways trackpad flick: on a control that
    // reads left to right, left is less.
    await _scrollOver(tester, find.byKey(_control), const Offset(53, 0));
    expect(state.notches, <int>[-1]);
  });

  testWidgets('a trackpad flick is one step, not forty', (tester) async {
    final _HarnessState state = await _pump(tester);

    for (int i = 0; i < 10; i++) {
      await _scrollOver(
        tester,
        find.byKey(_control),
        const Offset(0, wheelNotchExtent / 10),
        kind: PointerDeviceKind.trackpad,
      );
    }

    expect(
      state.notches,
      <int>[-1],
      reason: 'one gesture the size of one notch is one step',
    );
    expect(state.page.offset, 0);
  });

  testWidgets('two separate trackpad swipes do not add up into one step',
      (tester) async {
    // Fingers lifting from a trackpad look exactly like a pause, so a swipe
    // that stopped short of a notch must not be completed by an unrelated one
    // later — the first would appear to do nothing and the second to overshoot.
    final _HarnessState state = await _pump(tester);

    const Offset third = Offset(0, wheelNotchExtent / 3);
    await _scrollOver(tester, find.byKey(_control), third,
        kind: PointerDeviceKind.trackpad);
    await _scrollOver(tester, find.byKey(_control), third,
        kind: PointerDeviceKind.trackpad, at: const Duration(milliseconds: 16));
    expect(state.notches, isEmpty, reason: 'two thirds is not a notch yet');

    // Long enough later to be a gesture of its own.
    await _scrollOver(tester, find.byKey(_control), third,
        kind: PointerDeviceKind.trackpad, at: WheelNotches.gestureGap * 2);
    expect(
      state.notches,
      isEmpty,
      reason: 'the earlier swipe is over; this one is a third of a notch',
    );
  });

  testWidgets('the page still scrolls everywhere else on it', (tester) async {
    final _HarnessState state = await _pump(tester);
    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(state.page.offset, 53);
    expect(state.notches, isEmpty);
  });

  testWidgets('a disabled control claims nothing', (tester) async {
    final _HarnessState state = await _pump(tester, enabled: false);
    await _scrollOver(tester, find.byKey(_control), const Offset(0, 53));
    expect(state.notches, isEmpty);
    expect(
      state.page.offset,
      53,
      reason: 'an inert widget is just part of the page',
    );
  });

  testWidgets('nothing scrolls anywhere while the control is being held',
      (tester) async {
    final _HarnessState state = await _pump(tester);

    // A real hold is a pointer down on the control plus the control saying it
    // is being adjusted; the shield needs both.
    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byKey(_control)),
      kind: PointerDeviceKind.mouse,
    );
    state.setAdjusting(true);
    await tester.pump();
    await tester.pump();

    // Mid-drag the pointer wanders off a 14 px seek line easily. A notch that
    // lands on the page behind it must not move the page either.
    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(state.page.offset, 0);

    await hold.up();
    state.setAdjusting(false);
    await tester.pump();
    await tester.pump();

    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(
      state.page.offset,
      53,
      reason: 'letting go hands the wheel back to the page',
    );
  });

  testWidgets('a control that never says it let go cannot keep the shield',
      (tester) async {
    // The shield is the most destructive thing this widget does, so it is not
    // left to a control remembering to clear its own drag state. The pointer's
    // up is what takes it away.
    final _HarnessState state = await _pump(tester);

    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byKey(_control)),
      kind: PointerDeviceKind.mouse,
    );
    state.setAdjusting(true);
    await tester.pump();
    await tester.pump();

    await hold.up();
    await tester.pump();
    await tester.pump();

    // `adjusting` is deliberately still set — the control is wrong about
    // itself — and the page must scroll anyway.
    expect(state.adjusting, isTrue);
    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(state.page.offset, 53);
  });

  testWidgets('a cancelled press takes the shield with it', (tester) async {
    final _HarnessState state = await _pump(tester);

    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byKey(_control)),
      kind: PointerDeviceKind.mouse,
    );
    state.setAdjusting(true);
    await tester.pump();
    await tester.pump();

    await hold.cancel();
    await tester.pump();
    await tester.pump();

    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(state.page.offset, 53);
  });

  testWidgets('a keyboard adjustment never installs one', (tester) async {
    // An arrow key is over the instant it happens: there is no drag for a
    // stray notch to land in the middle of, and a shield installed for one
    // would have nothing to take it away.
    final _HarnessState state = await _pump(tester);

    state.setAdjusting(true);
    await tester.pump();
    await tester.pump();

    await _scrollOver(tester, find.byKey(_elsewhere), const Offset(0, 53));
    expect(state.page.offset, 53);
  });

  testWidgets('a touch drag over the control still scrolls the page',
      (tester) async {
    // The whole of Android depends on this: a finger never produces a scroll
    // signal, so nothing above can claim it, and a list dragged from a control
    // scrolls exactly as it always did.
    final _HarnessState state = await _pump(tester);

    await tester.drag(find.byKey(_control), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(state.page.offset, greaterThan(0));
    expect(state.notches, isEmpty);
  });

  testWidgets('one notch is one step at every display scale', (tester) async {
    for (final double ratio in <double>[1.0, 1.25, 1.5, 2.0]) {
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);

      final _HarnessState state = await _pump(tester);
      // The element tree is reused between pumps in this loop, so the state
      // carries over: start each scale from a clean slate.
      state.notches.clear();
      state.page.jumpTo(0);
      await _scrollOver(tester, find.byKey(_control), const Offset(0, 53));

      expect(
        state.notches,
        <int>[-1],
        reason: 'one wheel click at ${(ratio * 100).round()}% scaling',
      );
      expect(state.page.offset, 0);
    }
  });
}
