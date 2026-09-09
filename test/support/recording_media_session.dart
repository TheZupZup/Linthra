import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/core/repositories/favorites_repository.dart';
import 'package:linthra/core/repositories/music_library_repository.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/core/services/desktop_application_actions.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/media_session_binding.dart';
import 'package:linthra/core/services/playback_controller.dart';

/// A [MediaSessionBinding] test double that attaches without a platform.
///
/// `bootstrapApplication`'s default binding reads the real host, so on a Linux
/// machine — every CI runner included — a bootstrap test would open a real
/// session-bus connection through MPRIS. Nothing in these suites is about the
/// bus, and the connection attempt is as fast or as slow as the machine it runs
/// on, which is enough to change what a test sees mid-bootstrap. Pass one of
/// these instead and the attach is a single completed future.
///
/// It also records the detach, so the shutdown path that gives the session back
/// is asserted rather than assumed.
class RecordingMediaSessionBinding implements MediaSessionBinding {
  RecordingMediaSessionBinding({this.session});

  /// The session [attach] hands back, or null for a host that has none.
  final RecordingMediaSession? session;

  /// How many times startup asked for a session.
  int attachCount = 0;

  @override
  bool get isSupported => session != null;

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
    attachCount++;
    return session;
  }
}

/// A [MediaSession] that owns nothing and counts its releases.
class RecordingMediaSession implements MediaSession {
  int detachCount = 0;

  @override
  Future<void> detach() async {
    detachCount++;
  }
}
