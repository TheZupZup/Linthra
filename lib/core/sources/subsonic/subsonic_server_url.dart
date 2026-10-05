import '../server_url_normalizer.dart';
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
///
/// The trim/scheme/host/port/path mechanics are shared with the other
/// providers via [ServerUrlNormalizer]; the `/rest` stripping above and the
/// user-facing error text below stay Subsonic-specific.
abstract final class SubsonicServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [SubsonicException] of kind [SubsonicErrorKind.invalidUrl] with a friendly
  /// reason when the address can't be used.
  static String normalize(String input) {
    final ParsedServerUrl parsed;
    try {
      parsed = ServerUrlNormalizer.parse(input);
    } on ServerUrlParseFailure catch (failure) {
      throw SubsonicException.invalidUrl(_messageFor(failure.kind));
    }
    return parsed.toBase(pathOverride: _stripRestSuffix(parsed.path));
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

  static String _messageFor(ServerUrlErrorKind kind) {
    switch (kind) {
      case ServerUrlErrorKind.empty:
        return 'Enter your server address, e.g. https://music.example.com';
      case ServerUrlErrorKind.unparseable:
        return "That doesn't look like a valid web address.";
      case ServerUrlErrorKind.unsupportedScheme:
        return 'The address must start with https:// (or http:// on a local network).';
      case ServerUrlErrorKind.emptyHost:
        return 'The address is missing a server name, e.g. music.example.com';
      case ServerUrlErrorKind.invalidPort:
        return 'The port must be a number from 1 to 65535, e.g. :4533';
    }
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
