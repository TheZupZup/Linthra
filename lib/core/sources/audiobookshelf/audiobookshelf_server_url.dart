import '../server_url_normalizer.dart';
import 'audiobookshelf_exception.dart';

/// Validates and normalizes the server address the user types into the
/// Audiobookshelf settings.
///
/// Intentionally pure string logic with no HTTP: it is the one place that
/// decides what a "valid Audiobookshelf address" looks like, so the
/// connection test and sign-in agree, and so the rules stay unit-testable
/// without a network. The design choices mirror the self-hosted case Linthra
/// already targets for Jellyfin/Plex/Subsonic:
///  - A bare host (`audiobooks.example.com`) defaults to **https**, because a
///    self-hosted server is usually reached over TLS and users rarely type
///    the scheme.
///  - A subpath is preserved (`example.com/audiobookshelf`), since reverse
///    proxies often mount the server under one.
///  - A trailing slash, query, and fragment are stripped so the result is a
///    clean base to append API paths to.
///
/// The trim/scheme/host/port/path mechanics are shared with the other
/// providers via [ServerUrlNormalizer]; only the user-facing error text below
/// is Audiobookshelf-specific.
abstract final class AudiobookshelfServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws an
  /// [AudiobookshelfException] of kind [AudiobookshelfErrorKind.invalidUrl]
  /// with a friendly reason when the address can't be used.
  static String normalize(String input) {
    final ParsedServerUrl parsed;
    try {
      parsed = ServerUrlNormalizer.parse(input);
    } on ServerUrlParseFailure catch (failure) {
      throw AudiobookshelfException.invalidUrl(_messageFor(failure.kind));
    }
    return parsed.toBase();
  }

  /// Like [normalize] but returns `null` instead of throwing, for callers
  /// that only need a yes/no (e.g. enabling a button) and don't want the
  /// reason.
  static String? tryNormalize(String input) {
    try {
      return normalize(input);
    } on AudiobookshelfException {
      return null;
    }
  }

  static String _messageFor(ServerUrlErrorKind kind) {
    switch (kind) {
      case ServerUrlErrorKind.empty:
        return 'Enter your Audiobookshelf server address, e.g. '
            'https://audiobooks.example.com';
      case ServerUrlErrorKind.unparseable:
        return "That doesn't look like a valid web address.";
      case ServerUrlErrorKind.unsupportedScheme:
        return 'The address must start with https:// (or http:// on a '
            'local network).';
      case ServerUrlErrorKind.emptyHost:
        return 'The address is missing a server name, e.g. '
            'audiobooks.example.com';
      case ServerUrlErrorKind.invalidPort:
        return 'The port must be a number from 1 to 65535, e.g. :13378';
    }
  }
}
