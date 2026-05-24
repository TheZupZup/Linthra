import 'dart:async';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

import '../models/playback_queue.dart';
import '../models/playback_source.dart';
import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import 'local_playable_uri_resolver.dart';
import 'local_playback_controller.dart';
import 'playable_uri_resolver.dart';
import 'playback_controller.dart';

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
    Random? random,
  })  : _player = player ?? AudioPlayer(),
        _resolver = resolver,
        _random = random ?? Random() {
    _wire();
  }

  final AudioPlayer _player;
  final PlayableUriResolver _resolver;
  final Random _random;
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  final List<StreamSubscription<void>> _subscriptions =
      <StreamSubscription<void>>[];

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

  @override
  PlaybackState get state => _state;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  void _wire() {
    _subscriptions.add(_player.playerStateStream.listen((playerState) {
      // While suspended a cast receiver owns playback; ignore the (paused) local
      // engine's events entirely, so it can never auto-advance or report stale
      // status underneath the cast session.
      if (_suspended) return;
      final status = _statusFor(playerState);
      // When a track finishes, what happens next depends on the repeat mode.
      if (status == PlaybackStatus.completed) {
        _onCompleted();
        return;
      }
      _emit(_state.copyWith(status: status));
    }));
    _subscriptions.add(_player.positionStream.listen((position) {
      if (_suspended) return;
      _emit(_state.copyWith(position: position));
    }));
    _subscriptions.add(_player.durationStream.listen((duration) {
      if (_suspended) return;
      if (duration != null) _emit(_state.copyWith(duration: duration));
    }));
  }

  static PlaybackStatus _statusFor(PlayerState playerState) {
    switch (playerState.processingState) {
      case ProcessingState.idle:
        return PlaybackStatus.idle;
      case ProcessingState.loading:
      case ProcessingState.buffering:
        return PlaybackStatus.loading;
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
    _queue = _queue.enqueueNext(track);
    // The current track keeps playing; only the up-next list changes.
    _emit(_state.copyWith(upNext: _queue.upNext));
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
    _emit(_state.copyWith(upNext: _queue.upNext, hasPrevious: false));
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

  /// Decides what to play when the current track finishes, per [_repeatMode]:
  /// repeat-one replays the same track, repeat-all advances (wrapping past the
  /// end), and off advances until the queue runs out and then settles on
  /// [PlaybackStatus.completed].
  void _onCompleted() {
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
  }) async {
    final track = _queue.current;
    if (track == null) return;

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
        hasPrevious: _queue.hasPrevious,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      ));
      return;
    }

    // Reset position/duration up front so the UI doesn't show the previous
    // track's progress while the new one loads.
    final loading = PlaybackState(
      status: PlaybackStatus.loading,
      currentTrack: track,
      upNext: _queue.upNext,
      hasPrevious: _queue.hasPrevious,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
    _emit(loading);

    final ResolvedPlayable resolved;
    try {
      resolved = await _resolver.resolve(track);
    } on PlaybackResolutionException catch (error) {
      // A resolver failure carries its own friendly, secret-free message.
      _emitError(track, error.message);
      return;
    } catch (_) {
      // An unexpected error before we even know the source: stay generic.
      _emitError(track, "Couldn't play this track.");
      return;
    }

    // Record where the audio is coming from so the UI can show an honest
    // source badge. It rides along on every later position/status update via
    // copyWith until the next track loads (which resets it).
    _emit(_state.copyWith(source: resolved.source));

    try {
      // setUrl handles file://, content:// (Android), and https:// URIs alike,
      // so local files, SAF documents, and Jellyfin streams share one path. The
      // resolver guarantees this is never a bare `jellyfin:<id>` — that scheme
      // is turned into an authenticated stream URL (or a friendly error) before
      // it ever reaches here.
      await _player.setUrl(resolved.uri.toString());
      // Resuming on this device after casting picks up where the receiver left
      // off, paused unless asked to play.
      if (startAt > Duration.zero) await _player.seek(startAt);
      // play()'s future completes when playback ends, so we don't await it.
      if (autoplay) unawaited(_player.play());
    } catch (_) {
      // The URL resolved and (for streams) probed OK, so a failure here is the
      // engine itself. Word it for the source the listener can see on the badge.
      _emitError(track, _loadErrorFor(resolved.source));
    }
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
    await _player.stop();
    final stopped = PlaybackState(
      currentTrack: _state.currentTrack,
      upNext: _queue.upNext,
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
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
    await _player.dispose();
  }
}
