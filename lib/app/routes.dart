/// Canonical route paths. Reference these constants instead of raw strings so
/// navigation targets are discoverable and refactor-safe.
abstract final class AppRoutes {
  static const String library = '/library';

  /// One album's tracks, reached from the Library's Albums tab. A child of
  /// [library] so it keeps the bottom nav and pops back into that tab; the
  /// derived album id rides as a path segment.
  static const String albumDetail = '/library/album';

  /// Builds the [albumDetail] location for a derived album [id].
  static String albumDetailPath(String id) =>
      '$albumDetail/${Uri.encodeComponent(id)}';

  /// One artist's catalog, reached from the Library's Artists tab. A child of
  /// [library] for the same reasons as [albumDetail].
  static const String artistDetail = '/library/artist';

  /// Builds the [artistDetail] location for a derived artist [id].
  static String artistDetailPath(String id) =>
      '$artistDetail/${Uri.encodeComponent(id)}';

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

  /// The "Report a bug" builder, reached from Settings. A child of [settings]
  /// so it keeps the bottom nav and pops back into that tab.
  static const String reportBug = '/settings/report-bug';

  /// Full-screen now-playing view, pushed above the shell.
  static const String player = '/player';
}
