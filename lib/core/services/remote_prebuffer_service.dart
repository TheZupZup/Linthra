import 'dart:async';

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'playback_lookahead.dart';
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
/// A warmed URL only stays fresh for a couple of minutes, and most songs are
/// longer than that, so the next track is warmed once more as the current one
/// nears its end ([refreshLead]). Without it, the warm made when a track
/// started had usually expired by the time the track ended, and the natural
/// roll into the next one paid the full session check and probe after all.
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
    this.refreshLead = defaultRefreshLead,
  })  : _prebufferer = prebufferer,
        _ahead = ahead {
    _subscription = playbackStates.listen(_onState);
  }

  /// How close to the end of the current track the next one is warmed again.
  ///
  /// Far enough ahead for a slow resolve to finish before the change, close
  /// enough that the URL is still fresh at it. It costs a request only when
  /// the earlier warm has gone stale, and it is the request the change would
  /// have made anyway, made earlier.
  static const Duration defaultRefreshLead = Duration(seconds: 30);

  final Duration refreshLead;

  final RemoteStreamPrebufferer _prebufferer;
  final int _ahead;
  late final StreamSubscription<PlaybackState> _subscription;

  /// The last set of inputs we prepared against, so pure position/status ticks
  /// don't re-trigger a pass.
  PlaybackState? _lastInputs;
  PlaybackState? _pending;

  /// The tracks to warm again near the end of the current one, and how long
  /// until it ends.
  ({List<Track> tracks, Duration remaining})? _pendingRefresh;

  /// Whether reaching the last [refreshLead] of the track warms the next one
  /// again. Spent when it does; re-armed when playback leaves that stretch
  /// (a pause, a seek back) or moves to another track, since the warm may have
  /// gone stale again by the time it gets back there.
  bool _refreshArmed = true;
  bool _running = false;

  void _onState(PlaybackState state) {
    // Only the inputs that decide what to prepare count: the playing track,
    // shuffle, repeat, and the head of up-next this service warms. A position
    // tick moves none of them and costs a few reference checks here (see
    // [samePlaybackLookahead]), plus the end-of-track check below.
    if (samePlaybackLookahead(state, _lastInputs, ahead: _ahead)) {
      _refreshNearEnd(state);
      return;
    }
    _lastInputs = state;
    _refreshArmed = true;
    if (state.currentTrack == null) return;
    _pending = state;
    unawaited(_drain());
  }

  /// Warms the track after this one again once the current track is playing
  /// within [refreshLead] of its end.
  void _refreshNearEnd(PlaybackState state) {
    final bool nearEnd = state.status == PlaybackStatus.playing &&
        state.duration > Duration.zero &&
        state.duration - state.position <= refreshLead;
    if (!nearEnd) {
      _refreshArmed = true;
      return;
    }
    if (!_refreshArmed) return;
    _refreshArmed = false;
    // What the controller plays next: the wrap to the top under repeat-all,
    // nothing under repeat-one.
    final List<Track> next = upcomingTracks(state, count: _ahead);
    if (next.isEmpty) return;
    _pendingRefresh = (
      tracks: next,
      remaining: state.duration - state.position,
    );
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null || _pendingRefresh != null) {
        final PlaybackState? state = _pending;
        _pending = null;
        if (state == null) {
          final ({List<Track> tracks, Duration remaining}) refresh =
              _pendingRefresh!;
          _pendingRefresh = null;
          // A warm that stays fresh past the end of this track is kept, so
          // this only reaches the server for one that has gone stale or would
          // before the change.
          await _prebufferer.prepare(
            upNext: refresh.tracks,
            ahead: refresh.tracks.length,
            keepFreshFor: refresh.remaining,
          );
          continue;
        }
        // The track changed or the queue moved: this pass warms what plays
        // next now, which supersedes a refresh still waiting.
        _pendingRefresh = null;
        // Repeat-one replays the current track, so the up-next won't play soon:
        // prepare only the current track (a cheap no-op once it is warm) and
        // skip warming unrelated up-next entries.
        final List<Track> upNext =
            state.repeatMode == RepeatMode.one ? const <Track>[] : state.upNext;
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
