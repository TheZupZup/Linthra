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
import 'media_artwork_source.dart';
import 'media_browser_tree.dart';
import 'playback_controller.dart';
import 'stability_diagnostics.dart';

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
  LinthraAudioHandler(
    this._controller,
    this._tree, {
    MediaArtworkSource? artwork,
  }) : _artwork = artwork {
    _subscription = _controller.stateStream.listen(_broadcast);
    // Refresh the now-playing item the instant the current track's cover finishes
    // warming, so a card published without art picks it up at once instead of
    // waiting for the next playback tick. Off the playback path; [_onCoverReady]
    // gates the actual push so it never double-pushes or loops.
    _coverReadySub = artwork?.coverReady.listen(_onCoverReady);
    // Seed the session from the latest known state so a freshly attached
    // notification/Android Auto isn't blank before the first stream event.
    _broadcast(_controller.state);
  }

  final PlaybackController _controller;
  final MediaBrowserTree _tree;
  late final StreamSubscription<PlaybackState> _subscription;
  StreamSubscription<Uri>? _coverReadySub;

  /// Synchronous lookup of an already-fetched, safe `content://` cover for a
  /// credential-free reference (e.g. Subsonic). `null` when none is wired (tests
  /// / unsupported platform), in which case such references carry no
  /// media-session artwork. Covers are warmed ahead of time, off the playback
  /// path, by `MediaArtworkPrewarmService`; the handler reads this synchronously
  /// while building a `MediaItem` and never fetches. Its `coverReady` stream lets
  /// the handler re-publish a now-art-less item once a cover lands (also off the
  /// playback path).
  final MediaArtworkSource? _artwork;

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
  Future<void> play() {
    // A play that arrived through the platform media session: the user tapped
    // the notification / lock-screen play, or Android Auto / Bluetooth / a
    // headset sent PLAY. Breadcrumb it (secret-free) so every legitimate resume
    // is accounted for and distinguishable from an unwanted self-resume — which,
    // with the engine's audio-focus auto-resume disabled, no longer happens.
    StabilityDiagnostics.playCommand('media-session');
    return _controller.play();
  }

  @override
  Future<void> pause() {
    // A pause that arrived through the platform media session: the notification
    // / lock-screen pause, or Android Auto / Bluetooth / a headset sending
    // PAUSE. Breadcrumb it (secret-free) so a screen-off "it paused by itself"
    // report can tell a real session PAUSE apart from an audio-focus-loss or
    // becoming-noisy pause (both logged under `audio focus:` by the engine).
    StabilityDiagnostics.pauseCommand('media-session');
    return _controller.pause();
  }

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
      // Secret-free artwork trace: the *scheme* of what reached MediaItem.artUri
      // (never the URI). `content` = a safe FileProvider cover was attached;
      // `none` = no cover (not warmed / failed); `http`/`file` = Jellyfin/local;
      // `other` = a bug (an unresolved reference leaked). Lets a car test +
      // `adb logcat | grep Linthra` show whether the cover is actually being set.
      _log('now-playing: art=${_artScheme(item?.artUri)}');
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

  /// The media-session-safe artwork URI for [artworkUri].
  ///
  /// A platform-loadable cover (a token-free `http`/`https` image such as
  /// Jellyfin's primary image, a local `file:`, or an app-provided `content:`
  /// URI) is handed to the session unchanged. A credential-free *reference* (e.g.
  /// Subsonic's `subsonic-cover:<id>`) is replaced by its already-fetched, cached
  /// `content://` copy (a FileProvider URI the session's process can read) when
  /// one exists, or `null` otherwise — so an unloadable reference, and crucially
  /// never a credentialed URL, reaches `MediaItem.artUri`. Covers are
  /// fetched+cached ahead of time off the playback path by
  /// `MediaArtworkPrewarmService`; this read is purely synchronous.
  Uri? _sessionArtUri(Uri? artworkUri) {
    if (artworkUri == null) return null;
    if (isPlatformLoadableArtwork(artworkUri)) return artworkUri;
    return _artwork?.cached(artworkUri);
  }

  /// A cover ([reference]) just finished warming. If it belongs to the track
  /// playing now, re-publish so its art appears immediately rather than at the
  /// next playback tick. Off the playback path (driven by the cache, not the
  /// engine), and safe: [_broadcast]'s [_sameItem] check pushes only when the
  /// item actually changed, so an already-shown cover (or a cover for some other
  /// track) is a no-op — no double-push, no loop (a re-broadcast never emits
  /// `coverReady`).
  void _onCoverReady(Uri reference) {
    if (_controller.state.currentTrack?.artworkUri == reference) {
      // A cover finished warming: refresh the now-playing card so the art shows.
      // Breadcrumb it (secret-free) so a "cover art refresh restarted my music"
      // report shows the rebroadcast is off the playback path — [_broadcast]
      // mirrors the controller's *current* state and issues no transport command.
      StabilityDiagnostics.mediaItemRebroadcast('artwork');
      _broadcast(_controller.state);
    }
  }

  /// The non-secret *scheme* of an artwork [uri], for the diagnostic trace —
  /// never the URI itself (a `content:`/`file:`/`http` URI is credential-free,
  /// but logging only the scheme keeps the trace trivially safe). `none` for
  /// null; `other` flags the bug where a reference leaked into `artUri`.
  static String _artScheme(Uri? uri) {
    if (uri == null) return 'none';
    if (uri.isScheme('content')) return 'content';
    if (uri.isScheme('http') || uri.isScheme('https')) return 'http';
    if (uri.isScheme('file')) return 'file';
    return 'other';
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
    // A credential-free reference (e.g. Subsonic) that isn't already cached
    // locally is dropped to null rather than handed over unloadable.
    return audio.MediaItem(
      id: node.id,
      title: node.title,
      playable: false,
      displaySubtitle: node.subtitle,
      artUri: _sessionArtUri(node.artworkUri),
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
      // Only a platform-loadable cover (or a locally-cached reference) — never a
      // credentialed URL or an unloadable reference — reaches the session.
      artUri: _sessionArtUri(track.artworkUri),
    );
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
  Future<void> dispose() async {
    await _coverReadySub?.cancel();
    await _subscription.cancel();
  }
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
/// When [artwork] is supplied the now-playing media item can show a
/// credential-free source's cover (e.g. Subsonic) on the lock screen / Android
/// Auto: the handler reads an already-cached safe local `file:` for the cover's
/// reference (warmed ahead of time, off the playback path, by
/// `MediaArtworkPrewarmService`) and uses it as `artUri`, never a credentialed
/// URL. The read is synchronous, so artwork never touches the playback path.
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
  MediaArtworkSource? artwork,
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
        artwork: artwork,
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
        // Downscale the album-art bitmap `audio_service` embeds in the session
        // metadata. The metadata (with the bitmap) is delivered to the platform
        // session and to Android Auto across a process boundary; a full-size
        // cover can exceed the cross-process limit and be dropped — leaving
        // Android Auto, which then can only fall back to the art URI it loads in
        // its own process, with no art. A small bitmap crosses reliably, so the
        // now-playing cover actually shows. This applies to all sources (it only
        // changes the bitmap *size*, not whether art shows) and is the artwork
        // change that — with the content:// cover URI — makes Subsonic covers
        // appear on the car; it does not touch audio playback.
        artDownscaleWidth: 256,
        artDownscaleHeight: 256,
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
