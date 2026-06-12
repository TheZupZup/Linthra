import 'plex_tv_api.dart';

/// The single seam through which Linthra talks HTTP to **plex.tv** (the
/// account service behind the PIN sign-in flow).
///
/// The sibling of `PlexClient`, which talks to the user's own Plex Media
/// Server: the rest of the app (the PIN auth coordinator, the settings
/// controller) depends only on this interface — never on `http`, URLs,
/// headers, or JSON — so the whole sign-in flow is testable with a fake client
/// and canned responses.
///
/// Implementations send the `X-Plex-*` client-identity headers on every call
/// (plex.tv binds a PIN to the `X-Plex-Client-Identifier` that minted it) and
/// the account token — where one is needed at all — as the `X-Plex-Token`
/// **header**, never in a URL. Every failure becomes a `PlexException` whose
/// message is static and token-free; no token (account or server-scoped) may
/// ever reach an exception, a log, or any other output. See docs/plex.md →
/// Token safety rules.
abstract interface class PlexTvClient {
  /// Mints a new sign-in PIN via `POST /api/v2/pins?strong=true`. No token is
  /// sent — this is the very first step of obtaining one.
  ///
  /// Throws `PlexException` (`notReachable` when plex.tv can't be reached,
  /// `unexpected` for an unusable body).
  Future<PlexPin> createPin();

  /// Polls one PIN via `GET /api/v2/pins/{id}`: returns the granted account
  /// auth token once the user approved the sign-in in the browser, or `null`
  /// while the approval is still pending.
  ///
  /// The returned token is a secret — the caller must hand it on (to fetch
  /// resources / build a session) and never log or persist it as-is.
  ///
  /// Throws `PlexException.signInExpired` when plex.tv no longer knows the
  /// PIN (HTTP 404 — it lapsed before approval; polling it again can never
  /// succeed), and the usual token-free failures otherwise.
  Future<String?> checkPin(int pinId);

  /// Lists the account's devices via `GET /api/v2/resources` (HTTPS and relay
  /// addresses included). The caller keeps the ones that provide `server`.
  ///
  /// [token] is the account token granted by [checkPin]; it rides in the
  /// `X-Plex-Token` header. Each returned server carries its own
  /// server-scoped `accessToken` — the credential Linthra actually keeps.
  Future<List<PlexResource>> fetchResources({required String token});
}
