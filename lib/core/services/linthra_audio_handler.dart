import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart' as audio;

import '../models/playback_state.dart';
import '../models/repeat_mode.dart';
import '../models/track.dart';
import '../repositories/download_repository.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/music_library_repository.dart';
import '../repositories/playlist_repository.dart';
import 'media_browser_tree.dart';
import 'playback_controller.dart';

/// Logger name for the Android Auto / media-browser path. Filter device logs
/// with `adb logcat | grep $_logName` to see whether the session attached and
/// whether Android Auto is actually binding, browsing, and selecting items.
///
/// Everything logged here is deliberately **secret-free**: only the structural
/// *category* of a media id (never the raw id, a track id, a URI, or a token)
/// and small counts. See [_categoryOf].
const String _logName = 'Linthra.AndroidAuto';

void _log(String message) => developer.log(message, name: _logName);

/// The non-secret category an [id] belongs to, for safe diagnostics. Returns a
/// fixed label set — never the id itself — so a track id, playlist id, URI, or
/// token can never reach the log.
String _categoryOf(String id) {
  if (id == MediaId.root) return 'root';
  if (id == MediaId.library) return 'library';
  if (id == MediaId.albums) return 'albums';
  if (id == MediaId.artists) return 'artists';
  if (id == MediaId.queue) return 'queue';
  if (id == MediaId.playlists) return 'playlists';
  if (id == MediaId.favorites) return 'favorites';
  if (id == MediaId.offline) return 'offline';
  if (id == MediaId.empty) return 'empty';
  if (MediaId.isAlbumTrack(id)) return 'album-track';
  if (MediaId.isAlbumCategory(id)) return 'album';
  if (MediaId.isArtistTrack(id)) return 'artist-track';
  if (MediaId.isArtistCategory(id)) return 'artist';
  if (MediaId.isPlaylistTrack(id)) return 'playlist-track';
  if (MediaId.isPlaylistCategory(id)) return 'playlist';
  if (MediaId.isLibraryTrack(id)) return 'library-track';
  if (MediaId.isQueueItem(id)) return 'queue-item';
  if (MediaId.isFavoriteItem(id)) return 'favorite';
  if (MediaId.isOfflineItem(id)) return 'offline-item';
  return 'other';
}

/// Bridges the app's [PlaybackController] to the platform media session via
/// `audio_service`. This is the only file in the app that knows
/// `audio_service` exists.
///
/// It is a thin infrastructure adapter, deliberately *not* a second playback
/// engine: it forwards media-session commands (play/pause/stop/skip) to the
/// controller and mirrors the controller's [PlaybackState] back out as
/// audio_service playback state + media item, so the notification, lock screen,
/// and Android Auto reflect what is playing. For Android Auto it also exposes a
/// browsable tree (Songs / Albums / Artists / Playlists / Favorites / Offline /
/// Queue) built by [MediaBrowserTree] and turns a selected item into a
/// [PlaybackController.playTracks] call. The controller
/// stays the single source of truth and owns `just_audio`; the UI never touches
/// this class.
class LinthraAudioHandler extends audio.BaseAudioHandler {
  LinthraAudioHandler(this._controller, this._tree) {
    _subscription = _controller.stateStream.listen(_broadcast);
    // Seed the session from the latest known state so a freshly attached
    // notification/Android Auto isn't blank before the first stream event.
    _broadcast(_controller.state);
  }

  final PlaybackController _controller;
  final MediaBrowserTree _tree;
  late final StreamSubscription<PlaybackState> _subscription;

  // The last media item / playback state actually pushed to the platform
  // session. Position ticks arrive several times a second; re-pushing identical
  // metadata on every one of them thrashes the Android MediaSession and rebuilds
  // the notification needlessly (a real source of jank/ANR during long
  // playback), so [_broadcast] pushes only when something the session shows
  // actually changes. `audio_service` already interpolates the displayed
  // position from `updatePosition` + the wall clock, so it does not need a push
  // per tick — only when the position is discontinuous (a seek/track change) or
  // has drifted enough to re-sync.
  audio.MediaItem? _lastItem;
  audio.PlaybackState? _lastPlaybackState;

  // The queue (as a flat track list) last published to the platform session.
  // Re-publishing the queue on every position tick would thrash the car's
  // "Up Next" list, so [_broadcast] pushes it only when the queue's contents or
  // order actually change. Null until the first broadcast.
  List<Track>? _lastQueueTracks;
  bool _seeded = false;

  /// How far the reported position may drift before a fresh playback-state push
  /// re-syncs the session — so steady playback produces only this ~1 Hz
  /// correction rather than ~5 platform pushes a second.
  static const Duration _positionResyncThreshold = Duration(seconds: 1);

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> stop() async {
    await _controller.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _controller.skipToNext();

  @override
  Future<void> skipToPrevious() => _controller.skipToPrevious();

  /// Jumps to the [index]-th item of the published [queue] — the row a head
  /// unit / Android Auto's "Up Next" list reports when tapped. The queue is
  /// published as history, then the current track, then up-next (see
  /// [_queueTracksFor]), so this maps the flat index back onto the controller's
  /// history/up-next jumps. Out-of-range (a stale row after the queue shrank)
  /// and the current row are safe no-ops; it never bypasses the controller, so
  /// Cast routing and "no duplicate local playback" hold exactly as for a skip.
  @override
  Future<void> skipToQueueItem(int index) async {
    final PlaybackState state = _controller.state;
    final int historyLength = state.previous.length;
    final int total = _queueTracksFor(state).length;
    if (index < 0 || index >= total) return;
    if (index < historyLength) {
      await _controller.playFromHistory(index);
    } else if (index > historyLength) {
      await _controller.playFromQueue(index - historyLength - 1);
    }
    // index == historyLength is the current track: leave it playing untouched.
  }

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> setShuffleMode(audio.AudioServiceShuffleMode shuffleMode) async {
    _controller
        .setShuffleEnabled(shuffleMode != audio.AudioServiceShuffleMode.none);
  }

  @override
  Future<void> setRepeatMode(audio.AudioServiceRepeatMode repeatMode) async {
    _controller.setRepeatMode(_repeatModeFrom(repeatMode));
  }

  // --- Android Auto / media browser ---------------------------------------

  @override
  Future<List<audio.MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final nodes = await _tree.childrenOf(parentMediaId, _controller.state);
    // Secret-free browse trace: confirms Android Auto bound and is requesting
    // children, and shows whether a node returned content (vs. an empty
    // "library not synced yet" case) — without logging any id, title, or URI.
    _log('browse: ${_categoryOf(parentMediaId)} -> ${nodes.length} children');
    return nodes.map(_mediaItemForNode).toList();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final request = await _tree.resolve(mediaId, _controller.state);
    // Secret-free selection trace: which category was picked and whether it
    // resolved to something playable — useful when "controls don't work" turns
    // out to be a stale id resolving to nothing.
    _log('play: ${_categoryOf(mediaId)} resolved=${request != null}');
    if (request == null) return;
    // Delegates to the single PlaybackController, exactly like tapping a track
    // in the app. While a Cast session is active the controller has suspended
    // the local engine, so this updates the queue and mirrors onto the receiver
    // *without* starting any local audio — Android Auto can never produce a
    // second, duplicate stream on the phone. The controller owns that routing;
    // this handler stays a thin, output-agnostic bridge.
    await _controller.playTracks(request.tracks,
        startIndex: request.startIndex);
  }

  // ------------------------------------------------------------------------

  void _broadcast(PlaybackState state) {
    final Track? track = state.currentTrack;
    final audio.MediaItem? item = track == null
        ? null
        : _trackMediaItem(track, id: track.id, live: state.duration);
    // Re-push the media item only when its identity/metadata changes (a track
    // change, or its duration becoming known) — not on every position tick.
    if (!_seeded || !_sameItem(item, _lastItem)) {
      _lastItem = item;
      mediaItem.add(item);
    }
    // Publish the play queue so the car / head-unit "Up Next" list mirrors the
    // controller's queue and a tapped row (skipToQueueItem) lands on the right
    // track. Like the media item, it is pushed only when the queue's contents
    // or order change — never on a position tick (which would thrash the list).
    final List<Track> queueTracks = _queueTracksFor(state);
    if (!_seeded || !_sameQueue(queueTracks, _lastQueueTracks)) {
      _lastQueueTracks = queueTracks;
      queue.add(<audio.MediaItem>[
        for (final Track t in queueTracks) _trackMediaItem(t, id: t.id),
      ]);
    }
    final audio.PlaybackState next = _playbackStateFor(state);
    if (!_seeded || _shouldPushPlayback(next, _lastPlaybackState)) {
      _lastPlaybackState = next;
      playbackState.add(next);
    }
    _seeded = true;
  }

  /// Whether two media items would show the same thing in the session, so a
  /// re-push can be skipped. Compares the fields the platform renders; all of
  /// them derive from the track (identified by [audio.MediaItem.id]) plus the
  /// live duration, so this never drops a real metadata change.
  static bool _sameItem(audio.MediaItem? a, audio.MediaItem? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.id == b.id &&
        a.title == b.title &&
        a.artist == b.artist &&
        a.album == b.album &&
        a.duration == b.duration &&
        a.artUri == b.artUri;
  }

  /// Whether a playback state must be pushed to the platform session: when any
  /// field the session renders as a *control/mode* changes, or when the position
  /// is discontinuous relative to the last push (a seek, a track reset) or has
  /// drifted past [_positionResyncThreshold]. Steady position ticks within the
  /// threshold are skipped — `audio_service` interpolates them.
  static bool _shouldPushPlayback(
    audio.PlaybackState next,
    audio.PlaybackState? last,
  ) {
    if (last == null) return true;
    if (next.playing != last.playing ||
        next.processingState != last.processingState ||
        next.shuffleMode != last.shuffleMode ||
        next.repeatMode != last.repeatMode ||
        !_sameControls(next.controls, last.controls)) {
      return true;
    }
    return (next.updatePosition - last.updatePosition).abs() >=
        _positionResyncThreshold;
  }

  static bool _sameControls(
    List<audio.MediaControl> a,
    List<audio.MediaControl> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The live queue as one flat, ordered list: history, then the current track,
  /// then up-next. This is the exact order published to the platform session's
  /// [queue], so [skipToQueueItem] can map a flat row index straight back onto
  /// the controller's history / up-next jumps.
  static List<Track> _queueTracksFor(PlaybackState state) {
    final Track? current = state.currentTrack;
    return <Track>[
      ...state.previous,
      if (current != null) current,
      ...state.upNext,
    ];
  }

  /// Whether two queues would show the same list (same tracks, same order), so a
  /// re-push can be skipped. [Track] equality is by id, which is all the queue
  /// rows render from; the now-playing item carries any live metadata.
  static bool _sameQueue(List<Track> a, List<Track>? b) {
    if (b == null || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  audio.MediaItem _mediaItemForNode(MediaNode node) {
    final track = node.track;
    if (node.playable && track != null) {
      return _trackMediaItem(track, id: node.id);
    }
    // A browsable container (album/artist) may carry token-free cover art so the
    // car shows artwork on the row; categories and placeholders leave it null.
    return audio.MediaItem(
      id: node.id,
      title: node.title,
      playable: false,
      displaySubtitle: node.subtitle,
      artUri: _mediaArtUri(node.artworkUri),
    );
  }

  audio.MediaItem _trackMediaItem(
    Track track, {
    required String id,
    Duration live = Duration.zero,
  }) {
    // Prefer the live duration the engine reported (now-playing); fall back to
    // the track's catalog duration, and omit it entirely when unknown.
    final duration = live > Duration.zero ? live : track.duration;
    return audio.MediaItem(
      id: id,
      title: track.title,
      artist: track.artistName,
      album: track.albumName,
      duration: duration > Duration.zero ? duration : null,
      artUri: _mediaArtUri(track.artworkUri),
    );
  }

  /// The artwork URI to hand the platform media session (notification, lock
  /// screen, Android Auto), or null when there is none it can load directly.
  ///
  /// Unlike the in-app artwork seam ([artworkImageProvider]), `MediaItem.artUri`
  /// is fetched by the OS/audio_service itself, so only a directly loadable,
  /// credential-free URI belongs here: a token-free `http(s)` cover (Jellyfin)
  /// or a local `file:` cover (a local file's embedded art). An opaque in-app
  /// reference such as Subsonic's `subsonic-cover:<id>` — which only the widget
  /// resolver can turn into a signed URL — is dropped to null, so the platform
  /// is never handed a custom-scheme URI it can't fetch (which would fail/log
  /// instead of cleanly showing no art). Caching a resolved Subsonic cover to a
  /// `file:` for the lock screen is a separate follow-up; it must stay
  /// token-free, since the credential must never reach the platform session.
  static Uri? _mediaArtUri(Uri? uri) {
    if (uri == null) return null;
    if (uri.isScheme('http') || uri.isScheme('https') || uri.isScheme('file')) {
      return uri;
    }
    return null;
  }

  audio.PlaybackState _playbackStateFor(PlaybackState state) {
    return audio.PlaybackState(
      controls: _controlsFor(state),
      // The transport capabilities the platform (notification, lock screen,
      // Android Auto, Bluetooth/steering-wheel media buttons) may invoke on the
      // session. Every action here is implemented by this handler, so none is
      // "unsupported": skip is advertised steadily (rather than toggled at queue
      // edges) so a head unit that caches the capability set at connect time
      // keeps its Next/Previous and queue-row buttons live; the *visible*
      // notification controls are still gated on hasNext/hasPrevious by
      // [_controlsFor], so no dead button is ever shown.
      systemActions: const <audio.MediaAction>{
        audio.MediaAction.seek,
        audio.MediaAction.skipToNext,
        audio.MediaAction.skipToPrevious,
        audio.MediaAction.skipToQueueItem,
        audio.MediaAction.setShuffleMode,
        audio.MediaAction.setRepeatMode,
      },
      processingState: _processingStateFor(state.status),
      playing: _isSessionPlaying(state.status),
      updatePosition: state.position,
      shuffleMode: state.shuffleEnabled
          ? audio.AudioServiceShuffleMode.all
          : audio.AudioServiceShuffleMode.none,
      repeatMode: _repeatModeTo(state.repeatMode),
    );
  }

  /// Whether the platform session should be reported as `playing`.
  ///
  /// This is the value that keeps the foreground media service (and the CPU +
  /// Wi-Fi wake locks `audio_service` holds with it) alive: `audio_service`
  /// promotes the service to the foreground while `playing` is `true` and, with
  /// the default `androidStopForegroundOnPause`, demotes it the moment it goes
  /// `false`. If a mid-stream re-buffer or a track transition reported
  /// `playing: false`, the OS could freeze the backgrounded process with the
  /// screen off — so streaming would go silent and only resume when the app is
  /// reopened (the exact field bug this guards against).
  ///
  /// So the session is "playing" whenever the engine is actively working toward
  /// sound — steadily playing, re-buffering mid-stream, or loading the next
  /// track — and only reports `false` on a real user pause, stop, idle, normal
  /// completion, or error. The distinct buffering/loading `processingState`
  /// still drives the notification's spinner; the foreground service stays up.
  static bool _isSessionPlaying(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.playing:
      case PlaybackStatus.buffering:
      case PlaybackStatus.loading:
        return true;
      case PlaybackStatus.idle:
      case PlaybackStatus.paused:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        return false;
    }
  }

  static RepeatMode _repeatModeFrom(audio.AudioServiceRepeatMode mode) {
    switch (mode) {
      case audio.AudioServiceRepeatMode.none:
        return RepeatMode.off;
      case audio.AudioServiceRepeatMode.one:
        return RepeatMode.one;
      case audio.AudioServiceRepeatMode.all:
      case audio.AudioServiceRepeatMode.group:
        return RepeatMode.all;
    }
  }

  static audio.AudioServiceRepeatMode _repeatModeTo(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return audio.AudioServiceRepeatMode.none;
      case RepeatMode.all:
        return audio.AudioServiceRepeatMode.all;
      case RepeatMode.one:
        return audio.AudioServiceRepeatMode.one;
    }
  }

  List<audio.MediaControl> _controlsFor(PlaybackState state) {
    // Show the pause control whenever the session is treated as playing
    // (including while buffering/loading), so the notification/lock-screen
    // toggle matches the reported `playing` flag rather than flipping to a play
    // icon during a mid-stream re-buffer.
    return <audio.MediaControl>[
      if (state.hasPrevious) audio.MediaControl.skipToPrevious,
      _isSessionPlaying(state.status)
          ? audio.MediaControl.pause
          : audio.MediaControl.play,
      audio.MediaControl.stop,
      if (state.hasNext) audio.MediaControl.skipToNext,
    ];
  }

  audio.AudioProcessingState _processingStateFor(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.idle:
        return audio.AudioProcessingState.idle;
      case PlaybackStatus.loading:
        return audio.AudioProcessingState.loading;
      case PlaybackStatus.buffering:
        return audio.AudioProcessingState.buffering;
      case PlaybackStatus.playing:
      case PlaybackStatus.paused:
        return audio.AudioProcessingState.ready;
      case PlaybackStatus.completed:
        return audio.AudioProcessingState.completed;
      case PlaybackStatus.error:
        return audio.AudioProcessingState.error;
    }
  }

  /// Stops mirroring controller state. Call before disposing the controller.
  Future<void> dispose() => _subscription.cancel();
}

/// Registers [controller] with the platform media session so playback appears
/// in the notification / lock screen and is reachable from Android Auto, with a
/// browsable tree backed by [library] and — when supplied — the user's
/// [playlists], [favorites], and offline [downloads].
///
/// Runs entirely off repository seams, so when Android Auto starts the media
/// service cold (before any phone screen is opened) the browse tree is already
/// answerable from the persisted catalog/playlists/favourites/downloads — it
/// does not wait on the Flutter UI.
///
/// Best-effort by design: returns `null` when `audio_service` can't initialise
/// (a platform without the native setup, or a test environment). Playback still
/// works through the controller in that case, so a missing media session never
/// breaks basic playback. A failure is logged (secret-free) under [_logName] so
/// a silent "no media session / not in Android Auto" is diagnosable from
/// `adb logcat`.
Future<LinthraAudioHandler?> connectMediaSession(
  PlaybackController controller,
  MusicLibraryRepository library, {
  PlaylistRepository? playlists,
  FavoritesRepository? favorites,
  DownloadRepository? downloads,
}) async {
  try {
    final handler = await audio.AudioService.init(
      builder: () => LinthraAudioHandler(
        controller,
        MediaBrowserTree(
          library,
          playlists: playlists,
          favorites: favorites,
          downloads: downloads,
        ),
      ),
      config: const audio.AudioServiceConfig(
        androidNotificationChannelId: 'com.linthra.audio',
        androidNotificationChannelName: 'Linthra playback',
        // Keep the notification ongoing (un-swipeable) while the session reports
        // `playing`, so the foreground media service — and the CPU/Wi-Fi wake
        // locks it holds — stay alive with the screen off. `audio_service`
        // requires `androidStopForegroundOnPause: true` (the default, set
        // explicitly here) whenever the notification is ongoing: the service is
        // foregrounded only while playing and demoted on a real pause, never on
        // a mid-stream re-buffer (see [_isSessionPlaying]).
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    _log('media session attached (Android Auto browser ready)');
    return handler;
  } catch (error) {
    // The error here is a platform/plugin init failure (e.g. unsupported
    // platform, or a test host with no native binding) — it carries no Jellyfin
    // token or URL. Log its type so the cause is visible without leaking
    // anything from the catalog or a session.
    _log('media session init failed: ${error.runtimeType}');
    return null;
  }
}
