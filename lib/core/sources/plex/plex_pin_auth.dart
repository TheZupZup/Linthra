import '../../models/plex_session.dart';
import 'plex_api.dart';
import 'plex_client.dart';
import 'plex_exception.dart';
import 'plex_server_url.dart';
import 'plex_tv_api.dart';
import 'plex_tv_client.dart';
import 'plex_tv_endpoints.dart';

/// One started browser sign-in: the PIN to poll and the page the browser was
/// (or can again be) handed.
///
/// Holds no token — the PIN [code] inside [authUrl] is the public half of the
/// handshake (approving it requires the user's own plex.tv browser session),
/// and the granted token only ever travels through
/// [PlexPinAuth.waitForAuthToken]'s return value.
class PlexPinLink {
  const PlexPinLink({required this.pinId, required this.authUrl});

  /// The plex.tv PIN id this flow polls.
  final int pinId;

  /// The `app.plex.tv/auth` page to open in the user's browser.
  final Uri authUrl;

  @override
  String toString() => 'PlexPinLink(pinId: $pinId)';
}

/// The seam the poll loop waits through, injectable so tests can run the loop
/// without real delays. Production uses `Future.delayed`.
typedef PlexPinAuthWait = Future<void> Function(Duration duration);

/// The plex.tv PIN sign-in flow, end to end: mint a PIN and the browser URL
/// ([begin]), poll until the user approves it ([waitForAuthToken]), list the
/// account's Plex Media Servers ([fetchServers]), and turn the picked server
/// into a verified, persistable [PlexSession] ([connectToServer]).
///
/// Every plex.tv-specific auth detail lives here, behind plain methods, so the
/// settings controller only orchestrates UI state — mirroring how the manual
/// flow keeps its details in [PlexAuthenticator] (which remains the advanced /
/// fallback path).
///
/// Token safety: the account token returned by [waitForAuthToken] exists to be
/// handed straight back into [fetchServers]/[connectToServer]; it is never
/// stored on this class, never logged, and never reaches an exception (every
/// failure is a static, token-free [PlexException]). [connectToServer] prefers
/// each server's **server-scoped** `accessToken` over the account token — the
/// narrowest credential that works — and only the resulting session (whose
/// `toString` redacts its token) carries a secret out of this class. See
/// docs/plex.md → Token safety rules.
class PlexPinAuth {
  PlexPinAuth({
    required PlexTvClient tvClient,
    required PlexClient serverClient,
    required PlexClientIdentity identity,
    PlexPinAuthWait wait = Future.delayed,
  })  : _tvClient = tvClient,
        _serverClient = serverClient,
        _identity = identity,
        _wait = wait;

  final PlexTvClient _tvClient;
  final PlexClient _serverClient;
  final PlexClientIdentity _identity;
  final PlexPinAuthWait _wait;

  /// How often the granted-token poll asks plex.tv about the PIN. Plex's own
  /// guidance is ~1s; 2s is plenty responsive for a flow that involves a
  /// browser round-trip, and halves the request load.
  static const Duration pollInterval = Duration(seconds: 2);

  /// How long the poll keeps trying before giving up as expired. Slightly
  /// inside plex.tv's own ~30-minute PIN lifetime, and generous enough for a
  /// password manager + 2FA round-trip in the browser.
  static const Duration pollTimeout = Duration(minutes: 15);

  /// How many *consecutive* failed polls (plex.tv unreachable, 5xx, …) are
  /// tolerated before the flow gives up. Polling happens while the user is
  /// away in the browser, where a connectivity blip is normal — a single
  /// failed request must not kill the sign-in — but a plex.tv that hasn't
  /// answered for ~30s isn't coming back within the user's patience.
  static const int maxConsecutivePollFailures = 15;

  /// Mints a PIN and builds the browser page for it. The `clientID` woven
  /// into the URL is the same `X-Plex-Client-Identifier` the client sends on
  /// every request — plex.tv binds the PIN to it.
  Future<PlexPinLink> begin() async {
    final PlexPin pin = await _tvClient.createPin();
    return PlexPinLink(
      pinId: pin.id,
      authUrl: PlexTvEndpoints.authApp(
        clientIdentifier: _identity.clientIdentifier,
        code: pin.code,
        product: _identity.product,
      ),
    );
  }

  /// Polls the PIN until the user approves the sign-in in the browser,
  /// returning the granted **account** token — or `null` when [isCancelled]
  /// reports the caller no longer wants the result (the user cancelled, or a
  /// newer attempt superseded this one).
  ///
  /// Transient failures (plex.tv unreachable, a 5xx) are tolerated and the
  /// poll continues — the app may be backgrounded behind the browser while
  /// connectivity flaps — but [maxConsecutivePollFailures] in a row rethrows
  /// the last failure, and a PIN plex.tv no longer knows (404) or a poll that
  /// outlives [pollTimeout] throws [PlexException.signInExpired].
  Future<String?> waitForAuthToken(
    int pinId, {
    bool Function()? isCancelled,
  }) async {
    final int maxAttempts =
        pollTimeout.inMilliseconds ~/ pollInterval.inMilliseconds;
    int consecutiveFailures = 0;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (isCancelled?.call() ?? false) return null;
      try {
        final String? token = await _tvClient.checkPin(pinId);
        consecutiveFailures = 0;
        if (token != null && token.isNotEmpty) {
          return token;
        }
      } on PlexException catch (error) {
        // A 401/403/404 from the PIN endpoint is definitive (the PIN lapsed
        // or was refused); anything else is treated as transient.
        if (error.kind == PlexErrorKind.unauthorized) rethrow;
        consecutiveFailures++;
        if (consecutiveFailures >= maxConsecutivePollFailures) rethrow;
      }
      if (isCancelled?.call() ?? false) return null;
      await _wait(pollInterval);
    }
    throw PlexException.signInExpired();
  }

  /// Lists the account's Plex Media Servers (resources that provide
  /// `server`), owned servers first so the picker leads with the user's own.
  Future<List<PlexResource>> fetchServers({
    required String accountToken,
  }) async {
    final List<PlexResource> resources =
        await _tvClient.fetchResources(token: accountToken);
    final List<PlexResource> servers = <PlexResource>[
      for (final PlexResource resource in resources)
        if (resource.providesServer) resource,
    ];
    return <PlexResource>[
      for (final PlexResource server in servers)
        if (server.owned) server,
      for (final PlexResource server in servers)
        if (!server.owned) server,
    ];
  }

  /// Lists the account's Plex Home users (profiles) so the caller can offer a
  /// "whose library?" picker before any sync runs. A thin pass-through to the
  /// tv client — the account [accountToken] rides in the header; the listing
  /// carries no per-user token. An account without Plex Home simply reports one
  /// user (the owner), which the caller treats as "nothing to pick".
  Future<List<PlexHomeUser>> fetchHomeUsers({
    required String accountToken,
  }) {
    return _tvClient.fetchHomeUsers(token: accountToken);
  }

  /// Switches into the Plex Home user [uuid], returning that profile's own
  /// account token — the credential the rest of the flow then uses, so the
  /// fetched servers and the persisted session are scoped to what the profile
  /// may see. [pin] is required for a protected profile.
  ///
  /// The owner/admin already holds [accountToken], so the caller skips this for
  /// them. Token safety mirrors [waitForAuthToken]: the returned token is the
  /// only secret that leaves here, never logged and never put in an exception.
  Future<String> switchToUser({
    required String uuid,
    required String accountToken,
    String? pin,
  }) {
    return _tvClient.switchHomeUser(
      uuid: uuid,
      token: accountToken,
      pin: pin,
    );
  }

  /// Verifies the picked [server] is reachable and returns a session for it.
  ///
  /// Token choice: the server's own **server-scoped** `accessToken` when
  /// plex.tv provided one, falling back to the account token only when it
  /// didn't — the narrowest blast radius that works (docs/plex.md → Token
  /// scope). The session starts with no selected library sections; the
  /// existing library picker fills them.
  ///
  /// Connections are probed one at a time in plex.tv's order, except that
  /// relay addresses go last (they work from anywhere but are
  /// bandwidth-capped — only worth it when nothing direct answers).
  /// Unreachable or non-Plex answers move on to the next address. An address
  /// that answers as a **different** server (its `machineIdentifier` doesn't
  /// match the picked [server]'s `clientIdentifier`) is skipped too: a stale
  /// or reused advertised address can reach another Plex server that — under
  /// the account-token fallback — accepts the same account-wide token, and
  /// persisting it would silently bind the user to the wrong server.
  ///
  /// A rejected token (HTTP 401/403) on a single address does **not** abort
  /// the probe either: that same stale/reused address can land on a different
  /// server that rejects this server-scoped token, while a later advertised
  /// address still reaches the picked one. Every address is tried; if none
  /// matches, a token rejection seen on any of them is reported in preference
  /// to a generic unreachable error (it's the more actionable failure —
  /// reconnect to re-grant the token), otherwise
  /// [PlexException.serverUnreachable].
  Future<PlexSession> connectToServer({
    required PlexResource server,
    required String accountToken,
  }) async {
    final String? accessToken = server.accessToken;
    final String token = (accessToken != null && accessToken.isNotEmpty)
        ? accessToken
        : accountToken;

    final List<PlexResourceConnection> ordered = <PlexResourceConnection>[
      for (final PlexResourceConnection c in server.connections)
        if (!c.relay) c,
      for (final PlexResourceConnection c in server.connections)
        if (c.relay) c,
    ];

    // Remembered across the whole probe: a 401/403 from any single address is
    // not fatal on its own (it may come from a stale address on a different
    // server), but if nothing matches it's the failure worth surfacing.
    PlexException? rejected;

    for (final PlexResourceConnection connection in ordered) {
      final String baseUrl;
      try {
        baseUrl = PlexServerUrl.normalize(connection.uri);
      } on PlexException {
        // A malformed advertised address can't be probed; try the next one.
        continue;
      }
      final PlexServerIdentity identity;
      try {
        identity = await _serverClient.fetchIdentity(
          baseUrl: baseUrl,
          token: token,
        );
      } on PlexException catch (error) {
        // Don't let one address's rejection abort the rest: a stale/reused
        // address can reach a *different* server that rejects this
        // server-scoped token, while a later address still reaches the picked
        // one. Remember it and keep probing.
        if (error.kind == PlexErrorKind.unauthorized) {
          rejected = error;
        }
        continue;
      }
      // Confirm this address actually reached the server the user picked. A
      // PMS reports its `machineIdentifier` as the resource's
      // `clientIdentifier`, so a mismatch means a stale/reused address landed
      // on some other server (reachable here only because the account-token
      // fallback is accepted account-wide) — skip it rather than persist the
      // wrong server under the picked one's name.
      if (identity.machineIdentifier != server.clientIdentifier) {
        continue;
      }
      return PlexSession(
        baseUrl: baseUrl,
        token: token,
        machineIdentifier: identity.machineIdentifier,
        serverName: server.name.isNotEmpty ? server.name : null,
        serverVersion: identity.version ?? server.productVersion,
      );
    }
    // Nothing reached the picked server. A token rejection on any address is
    // the more actionable outcome (reconnect/re-grant) than "unreachable".
    if (rejected != null) {
      throw rejected;
    }
    throw PlexException.serverUnreachable();
  }
}
