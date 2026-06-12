import '../models/track.dart';
import 'server_playback_reporter.dart';

/// Routes each playback report to the first reporter that [handles] the
/// track's uri — the reporting counterpart of `RoutingPlayableUriResolver`.
///
/// A track no reporter handles is silently dropped: not reporting *is* the
/// correct behaviour for providers without reporting support (local files
/// today), and the only reporter that sees a track is the one that claimed it
/// — so one provider's playback can never trigger another provider's report.
///
/// [onTrackChanged] is the one event that can span two providers (a Plex track
/// followed by a Jellyfin one): it is forwarded to the reporter owning each
/// side — once when both sides route to the same reporter — so the outgoing
/// provider can close its session no matter what plays next.
class RoutingServerPlaybackReporter implements ServerPlaybackReporter {
  const RoutingServerPlaybackReporter(this._reporters);

  /// Candidate reporters, most specific first.
  final List<ServerPlaybackReporter> _reporters;

  @override
  bool handles(Track track) => true;

  ServerPlaybackReporter? _reporterFor(Track? track) {
    if (track == null) return null;
    for (final ServerPlaybackReporter reporter in _reporters) {
      if (reporter.handles(track)) return reporter;
    }
    return null;
  }

  @override
  Future<void> onPlaybackStarted(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    await _reporterFor(track)?.onPlaybackStarted(track, position, duration);
  }

  @override
  Future<void> onPlaybackProgress(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    await _reporterFor(track)?.onPlaybackProgress(track, position, duration);
  }

  @override
  Future<void> onPlaybackPaused(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    await _reporterFor(track)?.onPlaybackPaused(track, position, duration);
  }

  @override
  Future<void> onPlaybackResumed(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    await _reporterFor(track)?.onPlaybackResumed(track, position, duration);
  }

  @override
  Future<void> onPlaybackStopped(
    Track track,
    Duration position,
    Duration duration,
  ) async {
    await _reporterFor(track)?.onPlaybackStopped(track, position, duration);
  }

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {
    final ServerPlaybackReporter? previous = _reporterFor(previousTrack);
    final ServerPlaybackReporter? next = _reporterFor(nextTrack);
    if (previous != null) {
      await previous.onTrackChanged(previousTrack, nextTrack);
    }
    if (next != null && !identical(next, previous)) {
      await next.onTrackChanged(previousTrack, nextTrack);
    }
  }
}
