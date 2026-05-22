/// Canonical route paths. Reference these constants instead of raw strings so
/// navigation targets are discoverable and refactor-safe.
abstract final class AppRoutes {
  static const String library = '/library';
  static const String playlists = '/playlists';
  static const String downloads = '/downloads';
  static const String settings = '/settings';

  /// Full-screen now-playing view, pushed above the shell.
  static const String player = '/player';
}
