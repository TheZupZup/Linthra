import 'subsonic_exception.dart';

/// Validates and normalizes the server address the user types into the
/// Subsonic/Navidrome settings.
///
/// Intentionally pure string logic with no HTTP: it is the one place that
/// decides what a "valid Subsonic address" looks like, so the connection test
/// and sign-in agree, and so the rules stay unit-testable without a network.
/// The design choices mirror the self-hosted, reverse-proxied case Linthra
/// targets:
///  - A bare host (`music.example.com`) defaults to **https**, because a
///    self-hosted server is usually reached over TLS and users rarely type the
///    scheme.
///  - A subpath is preserved (`example.com/navidrome`), since reverse proxies
///    often mount the server under one; the `/rest/*.view` API paths append to
///    whatever base survives here.
///  - A trailing slash, query, and fragment are stripped so the result is a
///    clean base to append to.
///  - A trailing `/rest` is stripped, so a user who pastes the API path
///    (`http://host:4533/rest`) still gets a clean root — Linthra appends
///    `/rest/<method>.view` itself, so a kept `/rest` would double it into
///    `/rest/rest/ping.view`.
abstract final class SubsonicServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [SubsonicException] of kind [SubsonicErrorKind.invalidUrl] with a friendly
  /// reason when the address can't be used.
  static String normalize(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const SubsonicException.invalidUrl(
        'Enter your server address, e.g. https://music.example.com',
      );
    }

    // No scheme typed → assume https (the common self-hosted default).
    final String withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';

    final Uri? uri = Uri.tryParse(withScheme);
    if (uri == null) {
      throw const SubsonicException.invalidUrl(
        "That doesn't look like a valid web address.",
      );
    }

    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const SubsonicException.invalidUrl(
        'The address must start with https:// (or http:// on a local network).',
      );
    }

    if (uri.host.isEmpty) {
      throw const SubsonicException.invalidUrl(
        'The address is missing a server name, e.g. music.example.com',
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
    base.write(_stripRestSuffix(_trimTrailingSlashes(uri.path)));
    return base.toString();
  }

  /// Like [normalize] but returns `null` instead of throwing, for callers that
  /// only need a yes/no (e.g. enabling a button) and don't want the reason.
  static String? tryNormalize(String input) {
    try {
      return normalize(input);
    } on SubsonicException {
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

  /// Drops a trailing `/rest` segment (the Subsonic API mount) from an otherwise
  /// clean [path], so a pasted API path collapses back to the server root. Only
  /// a whole final segment named `rest` is removed (case-insensitive): `/rest`
  /// and `/navidrome/rest` lose it, while `/myrest` or `/restful` keep theirs.
  /// A Navidrome base is never itself `…/rest` (that path is always the API
  /// under the root), so this can't strip a legitimate reverse-proxy mount.
  static String _stripRestSuffix(String path) {
    const String marker = '/rest';
    if (path.toLowerCase() == marker) {
      return '';
    }
    if (path.toLowerCase().endsWith(marker)) {
      return path.substring(0, path.length - marker.length);
    }
    return path;
  }
}
