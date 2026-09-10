import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playback_history.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_controller.dart';
import '../../core/services/playback_history_recorder.dart';
import '../../data/repositories/host_platform_provider.dart';
import 'player_providers.dart';

/// Holds the session's bounded recent-playback history.
///
/// Filled by a [PlaybackHistoryRecorder] that watches the controller's state
/// stream; see that class for how completed and skipped are told apart. The
/// notifier owns exactly one recorder and disposes it with itself, so a
/// provider rebuild can never leave two listeners recording the same track
/// twice.
class PlaybackHistoryController extends Notifier<PlaybackHistory> {
  @override
  PlaybackHistory build() {
    // Desktop only. History is a desktop queue-pane feature (#419): Android's
    // queue keeps exactly the semantics it had, and a recorder that never runs
    // there cannot change them. Off desktop this stays the empty history and
    // costs one provider read.
    if (!ref.watch(hostPlatformProvider).isDesktop) {
      return PlaybackHistory.empty;
    }

    final PlaybackHistoryRecorder recorder = PlaybackHistoryRecorder(
      states: ref.read(playbackControllerProvider).stateStream,
      onPlayed: record,
    );
    recorder.start();
    ref.onDispose(recorder.dispose);
    return PlaybackHistory.empty;
  }

  /// Records [track] as recently played. Public so a test (and the recorder)
  /// can drive it directly; the bounding, de-duplication and logical-identity
  /// guard all live in [PlaybackHistory.record].
  void record(Track track, PlaybackHistoryOutcome outcome, DateTime at) {
    final PlaybackHistory next = state.record(track, outcome: outcome, at: at);
    if (next != state) state = next;
  }

  /// Empties the history. Wired to the queue pane's Clear, which has always
  /// meant "drop what is behind and ahead, keep what is playing".
  void clear() {
    final PlaybackHistory next = state.cleared();
    if (next != state) state = next;
  }
}

/// The session's recent-playback history. Empty off desktop.
final playbackHistoryProvider =
    NotifierProvider<PlaybackHistoryController, PlaybackHistory>(
  PlaybackHistoryController.new,
);

/// Plays a track the listener picked out of the recent-playback history.
///
/// Two routes, and which one is taken is the whole point:
///
///  * the track is still in the **current queue's** history → step back to it
///    with [PlaybackController.playFromHistory], exactly what tapping a
///    "previously played" row has always done. Up-next is preserved, the queue
///    is not rebuilt, and nothing about queue behaviour changes.
///  * otherwise (it came from an earlier queue) → [PlaybackController.playTrack],
///    the ordinary play path.
///
/// Either way the source is resolved fresh through the normal resolver and its
/// fallbacks — the history holds a catalog [Track] and nothing else, so there
/// is no stale stream URL to reuse even in principle.
Future<void> playFromRecentHistory(WidgetRef ref, Track track) {
  final PlaybackController controller = ref.read(playbackControllerProvider);
  final PlaybackState state = controller.state;
  final int inQueue =
      state.previous.indexWhere((Track queued) => queued.uri == track.uri);
  if (inQueue >= 0) return controller.playFromHistory(inQueue);
  return controller.playTrack(track);
}
