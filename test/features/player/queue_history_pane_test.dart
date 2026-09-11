import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_history.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/features/player/playback_history_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/queue_sheet.dart';

import 'fake_playback_controller.dart';

/// Desktop queue history (#419).
///
/// The desktop pane shows the session's *bounded recent-playback* history,
/// which survives the queue being replaced; a sheet (which is what Android
/// gets, at any width) keeps the queue's own already-played prefix.

Track _track(String id) => Track(
      id: id,
      title: 'Song $id',
      uri: 'jellyfin:$id',
      artistName: 'Artist $id',
      duration: const Duration(minutes: 3),
    );

/// Pumps the queue as an embedded pane on [host].
Future<ProviderContainer> _pumpPane(
  WidgetTester tester, {
  required FakePlaybackController controller,
  HostPlatform host = HostPlatform.linux,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(500, 1400);
  addTearDown(tester.view.reset);

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      playbackControllerProvider.overrideWithValue(controller),
      hostPlatformProvider.overrideWithValue(host),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: QueueSheet(embedded: true)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Plays [ids] one after another, letting each reach its end, so the recorder
/// sees three completed tracks from the live state stream.
Future<void> _playThrough(
  WidgetTester tester,
  FakePlaybackController controller,
  List<String> ids,
) async {
  for (final String id in ids) {
    final Track track = _track(id);
    controller.emit(PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: track,
      duration: const Duration(minutes: 3),
    ));
    await tester.pump();
    controller.emit(PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: track,
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 3),
    ));
    await tester.pump();
  }
}

void main() {
  group('the desktop pane', () {
    testWidgets('shows recently played separately from up next',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await _pumpPane(tester, controller: controller);

      await _playThrough(tester, controller, <String>['1', '2', '3']);
      // Land on a fourth track so the third one leaves the player too.
      await controller.playTracks(<Track>[_track('4'), _track('5')]);
      await tester.pumpAndSettle();

      expect(find.text('Recently played'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('Now playing'), findsOneWidget);
      // The queue-derived section belongs to the sheet, not to this pane.
      expect(find.text('Previously played'), findsNothing);
      // Newest first.
      expect(find.text('Song 3'), findsOneWidget);
      expect(find.text('Song 1'), findsOneWidget);
      // Up next is still the queue's, untouched.
      expect(find.text('Song 5'), findsOneWidget);
      // The bound is stated where it applies, so an older song falling off the
      // list is never a mystery.
      expect(
        find.textContaining('last ${PlaybackHistory.defaultLimit} tracks'),
        findsOneWidget,
      );
    });

    testWidgets('history survives the queue being replaced', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container =
          await _pumpPane(tester, controller: controller);

      await _playThrough(tester, controller, <String>['1']);
      // A brand new queue: the old queue's own history is gone with it.
      await controller.playTracks(<Track>[_track('9')]);
      await tester.pumpAndSettle();

      expect(controller.state.previous, isEmpty);
      expect(
        container.read(playbackHistoryProvider).entryFor('jellyfin:1'),
        isNotNull,
      );
      expect(find.text('Song 1'), findsOneWidget);
    });

    testWidgets('the retention bound is enforced and stated', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container =
          await _pumpPane(tester, controller: controller);

      await _playThrough(
        tester,
        controller,
        <String>[
          for (int i = 0; i < PlaybackHistory.defaultLimit + 20; i++) '$i'
        ],
      );
      await tester.pumpAndSettle();

      final PlaybackHistory history = container.read(playbackHistoryProvider);
      expect(history.length, PlaybackHistory.defaultLimit);
      // The oldest tracks are the ones that rolled off; the newest are kept.
      expect(history.entryFor('jellyfin:0'), isNull);
      expect(history.entries.first.track.id, isNot('0'));
    });

    testWidgets('Clear drops the history as well as the queue', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container =
          await _pumpPane(tester, controller: controller);

      await _playThrough(tester, controller, <String>['1']);
      await controller.playTracks(<Track>[_track('2'), _track('3')]);
      await tester.pumpAndSettle();
      expect(container.read(playbackHistoryProvider).isNotEmpty, isTrue);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(container.read(playbackHistoryProvider).isEmpty, isTrue);
      expect(controller.clearCount, 1);
      expect(find.text('Recently played'), findsNothing);
      // The track playing now is untouched, exactly as Clear has always meant.
      expect(controller.state.currentTrack?.id, '2');
    });
  });

  group('replaying a history row', () {
    testWidgets('steps back inside the queue when the track is still in it',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await _pumpPane(tester, controller: controller);

      await controller.playTracks(
        <Track>[_track('1'), _track('2'), _track('3')],
      );
      await tester.pumpAndSettle();
      await controller.skipToNext();
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.id, '2');
      expect(controller.state.upNext.map((Track t) => t.id), <String>['3']);

      await tester.tap(find.text('Song 1'));
      await tester.pumpAndSettle();

      expect(controller.state.currentTrack?.id, '1');
      // Up next is preserved — this is the in-queue step back, not a rebuild.
      expect(
        controller.state.upNext.map((Track t) => t.id),
        <String>['2', '3'],
      );
    });

    testWidgets('plays a track from an earlier queue through the normal path',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      await _pumpPane(tester, controller: controller);

      await _playThrough(tester, controller, <String>['1']);
      await controller.playTracks(<Track>[_track('8'), _track('9')]);
      await tester.pumpAndSettle();

      final int playsBefore = controller.playedTracks.length;
      await tester.tap(find.text('Song 1'));
      await tester.pumpAndSettle();

      // It went through the ordinary play path, so the source is resolved
      // fresh; the history itself holds no playable URL to reuse.
      expect(controller.playedTracks.length, playsBefore + 1);
      expect(controller.playedTracks.last.id, '1');
      expect(controller.state.currentTrack?.id, '1');
    });
  });

  group('Android is untouched', () {
    testWidgets('a wide Android window keeps the queue-derived history',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container = await _pumpPane(
        tester,
        controller: controller,
        host: HostPlatform.android,
      );

      await controller.playTracks(
        <Track>[_track('1'), _track('2'), _track('3')],
      );
      await tester.pumpAndSettle();
      await controller.skipToNext();
      await tester.pumpAndSettle();

      expect(find.text('Previously played'), findsOneWidget);
      expect(find.text('Recently played'), findsNothing);
      // The recorder never runs off desktop, so nothing is collected at all.
      expect(container.read(playbackHistoryProvider).isEmpty, isTrue);
    });

    testWidgets('the recorder collects nothing on Android', (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container = await _pumpPane(
        tester,
        controller: controller,
        host: HostPlatform.android,
      );

      await _playThrough(tester, controller, <String>['1', '2']);
      await tester.pumpAndSettle();

      expect(container.read(playbackHistoryProvider), PlaybackHistory.empty);
    });
  });
}
