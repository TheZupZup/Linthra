import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/playback_controls.dart';

import 'fake_playback_controller.dart';

/// The big play button on Now Playing has to say what state it is in (#460).
///
/// While a track is first being prepared it shows a spinner and stops taking
/// taps. Seen, that reads as "wait". Heard, it used to read as a Play button
/// that is simply disabled, with nothing saying why or for how long.
const Track _track = Track(id: '1', title: 'Song One', uri: '/music/1.mp3');

Future<void> _pump(WidgetTester tester, PlaybackState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider
            .overrideWithValue(FakePlaybackController(initial: state)),
      ],
      child: MaterialApp(
        home: Scaffold(body: PlaybackControls(state: state)),
      ),
    ),
  );
}

/// The semantics node announcing [tooltip], looked up in the semantics tree
/// itself: a finder on the [Tooltip] widget can resolve to an ancestor node.
SemanticsData _playButton(WidgetTester tester, String tooltip) {
  final Iterable<SemanticsNode> nodes = find.semantics
      .byPredicate((SemanticsNode node) => node.tooltip == tooltip)
      .evaluate();
  expect(nodes, hasLength(1));
  return nodes.single.getSemanticsData();
}

void main() {
  testWidgets('a preparing track is announced as buffering, not just disabled',
      (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _pump(
      tester,
      const PlaybackState(status: PlaybackStatus.loading, currentTrack: _track),
    );

    final SemanticsData data = _playButton(tester, 'Play');
    expect(data.value, 'Buffering');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });

  for (final (PlaybackStatus status, String tooltip)
      in <(PlaybackStatus, String)>[
    (PlaybackStatus.paused, 'Play'),
    (PlaybackStatus.playing, 'Pause'),
  ]) {
    testWidgets('and says nothing extra once it can be pressed ($status)',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester, PlaybackState(status: status, currentTrack: _track));

      final SemanticsData data = _playButton(tester, tooltip);
      expect(data.value, isEmpty);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  }
}
