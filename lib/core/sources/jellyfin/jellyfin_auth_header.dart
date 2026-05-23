import '../../app_info.dart';

/// Builds the value of the `Authorization` header Jellyfin expects.
///
/// Jellyfin authenticates with a `MediaBrowser` scheme that identifies the
/// client and (once signed in) carries the access token. Kept pure and separate
/// from [HttpJellyfinClient] so the exact format is unit-testable, and so the
/// token is only ever woven into a request header here — never logged.
abstract final class JellyfinAuthHeader {
  /// The header for an unauthenticated call (connection test, sign-in): it
  /// identifies the client and device but carries no token.
  static String forClient(String deviceId) => _build(deviceId, null);

  /// The header for an authenticated call: identical to [forClient] plus the
  /// session [token].
  static String forToken(String deviceId, String token) =>
      _build(deviceId, token);

  static String _build(String deviceId, String? token) {
    final StringBuffer header = StringBuffer()
      ..write('MediaBrowser Client="')
      ..write(AppInfo.name)
      ..write('", Device="')
      ..write(AppInfo.name)
      ..write('", DeviceId="')
      ..write(deviceId)
      ..write('", Version="')
      ..write(AppInfo.version)
      ..write('"');
    if (token != null && token.isNotEmpty) {
      header
        ..write(', Token="')
        ..write(token)
        ..write('"');
    }
    return header.toString();
  }
}
