import '../platform/host_platform.dart';
import '../repositories/download_repository.dart';
import '../repositories/favorites_repository.dart';
import '../repositories/music_library_repository.dart';
import '../repositories/playlist_repository.dart';
import 'desktop_application_actions.dart';
import 'linthra_audio_handler.dart';
import 'media_artwork_source.dart';
import 'mpris/mpris_media_session.dart';
import 'playback_controller.dart';

/// Attaches Linthra's playback to the platform's media session — the thing that
/// draws the notification / lock-screen controls and answers Android Auto.
///
/// The session is a *platform integration*, not a playback engine: whether one
/// exists says nothing about whether audio can play. Android has one
/// (`audio_service`, behind [LinthraAudioHandler]); Linux has MPRIS, the
/// desktop equivalent, behind [MprisMediaSessionBinding].
///
/// The seam exists so startup can ask for a session without knowing which
/// platform it is on, and so the Android-only plugin is never *touched* on a
/// platform that has no implementation for it. Calling into `audio_service` off
/// Android does not merely fail; it fails after `AudioService.init` has already
/// half-configured its statics (it builds a cache manager and installs handler
/// callbacks before the first platform call throws), which is the kind of
/// half-initialised state that is easy to trip over later.
abstract interface class MediaSessionBinding {
  /// Whether this platform has a media session Linthra can attach to. Read by
  /// diagnostics; startup does not need to branch on it.
  bool get isSupported;

  /// Attaches the session, returning it when one is now live, else null.
  ///
  /// Best-effort and never throws: a platform without the native setup (or a
  /// test host with no bindings) returns null and the app carries on. The
  /// repositories are what Android Auto browses; they are ignored where there
  /// is no session.
  ///
  /// [application] is what the session's own Raise/Quit go to. MPRIS offers
  /// both to the desktop shell (#401), which is how a listener with no window
  /// on screen still has a visible way to bring Linthra back or shut it down.
  /// Passing nothing means the session advertises neither.
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  });
}

/// A live media session, and the one thing startup needs from it: how to let go.
///
/// Android's session belongs to `audio_service`'s foreground service and the
/// platform, so its detach is a no-op. Linux's is a session-bus connection and a
/// well-known name that Linthra owns and must give back — a player that exits
/// still holding `org.mpris.MediaPlayer2.linthra` leaves a ghost in every shell
/// that was listening.
abstract interface class MediaSession {
  /// Releases whatever the session holds. Idempotent, and never throws:
  /// shutdown runs it best-effort alongside every other teardown step.
  Future<void> detach();
}

/// A session that owns nothing releasable.
class InertMediaSession implements MediaSession {
  const InertMediaSession();

  @override
  Future<void> detach() async {}
}

/// The Android media session, backed by `audio_service`.
///
/// A thin wrapper over [connectMediaSession] so the `audio_service` import stays
/// confined to [LinthraAudioHandler]'s file and this one line of routing.
class AudioServiceMediaSessionBinding implements MediaSessionBinding {
  const AudioServiceMediaSessionBinding();

  @override
  bool get isSupported => true;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  }) async {
    final LinthraAudioHandler? handler = await connectMediaSession(
      controller,
      library,
      playlists: playlists,
      favorites: favorites,
      downloads: downloads,
      artwork: artwork,
    );
    // Inert on purpose: the Android session outlives this app object — it
    // belongs to `audio_service`'s foreground service and the platform, and the
    // graceful-shutdown path that would call detach is desktop-only anyway.
    return handler == null ? null : const InertMediaSession();
  }
}

/// The explicit "this platform has no media session" binding.
///
/// Used on macOS, Windows and anything else: MPRIS is a freedesktop interface,
/// so it is Linux's alone, and those platforms' own session APIs have no
/// binding yet. It is deliberately a real, named class rather than a silent
/// `if`: an inert session is a fact about the platform that diagnostics can
/// report and tests can assert on, and it makes the missing integration
/// visible in the code instead of implied by its absence.
class UnsupportedMediaSessionBinding implements MediaSessionBinding {
  const UnsupportedMediaSessionBinding();

  @override
  bool get isSupported => false;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  }) async =>
      null;
}

/// The default [MediaSessionBinding]: the real `audio_service` session on
/// Android, an inert one everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// `PlatformShareService` and `PlatformFolderPickerService`. The Android
/// delegate is only ever *reached* on Android, so `audio_service` cannot
/// initialise on a platform that has no implementation for it.
class PlatformMediaSessionBinding implements MediaSessionBinding {
  const PlatformMediaSessionBinding({
    HostPlatform? host,
    MediaSessionBinding androidBinding =
        const AudioServiceMediaSessionBinding(),
    MediaSessionBinding linuxBinding = const MprisMediaSessionBinding(),
    MediaSessionBinding fallbackBinding =
        const UnsupportedMediaSessionBinding(),
  })  : _host = host,
        _androidBinding = androidBinding,
        _linuxBinding = linuxBinding,
        _fallbackBinding = fallbackBinding;

  // Null means "read the real host". Resolved lazily rather than in the
  // initialiser list so the class stays const-constructible.
  final HostPlatform? _host;
  final MediaSessionBinding _androidBinding;
  final MediaSessionBinding _linuxBinding;
  final MediaSessionBinding _fallbackBinding;

  MediaSessionBinding get _delegate {
    switch (_host ?? HostPlatform.current) {
      case HostPlatform.android:
        return _androidBinding;
      case HostPlatform.linux:
        return _linuxBinding;
      case HostPlatform.ios:
      case HostPlatform.macOS:
      case HostPlatform.windows:
      case HostPlatform.other:
        // MPRIS is a freedesktop interface, so it is Linux's alone. macOS and
        // Windows have their own session APIs and no binding for them yet.
        return _fallbackBinding;
    }
  }

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  }) =>
      _delegate.attach(
        controller,
        library,
        playlists: playlists,
        favorites: favorites,
        downloads: downloads,
        artwork: artwork,
        application: application,
      );
}
