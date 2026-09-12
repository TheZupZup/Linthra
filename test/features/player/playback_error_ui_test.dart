import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_failure.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/mini_player.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/playback_error_notice.dart';

import 'fake_playback_controller.dart';

const Track _track = Track(
  id: 't1',
  title: 'Remote Song',
  uri: 'jellyfin:t1',
  artistName: 'Artist',
  albumName: 'Album',
);

const Track _sibling = Track(
  id: 't1',
  title: 'Remote Song',
  uri: 'subsonic:t1',
  artistName: 'Artist',
  albumName: 'Album',
);

PlaybackState _errorState(
  PlaybackFailure failure, {
  List<Track> upNext = const <Track>[],
}) =>
    PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: _track,
      upNext: upNext,
      failure: failure,
    );

/// A controller whose Skip does not finish until the test lets it, so the panel
/// can be observed mid-recovery, which is when an impatient second tap would
/// land.
class _SlowSkipController extends FakePlaybackController {
  _SlowSkipController({required super.initial});

  final Completer<void> skipGate = Completer<void>();

  @override
  Future<void> skipToNext() async {
    await skipGate.future;
    return super.skipToNext();
  }
}

/// A controller that behaves like the real one during a source switch: it leaves
/// the error state as soon as the attempt starts (which takes the panel off
/// screen), and only finishes once the test lets it.
class _SourceSwitchController extends FakePlaybackController {
  _SourceSwitchController({required super.initial, required this.switched});

  /// What plays once the switch lands.
  final PlaybackState switched;

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> tryAnotherSource() async {
    anotherSourceCount++;
    // Leaving `error` is what removes the panel mid-attempt.
    emit(const PlaybackState(
        status: PlaybackStatus.loading, currentTrack: _track));
    await gate.future;
    emit(switched);
  }
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  FakePlaybackController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(home: PlayerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpMiniPlayer(
  WidgetTester tester,
  FakePlaybackController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
      ],
      child: const MaterialApp(
        home: Scaffold(
            body:
                Align(alignment: Alignment.bottomCenter, child: MiniPlayer())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the now-playing error panel', () {
    testWidgets('explains the failure and offers only the valid recoveries',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.localFileUnavailable,
          message: "This track's file isn't there anymore.",
          canRetry: true,
        )),
      );
      await _pumpPlayer(tester, controller);

      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsOneWidget);
      expect(
          find.text("This track's file isn't there anymore."), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // The failure says these are not available here, so they are not drawn.
      expect(find.text('Try another source'), findsNothing);
      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('shows no buttons at all when nothing can be done',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.unplayableMedia,
          message: "This track's format isn't supported on this device.",
        )),
      );
      await _pumpPlayer(tester, controller);

      expect(
        find.text("This track's format isn't supported on this device."),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('leaves the rest of the player usable: it is not a dialog',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(
          const PlaybackFailure(
            kind: PlaybackFailureKind.temporarySource,
            message: "Couldn't reach your music server.",
            canRetry: true,
            canSkip: true,
          ),
          upNext: <Track>[_sibling],
        ),
      );
      await _pumpPlayer(tester, controller);

      // Nothing modal is pushed over the screen…
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      // …and the transport underneath it still answers.
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();

      expect(controller.skipCount, 1);
    });

    testWidgets('Retry runs the bounded controller retry, once per tap',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
          canRetry: true,
          canSkip: true,
        )),
      );
      await _pumpPlayer(tester, controller);

      await tester.tap(find.byKey(
        PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.retry),
      ));
      await tester.pumpAndSettle();

      expect(controller.retryCount, 1);
      expect(controller.skipCount, 0);
      expect(controller.anotherSourceCount, 0);
    });

    testWidgets('Skip advances the queue exactly once',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.sourceSignInRequired,
          message: 'Your session expired. Sign in again to keep streaming.',
          canSkip: true,
        )),
      );
      await _pumpPlayer(tester, controller);

      // No Retry for an expired session, and skipping is a single advance.
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.byKey(
        PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.skip),
      ));
      await tester.pumpAndSettle();

      expect(controller.skipCount, 1);
    });

    testWidgets('a recovery in flight is visible, and cannot be tapped twice',
        (WidgetTester tester) async {
      final _SlowSkipController controller = _SlowSkipController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
          canRetry: true,
          canSkip: true,
        )),
      );
      await _pumpPlayer(tester, controller);

      final Finder skip = find.byKey(
        PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.skip),
      );
      await tester.tap(skip);
      await tester.pump();

      // While it runs the panel says so and the buttons are gone, so a second
      // tap has nothing to hit and the queue cannot advance twice.
      expect(find.text('Skipping…'), findsOneWidget);
      expect(skip, findsNothing);
      expect(
        find.byKey(
          PlaybackErrorNotice.keyForAction(PlaybackRecoveryAction.retry),
        ),
        findsNothing,
      );

      controller.skipGate.complete();
      await tester.pumpAndSettle();

      expect(controller.skipCount, 1);
    });

    testWidgets('a successful source switch says where the music came from',
        (WidgetTester tester) async {
      final _SourceSwitchController controller = _SourceSwitchController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
          canRetry: true,
          canTryAnotherSource: true,
        )),
        // What plays when the sibling copy works: same song, same queue entry,
        // a different provider behind it.
        switched: const PlaybackState(
          status: PlaybackStatus.playing,
          currentTrack: _sibling,
          source: PlaybackSource.streamingDirect,
        ),
      );
      await _pumpPlayer(tester, controller);

      await tester.tap(find.byKey(
        PlaybackErrorNotice.keyForAction(
          PlaybackRecoveryAction.tryAnotherSource,
        ),
      ));
      // The attempt takes the panel off screen before it lands, exactly as the
      // real controller does, and the confirmation must survive that.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsNothing);

      controller.gate.complete();
      await tester.pumpAndSettle();

      expect(controller.anotherSourceCount, 1);
      // The one recovery whose result is otherwise invisible is confirmed by
      // name.
      expect(find.byKey(PlaybackErrorNotice.noticeKey), findsNothing);
      expect(find.text('Playing from Navidrome.'), findsOneWidget);
    });

    testWidgets('a recovery that fails again leaves the panel up, not a toast',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
          canTryAnotherSource: true,
        )),
      );
      controller.anotherSourceResult = _errorState(const PlaybackFailure(
        kind: PlaybackFailureKind.temporarySource,
        message: "Couldn't play this track from any available source.",
        canSkip: true,
      ));
      await _pumpPlayer(tester, controller);

      await tester.tap(find.byKey(
        PlaybackErrorNotice.keyForAction(
          PlaybackRecoveryAction.tryAnotherSource,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.text("Couldn't play this track from any available source."),
        findsOneWidget,
      );
      // The recoveries follow the new failure: nowhere else to try, but the
      // listener can still move on.
      expect(find.text('Try another source'), findsNothing);
      expect(find.text('Skip'), findsOneWidget);
    });
  });

  group('the mini-player', () {
    testWidgets('says the track is failing instead of naming a source',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.sourceSignInRequired,
          message: 'Your session expired. Sign in again to keep streaming.',
          canSkip: true,
        )),
      );
      await _pumpMiniPlayer(tester, controller);

      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.text('Sign-in needed'), findsOneWidget);
      // The bar has one line: the artist/source line steps aside for it, and
      // the full message stays on the now-playing screen a tap away.
      expect(find.text('Artist • Album'), findsNothing);
    });

    testWidgets('goes back to the normal line once something plays',
        (WidgetTester tester) async {
      final FakePlaybackController controller = FakePlaybackController(
        initial: _errorState(const PlaybackFailure(
          kind: PlaybackFailureKind.temporarySource,
          message: "Couldn't reach your music server.",
          canRetry: true,
        )),
      );
      await _pumpMiniPlayer(tester, controller);
      expect(find.text('Playback problem'), findsOneWidget);

      controller.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _sibling,
        source: PlaybackSource.streamingDirect,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Playback problem'), findsNothing);
      expect(find.textContaining('Navidrome'), findsOneWidget);
    });
  });
}
