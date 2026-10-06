import '../server_url_normalizer.dart';
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
///
/// The trim/scheme/host/port/path mechanics are shared with the other
/// providers via [ServerUrlNormalizer]; only the user-facing error text
/// below is Jellyfin-specific.
abstract final class JellyfinServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [JellyfinException] of kind [JellyfinErrorKind.invalidUrl] with a friendly
  /// reason when the address can't be used.
  static String normalize(String input) {
    final ParsedServerUrl parsed;
    try {
      parsed = ServerUrlNormalizer.parse(input);
    } on ServerUrlParseFailure catch (failure) {
      throw JellyfinException.invalidUrl(_messageFor(failure.kind));
    }
    return parsed.toBase();
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

  static String _messageFor(ServerUrlErrorKind kind) {
    switch (kind) {
      case ServerUrlErrorKind.empty:
        return 'Enter your Jellyfin server address, e.g. https://music.example.com';
      case ServerUrlErrorKind.unparseable:
        return "That doesn't look like a valid web address.";
      case ServerUrlErrorKind.unsupportedScheme:
        return 'The address must start with https:// (or http:// on a local network).';
      case ServerUrlErrorKind.emptyHost:
        return 'The address is missing a server name, e.g. music.example.com';
      case ServerUrlErrorKind.invalidPort:
        return 'The port must be a number from 1 to 65535, e.g. :8096';
    }
  }
}
