/// Static, build-time app metadata.
abstract final class AppInfo {
  static const String name = 'Linthra';
  static const String tagline = 'Your music, beautifully yours.';

  /// App version, kept in step with `pubspec.yaml`. Sent (informationally) to
  /// Jellyfin as the client version in the auth header so the server can label
  /// this device in its dashboard.
  static const String version = '0.1.0';
}
