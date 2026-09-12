import 'dart:async';

import '../../models/playback_state.dart';
import '../../models/track.dart';
import 'desktop_notifier.dart';

/// Turns a track into the notification that announces it. Injected so the
/// content rules (and the artwork filter behind them) stay in
/// `now_playing_notification.dart` and this class stays about *when* to notify.
typedef DesktopNotificationBuilder = DesktopNotification Function(Track track);

/// Watches the playback state stream and announces the track that is actually
/// playing now (issue #400).
///
/// A pure observer, the same shape as `PlaybackHistoryRecorder`: it never
/// touches the queue, the controller or the audio engine, and it emits nothing
/// back into playback. Switching it off (which is what the preference does)
/// changes nothing except whether a toast appears.
///
/// **Why the state stream.** A track change is not an event the controller
/// raises; it is a state. Reading the stream sees a skip, a natural advance and
/// a queue jump identically, for every controller implementation, without the
/// playback seam growing a callback for the benefit of a desktop toast.
///
/// **What counts as a track change.** The stream carries a state several times
/// a second while playing, and almost none of those are news. Three rules
/// between them reduce it to real transitions:
///
///  * the track's logical identity ([Track.uri]) has to differ from the last
///    one announced, so position ticks, a pause, a resume, a volume change, a
///    seek, a reconnect and a queue rebuild all say nothing. Repeat-one, which
///    starts the *same* song again, is deliberately included in that: it is
///    not a new song;
///  * something has to actually be playing. A queue restored paused at launch,
///    a track loaded but not started, and a load that errored are all "nothing
///    is playing", and announcing one would be a claim Linthra cannot back;
///  * at most one notification per [minInterval]. Holding the button down
///    through twenty tracks must not put twenty notifications on the bus. See
///    below for why the last one still wins.
///
/// **Rapid skipping.** A burst is coalesced rather than dropped: the newest
/// eligible track replaces whatever was waiting, one timer covers the whole
/// burst, and when it fires the track the listener actually landed on is the
/// one announced. Dropping instead would either announce the first track of a
/// burst (the one they skipped away from) or nothing at all.
///
/// **Failure.** Every delivery is guarded and unawaited. A missing daemon, a
/// refused call or a bus that went away costs one absent toast and nothing
/// else; playback never waits for a notification and never sees it fail.
class TrackChangeNotifier {
  TrackChangeNotifier({
    required Stream<PlaybackState> states,
    required DesktopNotifier notifier,
    required bool Function() enabled,
    required DesktopNotificationBuilder build,
    Duration minInterval = defaultMinInterval,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
  })  : _states = states,
        _notifier = notifier,
        _enabled = enabled,
        _build = build,
        _minInterval = minInterval,
        _now = now ?? DateTime.now,
        _createTimer = createTimer ?? _scheduleTimer;

  /// The shortest gap between two notifications.
  ///
  /// Long enough that a listener stepping through a few tracks produces one
  /// notification rather than one per track; short enough that ordinary
  /// listening, where a track change is minutes apart, is never delayed by
  /// it at all.
  static const Duration defaultMinInterval = Duration(seconds: 5);

  final Stream<PlaybackState> _states;
  final DesktopNotifier _notifier;

  /// Read live, on every candidate, so turning the preference off silences the
  /// next track change (and a burst still waiting on its timer) at once.
  final bool Function() _enabled;

  final DesktopNotificationBuilder _build;
  final Duration _minInterval;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _createTimer;

  StreamSubscription<PlaybackState>? _subscription;

  /// The identity of the track the listener has already been told about.
  ///
  /// Updated even while the preference is off, so switching notifications on
  /// mid-track stays quiet until the *next* real change instead of announcing
  /// a song that has been playing for two minutes.
  String? _announced;

  /// When the last notification was handed to the notifier.
  DateTime? _lastAt;

  /// The newest eligible track seen inside the rate-limit window.
  Track? _pending;
  Timer? _timer;

  static Timer _scheduleTimer(Duration delay, void Function() callback) =>
      Timer(delay, callback);

  /// Begins observing. Idempotent: calling it twice never adds a second
  /// listener, which is what keeps one track change from notifying twice.
  void start() {
    _subscription ??= _states.listen(onState);
  }

  /// Feeds one state in. Public so the transition and rate-limit rules can be
  /// exercised without a stream, and used by [start] as the listener.
  void onState(PlaybackState state) {
    // Nothing to talk to (every platform but Linux): no state to keep either.
    if (!_notifier.isSupported) return;

    final Track? track = state.currentTrack;
    if (track == null) return;
    if (!_isPlayingSomething(state)) return;
    if (track.uri == _announced) return;

    if (!_enabled()) {
      _announced = track.uri;
      return;
    }

    final DateTime at = _now();
    final DateTime? last = _lastAt;
    final Duration since = last == null ? _minInterval : at.difference(last);
    if (since >= _minInterval) {
      _announce(track, at);
      return;
    }

    // Inside the window. Remember the newest track and let the one armed timer
    // announce whatever is newest when the window closes.
    _pending = track;
    _timer ??= _createTimer(_minInterval - since, _announcePending);
  }

  /// Whether [state] is a claim that audio is on this track.
  ///
  /// Buffering and reconnecting count: both mean the engine is working toward
  /// sound on the current track, and both are what `PlaybackStatus` reports
  /// mid-stream rather than a reason to stay silent. Loading, paused, idle,
  /// completed and error do not.
  static bool _isPlayingSomething(PlaybackState state) =>
      state.isPlaying || state.isBuffering;

  void _announce(Track track, DateTime at) {
    _announced = track.uri;
    _lastAt = at;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    unawaited(_deliver(track));
  }

  /// Announces whatever the burst landed on, if it is still worth announcing.
  void _announcePending() {
    _timer = null;
    final Track? track = _pending;
    _pending = null;
    if (track == null) return;
    // Turned off, or already announced by something else, while the window ran.
    if (!_enabled() || track.uri == _announced) return;
    _announce(track, _now());
  }

  Future<void> _deliver(Track track) async {
    try {
      await _notifier.show(_build(track));
    } catch (_) {
      // Best-effort by contract. A notification backend that throws (a daemon
      // that vanished, a bus that refused the call) must never surface as an
      // unhandled error on the playback stream's listener.
    }
  }

  /// Stops observing and drops a pending announcement. Idempotent.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    final StreamSubscription<PlaybackState>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
