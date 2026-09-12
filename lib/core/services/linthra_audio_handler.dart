import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/foundation.dart' show visibleForTesting;

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
  if (MediaId.isBrowsePage(id)) return 'browse-page';
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

  // The queue window last published to the platform session, and the absolute
  // index in the controller's queue that its first row corresponds to.
  // Re-publishing the queue on every position tick would thrash the car's
  // "Up Next" list, so [_broadcast] pushes it only when the window's contents,
  // order, or offset actually change. Null until the first broadcast.
  List<Track>? _lastQueueTracks;
  int _lastQueueStart = 0;
  bool _seeded = false;

  // The exact queue/track/duration inputs the metadata half of the last
  // broadcast was derived from, kept by *reference* so a position tick can be
  // recognised for what it is before any work is done for it.
  //
  // A steady playing state emits ~4 times a second, and every one of those
  // emissions carries the same `previous` / `upNext` list objects and the same
  // current track: [PlaybackState.copyWith] passes the lists straight through,
  // so a tick that only advances the position cannot have changed a single row.
  // Without this guard each of those ticks re-materialized the published window
  // (up to [maxPublishedQueueItems] tracks) and rebuilt a [audio.MediaItem],
  // only for the comparisons below to conclude nothing changed — several
  // thousand list writes a minute, for the whole length of a screen-off
  // session. Identity is a conservative test: a genuinely new list (a queue
  // edit, a skip, a shuffle) is a different object and falls through to the
  // full comparison, so nothing a session renders can be missed by it.
  List<Track>? _lastBroadcastPrevious;
  List<Track>? _lastBroadcastUpNext;
  Track? _lastBroadcastTrack;
  Duration? _lastBroadcastDuration;

  // Whether this handler has been detached from the session ([dispose]).
  //
  // A detached handler must never drive the controller again. `audio_service`
  // hands a command to whichever handler its callbacks currently point at, and
  // a rebind installs a new one — but nothing tears the old one down, and a
  // command already in flight (or a car that still holds a reference across a
  // reconnect) can still land on it. Forwarding then would run the *same* press
  // through the controller twice, once per live handler. Every transport
  // command checks this first, so a superseded handler is inert rather than a
  // second, invisible driver of the queue (#638).
  bool _detached = false;

  /// Whether [dispose] has run, i.e. this handler no longer speaks for the
  /// session and forwards nothing to the controller.
  bool get isDetached => _detached;

  /// The most rows the platform session's queue ever carries.
  ///
  /// The published queue is delivered to every media controller — Android Auto
  /// included — in a single Binder transaction (`MediaSessionCompat.setQueue`),
  /// exactly like a browse response and against the same ~1 MB per-process
  /// buffer. Selecting one song from the Songs list hands the controller the
  /// whole catalog, so an unbounded mirror would publish a six-figure queue and
  /// recreate the browse bug on the playback path — and, because
  /// `AudioServicePlugin.raw2queue` runs every row through
  /// `createMediaMetadata`, would also add one permanently-cached
  /// `MediaMetadataCompat` per row to `AudioService`'s static
  /// `mediaMetadataCache`. So the session sees a *window*, while the controller
  /// keeps the real, complete queue.
  static const int maxPublishedQueueItems = 250;

  /// How many already-played rows stay visible behind the current track in the
  /// published window, so the car's list still scrolls back a little rather than
  /// starting abruptly at what is playing now.
  static const int publishedQueueHistory = 50;

  /// How far the reported position may drift before a fresh playback-state push
  /// re-syncs the session — so steady playback produces only this ~1 Hz
  /// correction rather than ~5 platform pushes a second.
  static const Duration _positionResyncThreshold = Duration(seconds: 1);

  @override
  Future<void> play() async {
    if (_detached) return;
    // A play that arrived through the platform media session: the user tapped
    // the notification / lock-screen play, or Android Auto / Bluetooth / a
    // headset sent PLAY. Breadcrumb it (secret-free) so every legitimate resume
    // is accounted for and distinguishable from an unwanted self-resume — which,
    // with the engine's audio-focus auto-resume disabled, no longer happens.
    StabilityDiagnostics.playCommand('media-session');
    await _controller.play();
  }

  @override
  Future<void> pause() async {
    if (_detached) return;
    // A pause that arrived through the platform media session: the notification
    // / lock-screen pause, or Android Auto / Bluetooth / a headset sending
    // PAUSE. Breadcrumb it (secret-free) so a screen-off "it paused by itself"
    // report can tell a real session PAUSE apart from an audio-focus-loss or
    // becoming-noisy pause (both logged under `audio focus:` by the engine).
    StabilityDiagnostics.pauseCommand('media-session');
    await _controller.pause();
  }

  @override
  Future<void> stop() async {
    if (_detached) return;
    await _controller.stop();
    await super.stop();
  }

  /// Advances one track, on behalf of whoever pressed Next: Android Auto's
  /// on-screen control, a steering-wheel or Bluetooth button, a wired headset,
  /// or the notification. They all arrive here, and all of them mean the same
  /// thing, so this forwards to the one shared [PlaybackController.skipToNext]
  /// and does nothing else — no Android-Auto-only queue, no index arithmetic.
  ///
  /// Exactly one advance per press: the controller moves its queue pointer
  /// synchronously before it awaits anything, so two presses in quick
  /// succession advance twice and one press can never advance twice. At the end
  /// of the queue it is a safe no-op, and the shared repeat/shuffle policy
  /// applies exactly as it does in the app.
  @override
  Future<void> skipToNext() async {
    if (_detached) return;
    // Breadcrumb it (secret-free) so a "the car's Next did nothing" report can
    // tell a command that never arrived (no breadcrumb — the head unit swallowed
    // it) from one that arrived and was a legitimate queue-boundary no-op.
    StabilityDiagnostics.skipCommand('next');
    await _controller.skipToNext();
  }

  /// Steps back, on behalf of whoever pressed Previous — same transports, same
  /// shared policy as [skipToNext].
  ///
  /// It calls [PlaybackController.skipToPrevious] and nothing else, so the car
  /// gets whatever Linthra's previous-track behaviour is, and keeps getting it
  /// if that behaviour ever changes: today the controller steps to the previous
  /// queue item (it does not restart the current track first), and a Previous on
  /// the first track is a safe no-op.
  @override
  Future<void> skipToPrevious() async {
    if (_detached) return;
    StabilityDiagnostics.skipCommand('previous');
    await _controller.skipToPrevious();
  }

  /// Jumps to the [index]-th row of the published [queue] — what a head unit /
  /// Android Auto's "Up Next" list reports when tapped.
  ///
  /// The published queue is a *window* onto the controller's full queue (see
  /// [maxPublishedQueueItems]), and `audio_service` numbers its rows from zero
  /// within whatever list was published (`raw2queue` assigns
  /// `QueueItem(description, i)`). So a tapped row is offset by
  /// [_lastQueueStart] to get the absolute position in history + current +
  /// up-next, which then maps onto the controller's history/up-next jumps.
  ///
  /// The row is validated against the **published window** before it is
  /// translated, not merely against the controller's queue afterwards. Those
  /// are different checks once the window has slid: with a 200k queue and a
  /// window at 99 950, row 255 does not exist (the window is 250 rows) yet its
  /// absolute position 100 205 sits comfortably inside the controller's queue.
  /// Validating only the translated index would accept that row and jump to a
  /// track the car never showed. So a row outside what was actually published
  /// is rejected up front.
  ///
  /// Out-of-range — a stale row from a window published before the queue moved
  /// or shrank — and the current row are safe no-ops. It never bypasses the
  /// controller, so Cast routing and "no duplicate local playback" hold exactly
  /// as for a skip.
  @override
  Future<void> skipToQueueItem(int index) async {
    if (_detached) return;
    // Only rows that exist in the queue this handler last published are real.
    final int publishedLength = _lastQueueTracks?.length ?? 0;
    if (index < 0 || index >= publishedLength) return;

    final PlaybackState state = _controller.state;
    final int historyLength = state.previous.length;
    final int total = _queueLengthOf(state);
    final int absolute = _lastQueueStart + index;
    // The queue can still have shrunk since that window was published.
    if (absolute < 0 || absolute >= total) return;
    if (absolute < historyLength) {
      await _controller.playFromHistory(absolute);
    } else if (absolute > historyLength) {
      await _controller.playFromQueue(absolute - historyLength - 1);
    }
    // absolute == historyLength is the current track: leave it playing.
  }

  @override
  Future<void> seek(Duration position) async {
    if (_detached) return;
    await _controller.seek(position);
  }

  @override
  Future<void> setShuffleMode(audio.AudioServiceShuffleMode shuffleMode) async {
    if (_detached) return;
    _controller
        .setShuffleEnabled(shuffleMode != audio.AudioServiceShuffleMode.none);
  }

  @override
  Future<void> setRepeatMode(audio.AudioServiceRepeatMode repeatMode) async {
    if (_detached) return;
    _controller.setRepeatMode(_repeatModeFrom(repeatMode));
  }

  // --- Android Auto / media browser ---------------------------------------

  /// The children a media browser (Android Auto) asked for.
  ///
  /// [options] carries Android's `MediaBrowserCompat` browse options. When the
  /// client asked for a page (`EXTRA_PAGE` / `EXTRA_PAGE_SIZE`), this honours it
  /// — and it must, because nothing else on this stack does:
  /// `MediaBrowserServiceCompat` applies its own `applyOptions` only under
  /// `RESULT_FLAG_OPTION_NOT_HANDLED`, which the base class sets only for
  /// services that leave `onLoadChildren(parentId, result, options)`
  /// unoverridden. `audio_service`'s `AudioService` overrides it and calls
  /// `result.sendResult(...)` directly, so whatever this returns reaches the
  /// client verbatim. Without the window below, a head unit asking for page 1
  /// would be handed page 0's children again.
  ///
  /// Paging is applied *on top of* the tree's own bound rather than instead of
  /// it: a client may subscribe with no options at all (Android's two-argument
  /// `onLoadChildren` path, which reaches Dart as a null [options]), and that
  /// request must still be answerable in one Binder transaction. So
  /// [MediaBrowserTree] caps every node's child list and the window here narrows
  /// it further when asked.
  @override
  Future<List<audio.MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final nodes = await _tree.childrenOf(parentMediaId, _controller.state);
    final page = MediaBrowseOptions.applyPage(nodes, options);
    // Secret-free browse trace: confirms Android Auto bound and is requesting
    // children, and shows whether a node returned content (vs. an empty
    // "library not synced yet" case) — without logging any id, title, or URI.
    _log('browse: ${_categoryOf(parentMediaId)} -> ${page.length}'
        '${page.length == nodes.length ? '' : ' of ${nodes.length}'} children');
    return page.map(_mediaItemForNode).toList();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    if (_detached) return;
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

  /// Mirrors [state] onto the platform session.
  ///
  /// [force] re-derives the media item and queue window even when the state's
  /// own inputs are unchanged. That is what a cover finishing its warm needs:
  /// the artwork is looked up outside [PlaybackState] (see [_sessionArtUri]),
  /// so the same track can genuinely publish a different item.
  void _broadcast(PlaybackState state, {bool force = false}) {
    // A pure position tick carries the same queue objects, the same track, and
    // the same duration as the last broadcast, so nothing the notification, the
    // lock screen, or the car's "Up Next" renders can have moved. Reuse what
    // was published instead of rebuilding it several times a second — the
    // playback state below still follows the position and re-syncs on drift.
    if (!force && _isPublishedMetadataUnchanged(state)) {
      _pushPlaybackState(state, start: _lastQueueStart);
      return;
    }
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
    // track. Only a bounded window around the current track is published (see
    // [maxPublishedQueueItems]); the controller keeps the full queue, so nothing
    // is lost — the car just sees a slice of it, and the window follows playback.
    // Like the media item, it is pushed only when the window's contents, order,
    // or offset change — never on a position tick (which would thrash the list).
    final int total = _queueLengthOf(state);
    final int start = _publishedQueueStart(total, state.previous.length);
    final List<Track> window = _publishedWindow(state, start, total);
    if (!_seeded ||
        start != _lastQueueStart ||
        !_sameQueue(window, _lastQueueTracks)) {
      _lastQueueTracks = window;
      _lastQueueStart = start;
      queue.add(<audio.MediaItem>[
        for (final Track t in window) _trackMediaItem(t, id: t.id),
      ]);
    }
    _lastBroadcastPrevious = state.previous;
    _lastBroadcastUpNext = state.upNext;
    _lastBroadcastTrack = state.currentTrack;
    _lastBroadcastDuration = state.duration;
    _pushPlaybackState(state, start: start);
  }

  /// Whether [state] would publish exactly the media item and queue window the
  /// last broadcast already did, judged by object identity so the check itself
  /// costs nothing on the ~4 Hz position path.
  ///
  /// Deliberately conservative: two equal-but-rebuilt lists answer `false` and
  /// take the full comparison below, so this can only ever skip work that was
  /// provably redundant.
  bool _isPublishedMetadataUnchanged(PlaybackState state) {
    return _seeded &&
        identical(state.previous, _lastBroadcastPrevious) &&
        identical(state.upNext, _lastBroadcastUpNext) &&
        identical(state.currentTrack, _lastBroadcastTrack) &&
        state.duration == _lastBroadcastDuration;
  }

  /// Pushes the platform playback state for [state] when something it renders
  /// changed. [start] is the absolute queue index the published window begins
  /// at, so the highlighted row stays numbered within what was published.
  void _pushPlaybackState(PlaybackState state, {required int start}) {
    // The active row, numbered within the published window so the car
    // highlights the right one — a window-relative index, matching the ids
    // `audio_service` assigns the rows it published.
    final audio.PlaybackState next = _playbackStateFor(
      state,
      queueIndex:
          state.currentTrack == null ? null : state.previous.length - start,
    );
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
      // Forced: the state itself hasn't changed (same track, same queue), only
      // the cover the item resolves to, so the position-tick fast path must not
      // short-circuit this one.
      _broadcast(_controller.state, force: true);
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
        // A transient-focus hold keeps `playing` and the controls steady but
        // drops the speed to 0, and that is exactly the push that stops the
        // displayed position running away during the interruption.
        next.speed != last.speed ||
        next.processingState != last.processingState ||
        next.shuffleMode != last.shuffleMode ||
        next.repeatMode != last.repeatMode ||
        // The highlighted row moves as playback advances, even when nothing
        // else about the state does.
        next.queueIndex != last.queueIndex ||
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

  /// Where the published window starts within the flat history+current+up-next
  /// list of [total] tracks, given the current track sits at [currentIndex].
  ///
  /// A queue that already fits is published whole (start 0), so small libraries
  /// and ordinary playlists behave exactly as before. A larger one keeps
  /// [publishedQueueHistory] rows behind the current track and fills the rest of
  /// the budget forward, sliding back at the end of the queue so the window is
  /// always [maxPublishedQueueItems] long. The current track is therefore always
  /// inside the window, which is what lets the car highlight it and what makes
  /// [skipToQueueItem]'s offset unambiguous.
  static int _publishedQueueStart(int total, int currentIndex) {
    if (total <= maxPublishedQueueItems) return 0;
    int start = currentIndex - publishedQueueHistory;
    if (start < 0) start = 0;
    if (start + maxPublishedQueueItems > total) {
      start = total - maxPublishedQueueItems;
    }
    return start;
  }

  /// How many tracks the controller's queue holds, as the flat
  /// history + current + up-next list the published window indexes into.
  ///
  /// Counted rather than materialized: this runs on every state event, position
  /// ticks included, and a logical queue may hold 200k tracks. Concatenating it
  /// several times a second just to read a length (or to slice 250 rows off it)
  /// would allocate the whole library over and over for no benefit.
  static int _queueLengthOf(PlaybackState state) =>
      state.previous.length +
      (state.currentTrack == null ? 0 : 1) +
      state.upNext.length;

  /// The track at flat position [index] of history + current + up-next, without
  /// building that list. Callers stay inside `0 ..< _queueLengthOf(state)`.
  static Track _queueTrackAt(PlaybackState state, int index) {
    final List<Track> previous = state.previous;
    if (index < previous.length) return previous[index];
    final Track? current = state.currentTrack;
    if (current == null) return state.upNext[index - previous.length];
    if (index == previous.length) return current;
    return state.upNext[index - previous.length - 1];
  }

  /// The rows to publish: at most [maxPublishedQueueItems] tracks starting at
  /// flat position [start] of a queue holding [total] of them. Materializes only
  /// what is published — 250 tracks at most, whatever the queue's real size.
  static List<Track> _publishedWindow(
    PlaybackState state,
    int start,
    int total,
  ) {
    final int end = start + maxPublishedQueueItems > total
        ? total
        : start + maxPublishedQueueItems;
    return <Track>[
      for (int i = start; i < end; i++) _queueTrackAt(state, i),
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

  audio.PlaybackState _playbackStateFor(
    PlaybackState state, {
    int? queueIndex,
  }) {
    return audio.PlaybackState(
      queueIndex: queueIndex,
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
      playing: _isSessionPlaying(state),
      updatePosition: state.position,
      speed: _sessionSpeed(state),
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
  /// `androidStopForegroundOnPause: true`, demotes it the moment it goes
  /// `false`. If a mid-stream re-buffer or a track transition reported
  /// `playing: false`, the OS could freeze the backgrounded process with the
  /// screen off — so streaming would go silent and only resume when the app is
  /// reopened (the exact field bug this guards against).
  ///
  /// So the session is "playing" whenever the engine is actively working toward
  /// sound — steadily playing, re-buffering mid-stream, or loading the next
  /// track. The distinct buffering/loading `processingState` still drives the
  /// notification's spinner; the foreground service stays up.
  ///
  /// A pause is the one state that depends on *why* it happened, which is what
  /// makes this the battery-optimal mode (#499):
  ///  - paused because another app holds a transient focus and Linthra will
  ///    resume when it hands focus back (the controller's
  ///    [PlaybackState.interruptedByTransientFocus]) → still `playing`, so the
  ///    service stays foreground and the isolate that processes
  ///    `AUDIOFOCUS_GAIN` stays alive. Without it, recovery from a call or a
  ///    navigation prompt would again need the app reopened (#244).
  ///  - paused by the user → `false`, so the service is demoted and the wake
  ///    lock released straight away, exactly like stop / idle / completion /
  ///    error. That is the battery win over holding it across *every* pause.
  ///
  /// The controller bounds the transient hold, so a pause can never keep the
  /// service foreground indefinitely.
  static bool _isSessionPlaying(PlaybackState state) {
    switch (state.status) {
      case PlaybackStatus.playing:
      case PlaybackStatus.buffering:
      case PlaybackStatus.reconnecting:
      case PlaybackStatus.loading:
        return true;
      case PlaybackStatus.paused:
        return state.interruptedByTransientFocus;
      case PlaybackStatus.idle:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        return false;
    }
  }

  /// The rate the reported position is actually advancing at.
  ///
  /// `audio_service` — and, through it, `PlaybackStateCompat` — extrapolates the
  /// position every consumer *displays* (notification, lock screen, Android
  /// Auto, Bluetooth head unit) from `updatePosition` + wall clock × speed while
  /// the session says it is playing. A transient-focus hold is the one state
  /// where the session says `playing` while the engine is stopped for an
  /// open-ended stretch — up to the controller's hold timeout — so leaving the
  /// speed at 1.0 would run the progress bar (and a car's) minutes ahead of the
  /// audio during a call, then snap it back on the resume.
  ///
  /// Reporting 0.0 freezes the displayed position exactly where the audio
  /// stopped, with no extra pushes or timers, and does not touch the foreground
  /// service: `audio_service` promotes and demotes it on the `playing` flag
  /// alone. Buffering and loading keep 1.0 — they are bounded by the engine's
  /// own watchdog and behave as before.
  static double _sessionSpeed(PlaybackState state) =>
      state.status == PlaybackStatus.paused ? 0.0 : 1.0;

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
      _isSessionPlaying(state)
          ? audio.MediaControl.pause
          : audio.MediaControl.play,
      audio.MediaControl.stop,
      if (state.hasNext) audio.MediaControl.skipToNext,
    ];
  }

  /// The session-level processing state for a controller [status].
  ///
  /// Opening a track — [PlaybackStatus.loading] — is reported as *buffering*,
  /// not as `audio_service`'s `loading` (#638).
  ///
  /// `AudioProcessingState.loading` is the one value that becomes
  /// `PlaybackStateCompat.STATE_CONNECTING`
  /// (`AudioService.getPlaybackState()`), and `STATE_CONNECTING` does not mean
  /// "preparing the next item" — the platform defines it as the session
  /// connecting to a *new destination*. Android Auto reads it that way: while
  /// the session sits in `STATE_CONNECTING` the head unit shows its connecting
  /// placeholder, drops the position/progress it was drawing, and stops
  /// dispatching transport presses — so a Next pressed in that window is
  /// acknowledged by the car and never reaches this handler at all.
  ///
  /// Linthra enters `loading` on *every* track change: the controller's
  /// `_playCurrent` publishes it before resolving the next track's playable
  /// URI, which on a remote source is a network round trip. In a car that is
  /// most of the window a listener actually presses Next in, which is what
  /// made the car's Next/Previous look like it only worked sometimes.
  /// Bluetooth/headset buttons and the notification never regressed with it
  /// because those arrive as media-button intents that the session dispatches
  /// whatever state it is in.
  ///
  /// Buffering is also simply the truthful state: the item is being prepared,
  /// which is exactly what `STATE_BUFFERING` is for, and the car keeps its
  /// transport row live and its metadata/progress visible across the change.
  /// This is a *reporting* change only — nothing about the queue, the
  /// controller, or [PlaybackStatus] moves — and the session keeps reporting
  /// `playing` through the transition ([_isSessionPlaying]), so the foreground
  /// service is held exactly as before.
  ///
  /// `STATE_CONNECTING` is never the right answer for this session: it has no
  /// destination to connect to. Cast routing is resolved by
  /// `ActivePlaybackController` before any state reaches this bridge, so what
  /// arrives here is always a local view of one already-chosen output.
  audio.AudioProcessingState _processingStateFor(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.idle:
        return audio.AudioProcessingState.idle;
      case PlaybackStatus.loading:
      case PlaybackStatus.buffering:
      case PlaybackStatus.reconnecting:
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

  /// Stops mirroring controller state and makes this handler inert.
  ///
  /// Call before disposing the controller, and whenever this handler stops being
  /// the session's handler. Idempotent, and it closes both directions: no
  /// further state is mirrored *out*, and any command that still arrives *in* —
  /// from a car that is reconnecting, or one already in flight when the session
  /// was rebound — is dropped instead of driving a controller this handler no
  /// longer speaks for.
  Future<void> dispose() async {
    _detached = true;
    await _coverReadySub?.cancel();
    _coverReadySub = null;
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
///
/// **Attaches at most once per process.** A second call returns the handler that
/// is already attached instead of initialising `audio_service` again (#638).
/// `AudioService.init` installs a fresh set of platform callbacks and starts a
/// fresh set of stream observers each time it runs, but it tears none of the
/// previous ones down: a second init would leave the first handler mirroring
/// state into the *same* platform session — two writers racing over the
/// notification, the now-playing metadata and the car's Up Next list — while
/// commands went to the second. It is an assertion error in debug and silent in
/// release, which is exactly the shape of a bug that only shows up on a real
/// head unit, so the guard is here rather than left to the caller.
Future<LinthraAudioHandler?> connectMediaSession(
  PlaybackController controller,
  MusicLibraryRepository library, {
  PlaylistRepository? playlists,
  FavoritesRepository? favorites,
  DownloadRepository? downloads,
  MediaArtworkSource? artwork,
}) async {
  final LinthraAudioHandler? attached = _attachedHandler;
  if (attached != null && !attached.isDetached) {
    _log('media session already attached (reusing the live handler)');
    return attached;
  }
  // A detached handler is never handed back: it forwards nothing, so returning
  // it would look like a live session and behave like none at all.
  _attachedHandler = null;
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
        // Demote the foreground media service on a pause — but only on a pause
        // that is really the user's (#499).
        //
        // `audio_service` releases the foreground service AND the CPU wake lock
        // the moment the session reports `playing: false`, which lets the OS
        // freeze the Flutter isolate while backgrounded. The on-device audio
        // focus handling runs in that isolate (just_audio disables ExoPlayer's
        // native focus and routes interruptions through audio_session/Dart), so
        // a frozen isolate can't process the `AUDIOFOCUS_GAIN` that another app
        // emits when it ends a voice/transient interruption — and playback would
        // only recover when reopening the app (#244).
        //
        // #244 solved that with `androidStopForegroundOnPause: false`, which
        // held the service — and the wake lock — across *every* pause, including
        // one left paused-not-stopped for hours. The recovery guarantee is now
        // carried by the `playing` flag instead: [_isSessionPlaying] keeps
        // reporting `playing` across a transient-focus pause (bounded by the
        // controller), so the isolate survives exactly the interruption it has
        // to recover from, and an ordinary user pause demotes the service and
        // drops the wake lock right away. Foreground-while-playing (the
        // screen-off cutout fix, also in [_isSessionPlaying]) is unchanged.
        //
        // The notification stays non-ongoing. `stopForegroundOnPause: true`
        // would now let it be ongoing again (audio_service asserts
        // `!ongoing || stopForegroundOnPause`), but with the service demoted on
        // a real pause there is nothing to gain from making it undismissable, so
        // this is left exactly as #244 set it.
        androidNotificationOngoing: false,
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
    _attachedHandler = handler;
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

/// The handler currently attached to the platform media session, or null when
/// none is. Process-scoped because `audio_service`'s session is: it belongs to
/// the Android foreground service, not to any one app object.
LinthraAudioHandler? _attachedHandler;

/// Detaches the attached session handler, so a later [connectMediaSession] can
/// attach a fresh one.
///
/// Only for tests. Production never detaches on Android: the session outlives
/// the app object (see `AudioServiceMediaSessionBinding`). Disposing the old
/// handler is the point — it makes it inert, so a stale command can't reach a
/// controller it no longer speaks for.
@visibleForTesting
Future<void> resetAttachedMediaSession() async {
  final LinthraAudioHandler? handler = _attachedHandler;
  _attachedHandler = null;
  await handler?.dispose();
}
