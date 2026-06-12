import 'dart:async';

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'remote_cache/remote_stream_prebufferer.dart';

/// Drives the [RemoteStreamPrebufferer] from live playback: as the queue moves,
/// it prepares the **current** remote track and the next item(s) ahead of the
/// transition, so a skip — or the natural roll into the next track — starts
/// faster instead of re-running the session check + URL mint at the track
/// change.
///
/// It listens to the unified [PlaybackState] and reacts only when something that
/// affects *what plays next* changes — not on every position tick. It is the
/// aggressive successor to warming only the immediate next track: warming the
/// current track too covers a resume/retry on a flaky connection, and [ahead]
/// can warm more than one upcoming item.
///
/// What it deliberately does NOT do:
///  - **Repeat-one stays calm.** The current track loops, so the up-next won't
///    play soon — only the current track is (cheaply, usually no-op) prepared.
///  - **No disk, no downloads.** Preparing only warms an in-memory URL via the
///    prebufferer; it never writes the offline cache (that is smart pre-cache's
///    job) and a local/non-remote track is a no-op.
///  - **Best-effort, never blocking.** Warms run off the playback path, one pass
///    at a time, and any failure is swallowed — a slow or failing warm never
///    stalls or restarts the current track.
class RemotePrebufferService {
  RemotePrebufferService({
    required Stream<PlaybackState> playbackStates,
    required RemoteStreamPrebufferer prebufferer,
    int ahead = 1,
  })  : _prebufferer = prebufferer,
        _ahead = ahead {
    _subscription = playbackStates.listen(_onState);
  }

  final RemoteStreamPrebufferer _prebufferer;
  final int _ahead;
  late final StreamSubscription<PlaybackState> _subscription;

  /// The last set of inputs we prepared against, so pure position/status ticks
  /// don't re-trigger a pass.
  String? _lastKey;
  PlaybackState? _pending;
  bool _running = false;

  void _onState(PlaybackState state) {
    final String key = _keyFor(state);
    if (key == _lastKey) return;
    _lastKey = key;
    if (state.currentTrack == null) return;
    _pending = state;
    unawaited(_drain());
  }

  /// A fingerprint of the inputs that decide what to prepare: the playing track,
  /// shuffle, repeat, and the head of up-next we warm. Excludes
  /// position/duration/status so listening doesn't thrash on playback ticks.
  String _keyFor(PlaybackState state) {
    final StringBuffer buffer = StringBuffer()
      ..write(state.currentTrack?.id ?? '-')
      ..write('|')
      ..write(state.shuffleEnabled)
      ..write('|')
      ..write(state.repeatMode.name)
      ..write('|');
    final int count =
        _ahead < state.upNext.length ? _ahead : state.upNext.length;
    for (int i = 0; i < count; i++) {
      buffer
        ..write(state.upNext[i].id)
        ..write(',');
    }
    return buffer.toString();
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final PlaybackState state = _pending!;
        _pending = null;
        // Repeat-one replays the current track, so the up-next won't play soon:
        // prepare only the current track (a cheap no-op once it is warm) and
        // skip warming unrelated up-next entries.
        final List<Track> upNext = state.repeatMode == RepeatMode.one
            ? const <Track>[]
            : state.upNext;
        await _prebufferer.prepare(
          current: state.currentTrack,
          upNext: upNext,
          ahead: _ahead,
        );
      }
    } finally {
      _running = false;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
