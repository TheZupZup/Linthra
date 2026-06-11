import 'plex_api.dart';
import 'plex_exception.dart';

/// The stable client-identity a Plex client announces on every request.
///
/// Plex expects each client install to identify itself with a set of
/// `X-Plex-*` headers alongside the auth token: a stable per-install
/// [clientIdentifier] (a UUID) plus human-readable [product] / [version] /
/// [platform] / [device] strings. This is analogous to Jellyfin's device id +
/// `Authorization` client header. None of these are secret — they carry **no**
/// token and are safe to log — but they are required for a PMS to accept the
/// request, so they live in one typed place the client merges into its headers.
class PlexClientIdentity {
  const PlexClientIdentity({
    required this.clientIdentifier,
    required this.product,
    required this.version,
    required this.platform,
    required this.device,
  });

  // --- Header names: written once so a typo can't split a request. ---
  static const String clientIdentifierHeader = 'X-Plex-Client-Identifier';
  static const String productHeader = 'X-Plex-Product';
  static const String versionHeader = 'X-Plex-Version';
  static const String platformHeader = 'X-Plex-Platform';
  static const String deviceHeader = 'X-Plex-Device';

  /// A stable per-install UUID identifying this client to the server. Not a
  /// secret; it never grants access on its own.
  final String clientIdentifier;

  /// The product name reported to Plex (e.g. `Linthra`).
  final String product;

  /// The client/app version string.
  final String version;

  /// The platform the client runs on (e.g. `Android`).
  final String platform;

  /// A human-readable device name/model.
  final String device;

  /// The five `X-Plex-*` identity headers as a map, ready to merge with the
  /// `Accept` and `X-Plex-Token` headers the client adds per request. Carries no
  /// token, so the result is safe to log.
  Map<String, String> toHeaders() => <String, String>{
        clientIdentifierHeader: clientIdentifier,
        productHeader: product,
        versionHeader: version,
        platformHeader: platform,
        deviceHeader: device,
      };
}

/// The single seam through which Linthra talks HTTP to a Plex Media Server.
///
/// Every request to Plex goes through this interface, so the rest of the app
/// (the future authenticator, source, settings) depends only on it — never on
/// `http`, URLs, headers, or JSON. That keeps networking swappable and, just as
/// importantly, lets tests drive the whole feature with a fake client and canned
/// responses (no real server).
///
/// Each call takes the server [baseUrl] and the `X-Plex-Token` explicitly (a
/// `PlexSession` that bundles them is a later PR). Implementations send the
/// token as the `X-Plex-Token` **header** — never in these API URLs, which stay
/// token-free and safe to log — alongside the [PlexClientIdentity] headers and
/// `Accept: application/json`.
///
/// Implementations throw a [PlexException] (with a friendly message and a
/// [PlexErrorKind]) for every failure, and must **never** put the token into an
/// exception, a log, or any other output (header **or** query param). See
/// docs/plex.md → Token safety rules.
abstract interface class PlexClient {
  /// Fetches server identity from `GET /identity`, confirming the address is a
  /// reachable Plex Media Server (and recording its `machineIdentifier` /
  /// version). Backs the "Test connection" / token-verify flow.
  ///
  /// Throws [PlexException] ([PlexErrorKind.notPlex] when the body isn't a Plex
  /// `MediaContainer`, [PlexErrorKind.unauthorized] when the token is rejected,
  /// [PlexErrorKind.notReachable] when offline).
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  });

  /// Lists the server's library sections from `GET /library/sections`.
  ///
  /// Returns **all** sections (movies, shows, music, …); selecting the music
  /// ones ([PlexDirectory.isMusic]) is the caller's job, since the user picks
  /// which music libraries to include.
  Future<List<PlexDirectory>> fetchSections({
    required String baseUrl,
    required String token,
  });

  /// Lists every item of one music [itemType] (artist 8 / album 9 / track 10)
  /// in the section [sectionKey], walking **all pages** internally via
  /// `X-Plex-Container-Start` / `X-Plex-Container-Size` so the caller gets the
  /// complete set in one call.
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  });

  /// Fetches a single item from `GET /library/metadata/{ratingKey}`, including
  /// its `Media`/`Part` entries — the play-time lookup that turns an opaque
  /// `plex:<ratingKey>` into a playable [PlexPart.key].
  ///
  /// Throws [PlexException] ([PlexErrorKind.notFound] when the `ratingKey` no
  /// longer exists).
  Future<PlexMetadata> fetchMetadata({
    required String baseUrl,
    required String token,
    required String ratingKey,
  });
}
