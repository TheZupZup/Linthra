import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playback_queue.dart';
import '../models/playback_source.dart';
import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/replay_gain.dart';
import '../models/track.dart';
import 'local_playable_uri_resolver.dart';
import 'local_playback_controller.dart';
import 'playable_uri_resolver.dart';
import 'playback_candidate_source.dart';
import 'playback_controller.dart';
import 'stability_diagnostics.dart';
import 'stream_interruption.dart';

/// Notified when a track finishes playing (reaches its natural end), so play
/// history can be recorded. Carries only the catalog [Track] — never a resolved
/// or authenticated stream URL.
typedef TrackCompletionCallback = void Function(Track track);

/// [PlaybackController] backed by `just_audio`.
///
/// This is the only file in the app that knows `just_audio` exists. It adapts
/// the player's separate event streams (state, position, duration) into the
/// single immutable [PlaybackState] the UI renders from. Swapping the engine or
/// wrapping it for background playback later means replacing this class, not
/// the feature code.
///
/// It opens whatever URI a [PlayableUriResolver] returns rather than assuming a
/// local file path, so local files, Android SAF content URIs, and remote
/// (Jellyfin) streams all play through the same path. The default resolver
/// handles only on-device tracks; remote resolution is composed in at the
/// provider layer, keeping this class free of any source-specific knowledge.
class JustAudioPlaybackController implements LocalPlaybackController {
  JustAudioPlaybackController({
    AudioPlayer? player,
    PlayableUriResolver resolver = const LocalPlayableUriResolver(),
    PlaybackCandidateSource candidates = const NoFallbackCandidateSource(),
    Random? random,
    TrackCompletionCallback? onTrackCompleted,
  })  : _player = player ?? _defaultPlayer(),
        _resolver = resolver,
        _candidates = candidates,
        _random = random ?? Random(),
        _onTrackCompleted = onTrackCompleted,
        // Own audio focus only for the engine we created. An injected player
        // (tests, or a future custom engine) keeps whatever interruption
        // handling its owner configured, so unit tests never touch the
        // audio_session platform.
        _manageAudioFocus = player == null {
    _wire();
  }

  /// The default engine, tuned for resilient remote streaming. An injected
  /// [player] (tests, or a future custom engine) bypasses this.
  ///
  /// `handleInterruptions: false` deliberately turns *off* just_audio's built-in
  /// audio-focus handling. That handler pauses on a focus loss but then calls
  /// `play()` again on focus *regain* — so after a transient interruption (a
  /// notification, another app briefly taking focus, or the focus churn some
  /// OEMs emit on screen on/off and around battery-saver/Doze) the engine
  /// resumes on its own, underneath the controller and media session. That is
  /// the "music starts/resumes by itself when the screen turns on / when I
  /// switch apps" regression. [_wireAudioFocus] takes over: it pauses on a real
  /// focus loss and *never* auto-resumes — only an explicit user / media-session
  /// play resumes.
  static AudioPlayer _defaultPlayer() => AudioPlayer(
        audioLoadConfiguration: _streamBuffering,
        handleInterruptions: false,
      );

  /// Buffering tuned for remote streams so a brief network hiccup is absorbed
  /// instead of stalling playback: a generous look-ahead (up to ~2 minutes), a
  /// healthy minimum to resume on after a stall, and a quick initial start.
  /// Applied to the default engine only — an injected player (tests, or a future
  /// custom engine) is left untouched. just_audio exposes ExoPlayer's
  /// `LoadControl` here; there is no lower-level per-request buffer-size knob, so
  /// resilience also comes from the retry/recovery and preload paths.
  static const AudioLoadConfiguration _streamBuffering = AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      minBufferDuration: Duration(seconds: 30),
      maxBufferDuration: Duration(minutes: 2),
      bufferForPlaybackDuration: Duration(seconds: 2),
      bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
      prioritizeTimeOverSizeThresholds: true,
    ),
    darwinLoadControl: DarwinLoadControl(
      automaticallyWaitsToMinimizeStalling: true,
      preferredForwardBufferDuration: Duration(minutes: 1),
    ),
  );

  /// One bounded retry per track for a mid-stream failure, so a transient drop
  /// recovers without ever looping forever on a real outage/expiry.
  static const int _maxStreamRetries = 1;

  final AudioPlayer _player;
  final PlayableUriResolver _resolver;

  /// Supplies the ordered source candidates for the track being played, so a
  /// failed preferred copy can fall back to another copy of the same song. The
  /// default returns just the track itself (no fallback), so single-source
  /// playback is unchanged.
  final PlaybackCandidateSource _candidates;
  final Random _random;

  /// Invoked once each time a track reaches its natural end, before the repeat
  /// mode decides what plays next. Null when no listener is wired (tests, or the
  /// default engine). Used to record play history.
  final TrackCompletionCallback? _onTrackCompleted;
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<void>> _subscriptions =
      <StreamSubscription<void>>[];

  /// Whether this controller owns audio-focus handling for its engine (true only
  /// for the default engine it created; an injected player is left to its owner).
  final bool _manageAudioFocus;

  /// The audio-session subscriptions, kept so [dispose] can cancel them. Null
  /// until [_wireAudioFocus] attaches (real Android/iOS device only).
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;

  PlaybackState _state = PlaybackState.idle;
  PlaybackQueue _queue = PlaybackQueue.empty;

  // When true a cast receiver is the active output, so queue changes update the
  // current track/up-next but never load or play through the engine. Set/cleared
  // by [suspend]/[resume], driven by the ActivePlaybackController.
  bool _suspended = false;

  // Shuffle and repeat are session-wide playback modes owned here (not by the
  // engine, which only ever has one source loaded at a time). They persist
  // across track changes and are mirrored onto every emitted state.
  bool _shuffleEnabled = false;
  RepeatMode _repeatMode = RepeatMode.off;

  // Whether ReplayGain volume normalization is applied. Off by default so audio
  // is never altered until the listener opts in. Mirrored onto the engine's
  // volume whenever a track loads (and immediately when toggled).
  bool _normalizeVolume = false;

  // How many times the current track has been retried after a mid-stream
  // failure. Reset when a fresh track loads and when playback reaches `playing`,
  // so each track (and each successful stretch) gets its own one-retry budget.
  int _retriesForCurrent = 0;

  // The latest engine position awaiting a coalesced flush, and the timer that
  // flushes it. The engine's positionStream can fire several times a second
  // (more in bursts during seeking/buffering); emitting a new state for every
  // raw tick floods the unified stream — and the UI, media session, and
  // pre-cache services hanging off it. These coalesce position onto a steady
  // cadence; status/duration/track changes still emit immediately.
  Duration? _pendingPosition;
  Timer? _positionFlush;
  static const Duration _positionFlushInterval = Duration(milliseconds: 250);

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  void _wire() {
    _subscriptions.add(_player.playerStateStream.listen(
      handleEngineState,
      onError: (Object _, StackTrace __) {
        // Engine errors are recovered via [playbackEventStream] below; swallow
        // any duplicate that the player-state stream may forward so it never
        // becomes an unhandled async error (and so we never act on it twice).
      },
    ));
    _subscriptions.add(_player.positionStream.listen((position) {
      if (_suspended) return;
      // Coalesce raw position ticks onto a steady ~4 Hz flush so a high (or
      // bursty) engine tick rate can never flood the state stream with rebuilds.
      _pendingPosition = position;
      _positionFlush ??=
          Timer.periodic(_positionFlushInterval, (_) => _flushPosition());
    }));
    _subscriptions.add(_player.durationStream.listen((duration) {
      if (_suspended) return;
      if (duration != null) _emit(_state.copyWith(duration: duration));
    }));
    // A mid-stream failure (network drop, expired token, server gone) surfaces
    // here as a stream error. Recover gracefully rather than dying silently.
    _subscriptions.add(
      _player.playbackEventStream.listen((_) {}, onError: _onEngineError),
    );
    _wireAudioFocus();
  }

  /// Takes over audio-focus handling from just_audio (disabled via
  /// `handleInterruptions: false`) so playback never auto-resumes itself.
  ///
  /// Best-effort and platform-gated: only the engine we created manages focus,
  /// and only on a real Android/iOS device — a test host or desktop has no
  /// audio_session platform, so it stays inert (and unit tests never touch the
  /// platform channel). The pause-or-not decision is the pure
  /// [shouldPauseForInterruption]; the loud-output guard is [_onBecomingNoisy].
  void _wireAudioFocus() {
    if (!_manageAudioFocus) return;
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    unawaited(_attachAudioSession());
  }

  Future<void> _attachAudioSession() async {
    try {
      final AudioSession session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _interruptionSub =
          session.interruptionEventStream.listen(_onAudioInterruption);
      _becomingNoisySub =
          session.becomingNoisyEventStream.listen((_) => _onBecomingNoisy());
    } catch (_) {
      // No audio_session platform here: skip focus management entirely. Playback
      // still works; we simply don't pause on a focus loss on this host.
    }
  }

  /// Reacts to an audio-focus [event] for the on-device engine.
  ///
  /// While suspended a cast receiver owns the audio and the engine is parked, so
  /// a local focus change is ignored. Otherwise a real focus loss pauses and a
  /// focus *regain* does nothing — see [shouldPauseForInterruption].
  void _onAudioInterruption(AudioInterruptionEvent event) {
    if (_suspended) return;
    if (shouldPauseForInterruption(event)) unawaited(pause());
  }

  /// Whether an audio-focus [event] should pause the on-device engine.
  ///
  /// The whole point of owning focus ourselves: playback must NEVER resume by
  /// itself. So this pauses on a genuine focus *loss* (another app took focus, a
  /// call, an alarm) and returns `false` for every focus *regain*
  /// (`event.begin == false`) — only an explicit user / media-session play
  /// resumes. A transient duck (a brief system sound) is left to ride at full
  /// volume rather than pausing; just_audio is no longer adjusting it, and a
  /// momentary overlap is preferable to a surprise pause/!resume.
  @visibleForTesting
  static bool shouldPauseForInterruption(AudioInterruptionEvent event) {
    // Focus regained / interruption ended: do nothing. This is the exact point
    // just_audio's built-in handler called play() — the auto-resume we remove.
    if (!event.begin) return false;
    switch (event.type) {
      case AudioInterruptionType.duck:
        return false;
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        return true;
    }
  }

  /// Headphones unplugged / the output became the phone speaker: pause so audio
  /// doesn't suddenly blast out loud. Never auto-resumes when they're plugged
  /// back in — consistent with the no-surprise-resume rule.
  void _onBecomingNoisy() {
    if (_suspended) return;
    unawaited(pause());
  }

  /// Maps one raw engine [PlayerState] onto the unified [PlaybackState] and
  /// emits it. The [_wire] player-state subscription forwards every event here;
  /// it is exposed for tests so the screen-off transient-idle guard below can be
  /// exercised without a platform channel.
  @visibleForTesting
  void handleEngineState(PlayerState playerState) {
    // While suspended a cast receiver owns playback; ignore the (paused) local
    // engine's events entirely, so it can never auto-advance or report stale
    // status underneath the cast session.
    if (_suspended) return;
    final status = _statusFor(playerState);
    // just_audio pushes a fresh, default PlaybackEvent — whose processingState
    // is `idle` — synchronously at the *start* of every setAudioSource/setUrl
    // call, before the new source begins loading. That happens on every track
    // transition and every mid-stream retry reload, while `playing` is still
    // true. Forwarding that idle would make the media session report
    // `playing: false` + `idle` mid-transition, demoting audio_service's
    // foreground media service (and dropping the CPU/Wi-Fi wake locks it holds)
    // at the exact moment a new track loads with the screen off — letting the
    // OS freeze the backgrounded process so audio only resumes when the app is
    // reopened (the screen-off cutout bug). The controller is the sole
    // authority on going idle: it starts idle and emits its own idle from
    // stop(), so a raw engine idle is never needed here — drop it so a reload
    // can never demote the service. Buffering/loading still flow through (they
    // map to a still-`playing` session) and a real pause/completion/error is
    // unaffected.
    if (status == PlaybackStatus.idle) return;
    // Playback is healthy again: give a later, independent drop a fresh retry.
    if (status == PlaybackStatus.playing) _retriesForCurrent = 0;
    // When a track finishes, what happens next depends on the repeat mode.
    if (status == PlaybackStatus.completed) {
      _onCompleted();
      return;
    }
    _emit(_state.copyWith(status: status));
  }

  /// Recovers from an engine error that happens **while streaming**. A transient
  /// drop gets one bounded retry that re-resolves and reloads at the preserved
  /// position; an auth/format failure (or an exhausted retry) shows a friendly,
  /// secret-free message. The raw [error] (which can carry a tokenized URL) is
  /// never logged or surfaced — only its classification is used.
  void _onEngineError(Object error, StackTrace _) {
    // A cast receiver owns the audio while suspended: never touch local
    // playback, so a local engine glitch can't pull output back from the
    // receiver or start duplicate audio.
    if (_suspended) return;
    // Only recover from a failure that happens once we're actually streaming; an
    // initial-load failure is handled where setUrl is awaited (with its own
    // friendly message), so we don't fight it here.
    if (_state.status != PlaybackStatus.playing &&
        _state.status != PlaybackStatus.buffering) {
      return;
    }
    final Track? track = _queue.current;
    if (track == null) return;

    final StreamInterruption interruption = classifyEngineError(error);
    // Secret-free breadcrumb: only the classified *kind*, never the raw error
    // (which can echo a tokenized stream URL).
    StabilityDiagnostics.playbackError(interruption.kind.name);
    if (interruption.retryable && _retriesForCurrent < _maxStreamRetries) {
      _retriesForCurrent++;
      // Re-resolve and reload at the preserved position. The resolver re-checks
      // the session/server, so a real expiry/outage surfaces a precise friendly
      // error while a transient blip simply recovers. setUrl replaces the
      // source, so there is no duplicate playback and no jump to the start.
      unawaited(_playCurrent(startAt: _state.position, isRetry: true));
      return;
    }
    _emitError(track, interruption.message);
  }

  /// Maps the engine's (playing, processingState) pair to a [PlaybackStatus].
  ///
  /// The key distinction: `buffering` *while the engine wants to play* is a
  /// mid-stream re-buffer ([PlaybackStatus.buffering] — a calm "Buffering…"
  /// hint, not a frozen player), whereas `loading`, or buffering *before* the
  /// first play, is still the initial preparing state ([PlaybackStatus.loading]).
  @visibleForTesting
  static PlaybackStatus statusFor(PlayerState playerState) =>
      _statusFor(playerState);

  static PlaybackStatus _statusFor(PlayerState playerState) {
    switch (playerState.processingState) {
      case ProcessingState.idle:
        return PlaybackStatus.idle;
      case ProcessingState.loading:
        return PlaybackStatus.loading;
      case ProcessingState.buffering:
        return playerState.playing
            ? PlaybackStatus.buffering
            : PlaybackStatus.loading;
      case ProcessingState.ready:
        return playerState.playing
            ? PlaybackStatus.playing
            : PlaybackStatus.paused;
      case ProcessingState.completed:
        return PlaybackStatus.completed;
    }
  }

  void _emit(PlaybackState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// Emits the latest coalesced position. When nothing new has arrived since the
  /// last flush (paused/stopped), it stops the timer so it never ticks idly; the
  /// next position event restarts it.
  void _flushPosition() {
    final Duration? position = _pendingPosition;
    _pendingPosition = null;
    if (position == null) {
      _positionFlush?.cancel();
      _positionFlush = null;
      return;
    }
    if (_suspended) return;
    _emit(_state.copyWith(position: position));
  }

  /// Drops any pending position and stops the flush timer, so a stale tick from
  /// the previous source can't flush onto a freshly established state (a new
  /// track loading, stop, or a cast handoff).
  void _resetPositionFlush() {
    _pendingPosition = null;
    _positionFlush?.cancel();
    _positionFlush = null;
  }

  @override
  Future<void> playTrack(Track track) => playTracks(<Track>[track]);

  @override
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) {
    var queue = PlaybackQueue.of(tracks, startIndex: startIndex);
    // Shuffle is a persistent mode: a queue loaded while it's on starts
    // shuffled, with the chosen track kept as the one that plays first.
    if (_shuffleEnabled) queue = queue.shuffled(_random);
    _queue = queue;
    return _playCurrent();
  }

  @override
  void playNext(Track track) {
    final bool wasEmpty = _queue.current == null;
    _queue = _queue.enqueueNext(track);
    if (wasEmpty) {
      // Nothing was playing: "play next" has nothing to play after, so start
      // the track now rather than silently leaving it queued.
      unawaited(_playCurrent());
      return;
    }
    // The current track keeps playing; only the up-next list changes.
    _emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  void addToQueue(Track track) {
    final bool wasEmpty = _queue.current == null;
    _queue = _queue.appended(track);
    if (wasEmpty) {
      // An empty queue has nothing playing to append behind: start the track.
      unawaited(_playCurrent());
      return;
    }
    // The current track keeps playing; only the up-next list grows.
    _emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  void removeFromQueue(int upNextIndex) {
    final updated = _queue.removeUpNextAt(upNextIndex);
    if (identical(updated, _queue)) return; // out of range: nothing to do
    _queue = updated;
    // Only the up-next list shrank; the current track and its audio are
    // untouched — no reload, no restart.
    _emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  void reorderQueue(int oldIndex, int newIndex) {
    final updated = _queue.reorderUpNext(oldIndex, newIndex);
    if (identical(updated, _queue)) return;
    _queue = updated;
    // The current track keeps playing; only the order of what follows changes.
    _emit(_state.copyWith(upNext: _queue.upNext));
  }

  @override
  Future<void> playFromQueue(int upNextIndex) async {
    final jumped = _queue.jumpToUpNext(upNextIndex);
    if (identical(jumped, _queue)) return;
    _queue = jumped;
    await _playCurrent();
  }

  @override
  Future<void> playFromHistory(int previousIndex) async {
    final jumped = _queue.jumpToHistory(previousIndex);
    if (identical(jumped, _queue)) return;
    _queue = jumped;
    await _playCurrent();
  }

  @override
  Future<void> skipToNext() async {
    if (!_queue.hasNext) return;
    _queue = _queue.next();
    await _playCurrent();
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_queue.hasPrevious) return;
    _queue = _queue.previous();
    await _playCurrent();
  }

  @override
  void clearQueue() {
    _queue = _queue.cleared();
    // Clearing keeps only the current track, so both the up-next list and the
    // history collapse to empty; the current track's audio is untouched.
    _emit(_state.copyWith(
      upNext: _queue.upNext,
      previous: _queue.history,
      hasPrevious: false,
    ));
  }

  @override
  void setShuffleEnabled(bool enabled) {
    if (enabled == _shuffleEnabled) return;
    _shuffleEnabled = enabled;
    // Reorder in place: the current track keeps playing; only the up-next list
    // (and whether a previous track now exists) changes — no reload.
    _queue = enabled ? _queue.shuffled(_random) : _queue.unshuffled();
    _emit(_state.copyWith(
      upNext: _queue.upNext,
      previous: _queue.history,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
    ));
  }

  @override
  void setRepeatMode(RepeatMode mode) {
    if (mode == _repeatMode) return;
    _repeatMode = mode;
    _emit(_state.copyWith(repeatMode: _repeatMode));
  }

  @override
  void setVolumeNormalizationEnabled(bool enabled) {
    if (enabled == _normalizeVolume) return;
    _normalizeVolume = enabled;
    // Re-level whatever is loaded so toggling takes effect now, not only on the
    // next track. Best-effort and silent: a volume tweak must never surface as a
    // playback error or interrupt audio.
    unawaited(_applyVolume());
  }

  /// The engine volume (0.0–1.0) to use for [track] given whether normalization
  /// is on. With it off, or no track loaded, returns 1.0 (full, untouched).
  /// With it on, returns the track's safe ReplayGain multiplier — attenuation
  /// only and clip-safe (see [ReplayGain.linearVolume]).
  @visibleForTesting
  static double volumeFor(Track? track, {required bool normalizeVolume}) {
    if (!normalizeVolume || track == null) return 1.0;
    return track.replayGain.linearVolume();
  }

  /// Pushes the target volume for the current track onto the engine. A cast
  /// receiver owns its own volume while suspended, so this is a no-op then.
  Future<void> _applyVolume() async {
    if (_suspended) return;
    final double volume =
        volumeFor(_queue.current, normalizeVolume: _normalizeVolume);
    try {
      await _player.setVolume(volume);
    } catch (_) {
      // A volume failure must never break playback; leave the prior volume.
    }
  }

  /// Decides what to play when the current track finishes, per [_repeatMode]:
  /// repeat-one replays the same track, repeat-all advances (wrapping past the
  /// end), and off advances until the queue runs out and then settles on
  /// [PlaybackStatus.completed].
  void _onCompleted() {
    // The track that just finished is still current here, before any advance.
    // Record the completed play once, regardless of what plays next.
    final Track? finished = _queue.current;
    if (finished != null) _onTrackCompleted?.call(finished);
    switch (_repeatMode) {
      case RepeatMode.one:
        unawaited(_replayCurrent());
      case RepeatMode.all:
        if (_queue.hasNext) {
          skipToNext();
        } else {
          _queue = _queue.restarted();
          unawaited(_playCurrent());
        }
      case RepeatMode.off:
        if (_queue.hasNext) {
          skipToNext();
        } else {
          _emit(_state.copyWith(status: PlaybackStatus.completed));
        }
    }
  }

  /// Replays the current track from the start without re-resolving its URI, so
  /// repeat-one never re-mints a stream URL or re-hits the cache each loop.
  Future<void> _replayCurrent() async {
    await _player.seek(Duration.zero);
    unawaited(_player.play());
  }

  /// Loads and plays the queue's current track, surfacing its up-next list.
  ///
  /// Resolution (local path / content URI / remote stream) happens through the
  /// [PlayableUriResolver]. A resolution failure carries its own friendly,
  /// secret-free message; a load failure after a successful resolve falls back
  /// to a generic one.
  Future<void> _playCurrent({
    Duration startAt = Duration.zero,
    bool autoplay = true,
    bool isRetry = false,
  }) async {
    final track = _queue.current;
    if (track == null) return;

    // A fresh load (or retry) establishes a new position baseline; drop any
    // coalesced tick from the previous source so it can't flush onto it.
    _resetPositionFlush();

    // A fresh (non-retry) load starts a new track or a deliberate (re)play, so
    // reset the mid-stream recovery budget. A retry must keep its counter.
    if (!isRetry) _retriesForCurrent = 0;

    if (_suspended) {
      // A cast receiver owns the audio. Reflect only the queue/track so the UI
      // shows what is playing; the ActivePlaybackController overrides
      // status/position/duration from the cast session. No URI resolve (no need
      // to mint a local stream URL) and no engine work, so the phone stays
      // silent and the local and cast outputs never fight.
      _emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: track,
        upNext: _queue.upNext,
        previous: _queue.history,
        hasPrevious: _queue.hasPrevious,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      ));
      return;
    }

    if (isRetry) {
      // Recovering from a mid-stream drop: keep the current track and position
      // visible and show a calm buffering state, rather than blanking to a fresh
      // load (which would look like the track jumped back to the start).
      _emit(_state.copyWith(status: PlaybackStatus.buffering));
    } else {
      // Reset position/duration up front so the UI doesn't show the previous
      // track's progress while the new one loads.
      _emit(PlaybackState(
        status: PlaybackStatus.loading,
        currentTrack: track,
        upNext: _queue.upNext,
        previous: _queue.history,
        hasPrevious: _queue.hasPrevious,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      ));
    }

    // Try the track's source candidates in deterministic, most-preferred-first
    // order, falling back to the next copy of the same song when the preferred
    // one can't resolve or start. A single-source track has just one candidate,
    // so this behaves exactly as a direct load did.
    final List<Track> candidates = _candidates.candidatesFor(track);
    final ({Track track, ResolvedPlayable resolved}) outcome;
    try {
      outcome = await _loadFirstWorkingCandidate(candidates);
    } on PlaybackResolutionException catch (error) {
      // Every candidate failed: surface one friendly, secret-free message.
      _emitError(track, error.message);
      return;
    }

    // Make the copy that actually started the current one, so the queue, the
    // mini-player, and the "Playing from …" indicator all reflect the source
    // that succeeded — not the preferred one that may have failed. The resolved
    // source rides along on later position/status updates until the next load.
    final Track played = outcome.track;
    if (played.id != track.id) _queue = _queue.replaceCurrent(played);
    _emit(_state.copyWith(
      currentTrack: played,
      source: outcome.resolved.source,
      upNext: _queue.upNext,
      previous: _queue.history,
      hasPrevious: _queue.hasPrevious,
    ));

    // Level this track before it's heard (its ReplayGain, or full volume when
    // normalization is off); resume at the preserved position after a cast
    // handoff; then start — the source is already loaded.
    await _applyVolume();
    if (startAt > Duration.zero) await _player.seek(startAt);
    // play()'s future completes when playback ends, so we don't await it.
    if (autoplay) unawaited(_player.play());
  }

  /// Tries [candidates] in order — **at most once each** — resolving and loading
  /// the first that works, returning it with its resolved source. Throws a
  /// single, safe [PlaybackResolutionException] when every candidate fails.
  ///
  /// A one-candidate list (the common, single-source case) rethrows that
  /// candidate's own specific failure, so single-source playback errors are
  /// worded exactly as before; only a genuine multi-source all-fail collapses to
  /// the generic "any available source" message. It makes a single pass and
  /// never retries, so it always terminates.
  Future<({Track track, ResolvedPlayable resolved})> _loadFirstWorkingCandidate(
    List<Track> candidates,
  ) async {
    final List<PlaybackResolutionException> failures =
        <PlaybackResolutionException>[];
    for (final Track candidate in candidates) {
      final ResolvedPlayable resolved;
      try {
        resolved = await _resolver.resolve(candidate);
      } on PlaybackResolutionException catch (error) {
        // A resolver failure carries its own friendly, secret-free message.
        StabilityDiagnostics.playbackError('resolution');
        failures.add(error);
        continue;
      } catch (_) {
        // An unexpected error before we even know the source: stay generic.
        StabilityDiagnostics.playbackError('resolution-unknown');
        failures.add(const PlaybackResolutionException(
          "Couldn't play this track.",
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        ));
        continue;
      }
      try {
        // setUrl handles file://, content:// (Android), and https:// URIs alike,
        // so local files, SAF documents, and remote streams share one path. The
        // resolver guarantees this is never a bare `jellyfin:`/`subsonic:` scheme
        // — that is turned into an authenticated stream URL before it gets here.
        await _player.setUrl(resolved.uri.toString());
        return (track: candidate, resolved: resolved);
      } catch (_) {
        // Resolved (and, for streams, probed) OK but the engine couldn't open
        // it: a start failure. Word it for the source, then try the next copy.
        StabilityDiagnostics.playbackError('load');
        failures.add(PlaybackResolutionException(
          _loadErrorFor(resolved.source),
          kind: PlaybackResolutionErrorKind.streamUnavailable,
        ));
        continue;
      }
    }
    if (failures.length == 1) throw failures.first;
    throw const PlaybackResolutionException(
      "Couldn't play this track from any available source.",
      kind: PlaybackResolutionErrorKind.streamUnavailable,
    );
  }

  /// The generic message for an engine load failure *after* a successful
  /// resolve, worded for the resolved [source] (a direct stream "couldn't
  /// stream", an on-device/cached file "couldn't play").
  static String _loadErrorFor(PlaybackSource source) =>
      source == PlaybackSource.streamingDirect
          ? "Couldn't stream this track."
          : "Couldn't play this track.";

  /// Emits an error state for [track] carrying a friendly [message], preserving
  /// the queue context so the UI keeps showing the right track and up-next.
  void _emitError(Track track, String message) {
    _emit(PlaybackState(
      status: PlaybackStatus.error,
      currentTrack: track,
      upNext: _queue.upNext,
      previous: _queue.history,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
      errorMessage: message,
    ));
  }

  @override
  bool get isSuspended => _suspended;

  @override
  Future<void> suspend() async {
    if (_suspended) return;
    _suspended = true;
    // A cast receiver now owns position; stop flushing local ticks underneath it.
    _resetPositionFlush();
    // Silence the engine but keep the loaded source and queue intact, so a
    // later resume can pick up the same track instantly when nothing changed.
    await _player.pause();
  }

  @override
  Future<void> resume({Duration at = Duration.zero, bool play = false}) async {
    _suspended = false;
    // The current track may have changed during casting (skips re-cast onto the
    // receiver), so (re)load whatever is current rather than trusting the
    // engine's last-loaded source.
    await _playCurrent(startAt: at, autoplay: play);
  }

  @override
  Future<void> restartQueue() async {
    _queue = _queue.restarted();
    await _playCurrent();
  }

  @override
  Future<void> play() async {
    // A cast receiver owns playback while suspended; never start local audio
    // underneath it.
    if (_suspended) return;
    // play()'s future completes when playback ends, so we don't await it.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _resetPositionFlush();
    await _player.stop();
    final stopped = PlaybackState(
      currentTrack: _state.currentTrack,
      upNext: _queue.upNext,
      previous: _queue.history,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
    _emit(stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_suspended) return;
    return _player.seek(position);
  }

  @override
  Future<void> dispose() async {
    _resetPositionFlush();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
    await _player.dispose();
  }
}
