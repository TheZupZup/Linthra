/// Canonical route paths. Reference these constants instead of raw strings so
/// navigation targets are discoverable and refactor-safe.
abstract final class AppRoutes {
  static const String library = '/library';
  static const String playlists = '/playlists';

  /// Liked tracks, reached from the Playlists tab. A child of [playlists] so it
  /// keeps the bottom nav and pops back into that tab.
  static const String favorites = '/playlists/favorites';

  /// A single playlist's tracks. A child of [playlists] (so it keeps the bottom
  /// nav and pops back into that tab); the playlist id rides as a path segment.
  static const String playlistDetail = '/playlists/detail';

  /// Builds the [playlistDetail] location for a given playlist [id].
  static String playlistDetailPath(String id) => '$playlistDetail/$id';

  static const String downloads = '/downloads';
  static const String settings = '/settings';

  /// Full-screen now-playing view, pushed above the shell.
  static const String player = '/player';
}
