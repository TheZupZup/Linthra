import 'plex_exception.dart';

/// Validates and normalizes the server address the user types into the Plex
/// settings (phase 1 authenticates against a manually typed server URL + token).
///
/// Intentionally pure string logic with no HTTP: it is the one place that decides
/// what a "valid Plex address" looks like, so the connection test and sign-in
/// agree, and so the rules stay unit-testable without a network. Plex Media
/// Server normally listens on port 32400 and a self-hosted server is often
/// reached over a reverse proxy, so the choices mirror that:
///  - A bare host (`plex.example.com`) defaults to **https**, because a remote
///    server is reached over TLS and users rarely type the scheme. A LAN server
///    is typed with its scheme and port (`http://192.168.1.10:32400`).
///  - An explicit port is preserved, since a LAN server is reached by host:port.
///  - A subpath is preserved (`example.com/plex`), since a reverse proxy may
///    mount PMS under one; the API paths append to whatever base survives here.
///  - A trailing slash, query, and fragment are stripped so the result is a
///    clean base to append to (the endpoint builders concatenate paths directly).
abstract final class PlexServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [PlexException] of kind [PlexErrorKind.invalidUrl] with a friendly reason
  /// when the address can't be used.
  static String normalize(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const PlexException.invalidUrl(
        'Enter your Plex server address, e.g. http://192.168.1.10:32400',
      );
    }

    // No scheme typed → assume https (the common remote default).
    final String withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';

    final Uri? uri = Uri.tryParse(withScheme);
    if (uri == null) {
      throw const PlexException.invalidUrl(
        "That doesn't look like a valid web address.",
      );
    }

    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const PlexException.invalidUrl(
        'The address must start with https:// (or http:// on a local network).',
      );
    }

    if (uri.host.isEmpty) {
      throw const PlexException.invalidUrl(
        'The address is missing a server name, e.g. 192.168.1.10:32400',
      );
    }

    final StringBuffer base = StringBuffer()
      ..write(scheme)
      ..write('://')
      ..write(uri.host);
    if (uri.hasPort) {
      base
        ..write(':')
        ..write(uri.port);
    }
    base.write(_trimTrailingSlashes(uri.path));
    return base.toString();
  }

  /// Like [normalize] but returns `null` instead of throwing, for callers that
  /// only need a yes/no (e.g. enabling a button) and don't want the reason.
  static String? tryNormalize(String input) {
    try {
      return normalize(input);
    } on PlexException {
      return null;
    }
  }

  static String _trimTrailingSlashes(String path) {
    int end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
