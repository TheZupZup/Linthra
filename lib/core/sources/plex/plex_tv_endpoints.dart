/// Every plex.tv (account service) URL Linthra builds, in one place.
///
/// The sibling of `plex_endpoints.dart`, which owns the user's own Plex Media
/// Server paths: this file owns the **plex.tv** side of the PIN sign-in flow —
/// minting a PIN, polling it, listing the account's servers, and the
/// `app.plex.tv` page the browser opens. Keeping them separate keeps the
/// "which host is this request for" question answerable at a glance.
///
/// All builders are pure and **token-free**: the account token rides in the
/// `X-Plex-Token` *request header* (set by `HttpPlexTvClient`), never in a URL
/// built here, so every one of these URLs is safe to log. The auth-app URL
/// carries the PIN [authApp]`code` — the *public* half of the handshake, not a
/// credential (approving it requires the user's own plex.tv browser session).
/// See docs/plex.md → Authentication.
abstract final class PlexTvEndpoints {
  /// The plex.tv API origin. The PIN and resources endpoints live here.
  static const String plexTvBaseUrl = 'https://plex.tv';

  /// The hosted sign-in page origin the browser is handed.
  static const String authAppBaseUrl = 'https://app.plex.tv/auth';

  static const String _pinsPath = '/api/v2/pins';
  static const String _resourcesPath = '/api/v2/resources';
  static const String _homeUsersPath = '/api/v2/home/users';

  /// `POST https://plex.tv/api/v2/pins?strong=true` — mints a new sign-in PIN.
  ///
  /// `strong=true` asks for the long, link-style code the `app.plex.tv/auth`
  /// page consumes directly (the short 4-character codes are for TVs, where
  /// the user types them at plex.tv/link — Linthra opens the browser instead,
  /// so the user never sees or types a code).
  static Uri pins() => Uri.parse('$plexTvBaseUrl$_pinsPath?strong=true');

  /// `GET https://plex.tv/api/v2/pins/{id}` — polls one PIN until the user
  /// approves it in the browser and the response carries an `authToken`.
  static Uri pin(int id) => Uri.parse('$plexTvBaseUrl$_pinsPath/$id');

  /// `GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1` —
  /// lists the account's devices, each Plex Media Server with its
  /// **server-scoped** `accessToken` and the connection addresses it can be
  /// reached on. `includeHttps` asks for the `*.plex.direct` HTTPS addresses;
  /// `includeRelay` includes the plex.tv relay as a last-resort path.
  static Uri resources() =>
      Uri.parse('$plexTvBaseUrl$_resourcesPath?includeHttps=1&includeRelay=1');

  /// `GET https://plex.tv/api/v2/home/users` — lists the account's Plex Home
  /// users (profiles). The account token rides in the `X-Plex-Token`
  /// **header**, so this URL stays token-free and loggable.
  static Uri homeUsers() => Uri.parse('$plexTvBaseUrl$_homeUsersPath');

  /// `POST https://plex.tv/api/v2/home/users/{uuid}/switch` — switches into a
  /// Plex Home user, returning that profile's own auth token.
  ///
  /// A protected profile needs its [pin] (a short, low-entropy profile PIN —
  /// **not** the account `X-Plex-Token`); it rides as a query param because
  /// that is the shape the endpoint expects. The account token still rides in
  /// the `X-Plex-Token` header, so the URL never carries it.
  static Uri switchHomeUser({required String uuid, String? pin}) {
    final String base =
        '$plexTvBaseUrl$_homeUsersPath/${Uri.encodeComponent(uuid)}/switch';
    if (pin == null || pin.isEmpty) return Uri.parse(base);
    return Uri.parse('$base?pin=${Uri.encodeComponent(pin)}');
  }

  /// The `https://app.plex.tv/auth#?…` page the browser opens so the user can
  /// approve the sign-in with their own Plex account.
  ///
  /// The parameters ride in the **fragment** (after `#`) — that is the shape
  /// the hosted page expects (it reads them client-side; a fragment is never
  /// sent to a server in a request line, so they also can't land in an access
  /// log). `clientID` must be the same `X-Plex-Client-Identifier` that minted
  /// the PIN — plex.tv binds the PIN to it — and `context[device][product]`
  /// names the app on the approval screen. Values are percent-encoded
  /// (`Uri.encodeComponent`, so a space is `%20`, matching how the page's own
  /// client parses the fragment).
  static Uri authApp({
    required String clientIdentifier,
    required String code,
    required String product,
  }) {
    final String params = <String>[
      'clientID=${Uri.encodeComponent(clientIdentifier)}',
      'code=${Uri.encodeComponent(code)}',
      'context%5Bdevice%5D%5Bproduct%5D=${Uri.encodeComponent(product)}',
    ].join('&');
    return Uri.parse('$authAppBaseUrl#?$params');
  }
}
