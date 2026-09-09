import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/player/widgets/playback_progress_bar.dart';
import 'package:linthra/features/player/widgets/wavy_seek_bar.dart';

/// The bar is pumped at a fixed 300dp so the tap/drag maths below are exact:
/// the painter insets the track by the marker radius (6) at each end, leaving a
/// 288dp travel, and the widget is centred in an 800dp-wide test window.
const double _barWidth = 300;
const Duration _total = Duration(minutes: 4);

/// Pumps the bar, returning the list every seek lands in.
///
/// Passing [seeks] back in re-pumps the *same* bar with a new [position] — the
/// widget type and location are unchanged, so the element and its state survive
/// and the bar sees the update exactly as it would from a position tick.
Future<List<Duration>> _pumpBar(
  WidgetTester tester, {
  Duration position = Duration.zero,
  Duration duration = _total,
  bool seekable = true,
  bool playing = false,
  PlaybackProgressStyle style = PlaybackProgressStyle.wave,
  WavySeekBarDensity density = WavySeekBarDensity.standard,
  List<Duration>? seeks,
}) async {
  seeks ??= <Duration>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _barWidth,
            child: PlaybackProgressBar(
              position: position,
              duration: duration,
              playing: playing,
              style: style,
              density: density,
              onSeek: seekable ? seeks.add : null,
              // Keyed so a re-pump with a new position updates this bar rather
              // than replacing it — the state under test has to survive.
              key: const Key('progress-bar'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return seeks;
}

/// Drags the wave to [fraction] of the track and lifts the finger, returning
/// after the frame that release produced.
Future<void> _dragTo(WidgetTester tester, double fraction) async {
  // The painter insets the box by the marker radius (6) at each end.
  const double travel = _barWidth - 12;
  final Offset centre = tester.getCenter(find.byType(WavySeekBar));
  final TestGesture gesture = await tester.startGesture(centre);
  await tester.pump();
  await gesture.moveTo(centre + Offset((fraction - 0.5) * travel, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  group('PlaybackProgressBar (wave)', () {
    testWidgets('is the default style', (tester) async {
      await _pumpBar(tester);

      expect(find.byType(WavySeekBar), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('renders the elapsed and total times', (tester) async {
      await _pumpBar(tester, position: const Duration(seconds: 75));

      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('4:00'), findsOneWidget);
    });

    testWidgets('reads --:-- and does not seek without a duration',
        (tester) async {
      final seeks = await _pumpBar(tester, duration: Duration.zero);

      expect(find.text('--:--'), findsOneWidget);

      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();
      expect(seeks, isEmpty);
    });

    testWidgets('a tap seeks to the touched point', (tester) async {
      final seeks = await _pumpBar(tester);

      // The centre of the track is half of a four-minute song.
      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(120, 1));
    });

    testWidgets('a drag previews the elapsed label and seeks once on release',
        (tester) async {
      final seeks = await _pumpBar(tester);

      final Offset centre = tester.getCenter(find.byType(WavySeekBar));
      final TestGesture gesture = await tester.startGesture(centre);
      await tester.pump();
      // Quarter of the 288dp travel is 25% of the song…
      await gesture.moveTo(centre - const Offset(72, 0));
      await tester.pump();

      // …shown live in the label, with nothing committed yet.
      expect(find.text('1:00'), findsOneWidget);
      expect(seeks, isEmpty);

      await gesture.up();
      await tester.pump();

      // Exactly one seek, at the released position.
      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(60, 1));
    });

    testWidgets('renders progress but never seeks with no onSeek handler',
        (tester) async {
      final seeks = await _pumpBar(
        tester,
        position: const Duration(minutes: 1),
        seekable: false,
      );

      expect(find.text('1:00'), findsOneWidget);
      await tester.tap(find.byType(WavySeekBar));
      await tester.pump();
      expect(seeks, isEmpty);
    });

    testWidgets('never animates perpetually, playing or paused',
        (tester) async {
      // The bar lives on the screen users leave open longest, so it must settle
      // in both states — pumpAndSettle returning is the whole assertion.
      await _pumpBar(tester, playing: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await _pumpBar(tester, playing: false);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('PlaybackProgressBar seek handoff', () {
    // The position stream is coalesced to ~250 ms for battery, so for a moment
    // after a seek it still reports where playback *was*. These tests pin the
    // handoff across that gap: the released target holds the display until the
    // authoritative position reaches it, so the marker never snaps backwards
    // and then forward again.

    testWidgets('releasing a drag does not snap back to the old position',
        (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);

      await _dragTo(tester, 0.25);

      // Released at a quarter of a four-minute song.
      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(60, 1));
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('0:00'), findsNothing);

      // The next ticks still carry the pre-seek position — the seek has not
      // reached playbackStateProvider yet. The bar must not show it.
      for (final Duration stale in <Duration>[
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]) {
        await _pumpBar(tester, position: stale, seeks: seeks);
        expect(find.text('1:00'), findsOneWidget);
        expect(find.text('0:00'), findsNothing);
      }
    });

    testWidgets('normal position updates take over once playback catches up',
        (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);
      await _dragTo(tester, 0.25);
      await _pumpBar(tester, position: Duration.zero, seeks: seeks);
      expect(find.text('1:00'), findsOneWidget);

      // The seek lands: the first authoritative position at the target hands
      // the display straight back.
      await _pumpBar(
        tester,
        position: const Duration(seconds: 60, milliseconds: 120),
        seeks: seeks,
      );
      await _pumpBar(tester,
          position: const Duration(seconds: 63), seeks: seeks);
      expect(find.text('1:03'), findsOneWidget);

      // Including an update that moves *backwards*, which a still-pinned bar
      // would have swallowed.
      await _pumpBar(tester,
          position: const Duration(seconds: 30), seeks: seeks);
      expect(find.text('0:30'), findsOneWidget);
    });

    testWidgets('a drag still seeks exactly once, however long the hold lasts',
        (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);

      await _dragTo(tester, 0.75);

      for (final int seconds in <int>[0, 1, 180, 181]) {
        await _pumpBar(
          tester,
          position: Duration(seconds: seconds),
          seeks: seeks,
        );
      }

      expect(seeks, hasLength(1));
      expect(seeks.single.inSeconds, closeTo(180, 1));
    });

    testWidgets('a seek that never lands releases the bar after the timeout',
        (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);
      await _dragTo(tester, 0.25);

      // Playback carries on where it was: the seek failed. The bar holds the
      // optimistic target only while the bound allows.
      await _pumpBar(tester,
          position: const Duration(seconds: 1), seeks: seeks);
      expect(find.text('1:00'), findsOneWidget);

      await tester.pump(
        PlaybackProgressBar.seekAckTimeout + const Duration(milliseconds: 1),
      );
      await tester.pump();

      expect(find.text('0:01'), findsOneWidget);
      expect(find.text('1:00'), findsNothing);
    });

    testWidgets('a new drag supersedes the held target', (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);
      await _dragTo(tester, 0.25);
      expect(find.text('1:00'), findsOneWidget);

      // Second thoughts, before the first seek was ever reported.
      await _dragTo(tester, 0.75);

      expect(find.text('3:00'), findsOneWidget);
      expect(seeks, hasLength(2));
    });

    testWidgets('a new track drops a target measured against the old one',
        (tester) async {
      final List<Duration> seeks = <Duration>[];
      await _pumpBar(tester, seeks: seeks);
      await _dragTo(tester, 0.25);
      expect(find.text('1:00'), findsOneWidget);

      await _pumpBar(
        tester,
        position: const Duration(seconds: 3),
        duration: const Duration(minutes: 5),
        seeks: seeks,
      );

      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('5:00'), findsOneWidget);
    });
  });

  group('PlaybackProgressBar (wave) accessibility', () {
    testWidgets('announces the position as a slider', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(tester, position: const Duration(seconds: 75));

      final SemanticsNode node = tester.getSemantics(find.byType(WavySeekBar));
      expect(node.label, 'Playback position');
      expect(node.value, '1:15 of 4:00');
      expect(
        node.flagsCollection.isSlider,
        isTrue,
        reason: 'replacing Slider must not drop the slider role',
      );

      handle.dispose();
    });

    testWidgets('increase and decrease seek by a step', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final seeks =
          await _pumpBar(tester, position: const Duration(minutes: 1));

      // 5% of a four-minute track is 12s, comfortably over the 5s floor.
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.single, const Duration(seconds: 72));

      seeks.clear();
      // A step lands on the announced value, not on a position the coalesced
      // stream has yet to report: stepping down from 1:12 returns to 1:00,
      // rather than stepping down from a stale 1:00 and jumping to 0:48.
      expect(
        tester.getSemantics(find.byType(WavySeekBar)).value,
        '1:12 of 4:00',
      );
      tester.semantics.decrease(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.single, const Duration(seconds: 60));

      handle.dispose();
    });

    testWidgets('a step away from a stale position still lands where announced',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final seeks =
          await _pumpBar(tester, position: const Duration(minutes: 1));

      // Two increases in quick succession, before either is reported: the
      // second must build on the first rather than repeat it.
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pump();
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pump();

      expect(
        seeks,
        <Duration>[const Duration(seconds: 72), const Duration(seconds: 84)],
      );

      handle.dispose();
    });

    testWidgets('is read-only, not a slider, without a duration',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(tester, duration: Duration.zero);

      final SemanticsNode node = tester.getSemantics(find.byType(WavySeekBar));
      expect(node.value, 'Unknown');
      expect(node.flagsCollection.isSlider, isFalse);

      handle.dispose();
    });
  });

  group('PlaybackProgressBar (slider fallback)', () {
    testWidgets('still renders a Material slider and seeks', (tester) async {
      final seeks = await _pumpBar(
        tester,
        style: PlaybackProgressStyle.slider,
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(WavySeekBar), findsNothing);

      await tester.tap(find.byType(Slider));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(Duration.zero));
    });

    testWidgets('shows the same labels as the wave', (tester) async {
      await _pumpBar(
        tester,
        position: const Duration(seconds: 75),
        style: PlaybackProgressStyle.slider,
      );

      expect(find.text('1:15'), findsOneWidget);
      expect(find.text('4:00'), findsOneWidget);
    });

    testWidgets('announces the same name and value as the wave',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(
        tester,
        position: const Duration(seconds: 75),
        style: PlaybackProgressStyle.slider,
      );

      // Without this the fallback announced a bare percentage, with nothing
      // saying what it measured.
      final SemanticsNode slider = _sliderNode();
      expect(slider.label, 'Playback position');
      expect(slider.value, '1:15 of 4:00');
      handle.dispose();
    });

    testWidgets('an unknown duration says so rather than implying a length',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpBar(
        tester,
        duration: Duration.zero,
        style: PlaybackProgressStyle.slider,
      );

      final SemanticsNode slider = _sliderNode();
      expect(slider.label, 'Playback position');
      expect(slider.value, 'Unknown');
      handle.dispose();
    });

    // Flipping defaultPlaybackProgressStyle back to the slider is meant to be a
    // one-constant change. The mini player asks for a compact bar and keeps 64dp
    // for the whole thing, so a fallback that ignored the density would take the
    // room its transport row needs.
    //
    // Both densities are pumped in one tree: the Material slider only repaints
    // when its theme changes, so measuring one after the other in the same
    // element would read the first one's size twice.
    testWidgets('a compact slider still fits the mini player', (tester) async {
      final List<Duration> seeks = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: <Widget>[
                for (final WavySeekBarDensity density
                    in WavySeekBarDensity.values)
                  SizedBox(
                    width: _barWidth,
                    child: PlaybackProgressBar(
                      key: ValueKey<WavySeekBarDensity>(density),
                      position: Duration.zero,
                      duration: _total,
                      style: PlaybackProgressStyle.slider,
                      density: density,
                      onSeek: seeks.add,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      double heightOf(WavySeekBarDensity density) => tester
          .getSize(
            find.descendant(
              of: find.byKey(ValueKey<WavySeekBarDensity>(density)),
              matching: find.byType(Slider),
            ),
          )
          .height;

      final double compact = heightOf(WavySeekBarDensity.compact);
      expect(compact, lessThan(heightOf(WavySeekBarDensity.standard)));
      // 64dp bar, 48dp of transport buttons under it.
      expect(compact, lessThanOrEqualTo(16));

      // Still a seek bar, not just a thinner drawing of one.
      await tester.tap(
        find.descendant(
          of: find.byKey(
            const ValueKey<WavySeekBarDensity>(WavySeekBarDensity.compact),
          ),
          matching: find.byType(Slider),
        ),
      );
      await tester.pump();
      expect(seeks, hasLength(1));
    });
  });
}

/// The Material slider's own node. [Slider] is a semantic boundary below its
/// widget, so it is found by role rather than by widget type.
SemanticsNode _sliderNode() => find.semantics
    .byPredicate(
      (SemanticsNode node) => node.flagsCollection.isSlider,
      describeMatch: (_) => 'the seek slider',
    )
    .evaluate()
    .single;
