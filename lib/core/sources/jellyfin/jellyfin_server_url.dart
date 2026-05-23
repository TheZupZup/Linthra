import 'jellyfin_exception.dart';

/// Validates and normalizes the server address the user types into settings.
///
/// This is intentionally pure string logic with no HTTP: it is the one place
/// that decides what a "valid Jellyfin address" looks like, so both the
/// connection test and sign-in agree, and so the rules stay unit-testable
/// without a network.
///
/// Design choices that matter for the Cloudflare-proxied case this MVP targets:
///  - A bare host (`music.example.com`) defaults to **https**, because a
///    Cloudflare-proxied server is reached over TLS and users rarely type the
///    scheme.
///  - A subpath is preserved (`example.com/jellyfin`), since reverse proxies
///    often mount Jellyfin under one.
///  - A trailing slash, query, and fragment are stripped so the result is a
///    clean base to which API paths can be appended.
abstract final class JellyfinServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [JellyfinException] of kind [JellyfinErrorKind.invalidUrl] with a friendly
  /// reason when the address can't be used.
  static String normalize(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const JellyfinException.invalidUrl(
        'Enter your Jellyfin server address, e.g. https://music.example.com',
      );
    }

    // No scheme typed → assume https (the Cloudflare-proxied default).
    final String withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';

    final Uri? uri = Uri.tryParse(withScheme);
    if (uri == null) {
      throw const JellyfinException.invalidUrl(
        "That doesn't look like a valid web address.",
      );
    }

    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const JellyfinException.invalidUrl(
        'The address must start with https:// (or http:// on a local network).',
      );
    }

    if (uri.host.isEmpty) {
      throw const JellyfinException.invalidUrl(
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
    base.write(_trimTrailingSlashes(uri.path));
    return base.toString();
  }

  /// Like [normalize] but returns `null` instead of throwing, for callers that
  /// only need a yes/no (e.g. enabling a button) and don't want the reason.
  static String? tryNormalize(String input) {
    try {
      return normalize(input);
    } on JellyfinException {
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
