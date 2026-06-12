import '../models/track.dart';

/// Reports playback lifecycle events for a [Track] back to the server that
/// owns it, so the user's own media server can show the app as an active
/// player (e.g. Plex's Now Playing dashboard) and keep its play state in sync.
///
/// This is the provider-neutral seam: the playback layer emits the events and
/// never knows *how* (or whether) a provider reports them — a routing
/// implementation selects the reporter that [handles] the track, and providers
/// without reporting support fall through to [NoOpServerPlaybackReporter].
///
/// Contract for implementations:
///  - **Best-effort, never fatal.** Reporting must never throw out of these
///    methods and must never stall, stop, or alter playback. A failed report is
///    silently dropped (at most a secret-free debug breadcrumb).
///  - **Secret-free.** No credential — token, password, authenticated URL —
///    may reach a log, an error, or any other output on any reporting path.
///  - **Stateless inputs.** Events carry only the catalog [Track] (opaque,
///    credential-free uri) plus the playback [position] and [duration]; an
///    implementation minting a server call weaves credentials in on demand and
///    discards them, exactly like stream-URL resolution.
abstract interface class ServerPlaybackReporter {
  /// Whether this reporter knows how to report playback of [track] (decided
  /// from its opaque uri scheme, like `PlayableUriResolver.handles`).
  bool handles(Track track);

  /// A track started playing (a fresh start — not a resume after pause).
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration);

  /// Periodic progress while playing. Callers throttle this to a calm cadence;
  /// implementations may assume it is *not* called for every position tick.
  Future<void> onPlaybackProgress(
      Track track, Duration position, Duration duration);

  /// Playback was paused at [position].
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration);

  /// Playback resumed from a pause at [position].
  Future<void> onPlaybackResumed(
      Track track, Duration position, Duration duration);

  /// Playback stopped (user stop, queue ran out, or a playback error ended
  /// it). The server should clear/settle its active session for [track].
  Future<void> onPlaybackStopped(
      Track track, Duration position, Duration duration);

  /// The queue moved from [previousTrack] to [nextTrack] (either may be null
  /// at the edges of a queue). Reporters owning [previousTrack] should close
  /// its session; [nextTrack]'s own start is reported separately via
  /// [onPlaybackStarted] once it is actually playing.
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack);
}

/// The reporter for providers without server-side playback reporting (local
/// files today, and any remote provider until its reporting path lands):
/// accepts every track and reports nothing, so the playback layer never has to
/// special-case "this source doesn't report".
class NoOpServerPlaybackReporter implements ServerPlaybackReporter {
  const NoOpServerPlaybackReporter();

  @override
  bool handles(Track track) => true;

  @override
  Future<void> onPlaybackStarted(
      Track track, Duration position, Duration duration) async {}

  @override
  Future<void> onPlaybackProgress(
      Track track, Duration position, Duration duration) async {}

  @override
  Future<void> onPlaybackPaused(
      Track track, Duration position, Duration duration) async {}

  @override
  Future<void> onPlaybackResumed(
      Track track, Duration position, Duration duration) async {}

  @override
  Future<void> onPlaybackStopped(
      Track track, Duration position, Duration duration) async {}

  @override
  Future<void> onTrackChanged(Track? previousTrack, Track? nextTrack) async {}
}
