import '../server_url_normalizer.dart';
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
///
/// The trim/scheme/host/port/path mechanics are shared with the other
/// providers via [ServerUrlNormalizer]; only the user-facing error text
/// below is Plex-specific.
abstract final class PlexServerUrl {
  /// Returns a clean base URL (no trailing slash) for [input], or throws a
  /// [PlexException] of kind [PlexErrorKind.invalidUrl] with a friendly reason
  /// when the address can't be used.
  static String normalize(String input) {
    final ParsedServerUrl parsed;
    try {
      parsed = ServerUrlNormalizer.parse(input);
    } on ServerUrlParseFailure catch (failure) {
      throw PlexException.invalidUrl(_messageFor(failure.kind));
    }
    return parsed.toBase();
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

  static String _messageFor(ServerUrlErrorKind kind) {
    switch (kind) {
      case ServerUrlErrorKind.empty:
        return 'Enter your Plex server address, e.g. http://192.168.1.10:32400';
      case ServerUrlErrorKind.unparseable:
        return "That doesn't look like a valid web address.";
      case ServerUrlErrorKind.unsupportedScheme:
        return 'The address must start with https:// (or http:// on a local network).';
      case ServerUrlErrorKind.emptyHost:
        return 'The address is missing a server name, e.g. 192.168.1.10:32400';
      case ServerUrlErrorKind.invalidPort:
        return 'The port must be a number from 1 to 65535, e.g. :32400';
    }
  }
}
