/// Wire models for the plex.tv account API (the PIN sign-in flow).
///
/// These mirror the JSON shapes `https://plex.tv/api/v2` returns when asked for
/// JSON (`Accept: application/json`) and live behind the `PlexTvClient`;
/// nothing outside the Plex source should touch them. They are deliberately
/// separate from `plex_api.dart`: that file models the user's own Plex Media
/// Server, this one models Plex's account service — two different hosts with
/// two different envelopes (plex.tv answers bare objects/arrays, a PMS wraps
/// everything in `MediaContainer`).
///
/// **Secrets.** A [PlexPin] holds **no** token by design — the granted
/// `authToken` is read off the poll response by the client and handed straight
/// to the caller, never parked on a DTO. A [PlexResource] must carry its
/// per-server `accessToken` (that token is the very thing the flow is after),
/// so its [PlexResource.toString] redacts it, exactly like `PlexSession`. See
/// docs/plex.md → Token safety rules.
///
/// Only the fields Linthra uses are kept; the rest of each payload is ignored.
library;

/// One sign-in PIN minted by `POST https://plex.tv/api/v2/pins?strong=true`.
///
/// The [id] is what Linthra polls (`GET /api/v2/pins/{id}`) and the [code] is
/// what the plex.tv auth page consumes (woven into the `app.plex.tv/auth` URL
/// the browser opens). Neither is the auth token: the code is the *public*
/// half of the handshake — approving it requires the user's signed-in plex.tv
/// session in the browser — and the granted token is returned only by the
/// poll, bound to the `X-Plex-Client-Identifier` that created the PIN.
class PlexPin {
  const PlexPin({required this.id, required this.code, this.expiresInSeconds});

  /// The PIN's id, used to poll its status. Not a credential.
  final int id;

  /// The single-use code the browser auth page consumes. Short-lived and
  /// useless without the user approving it from their own plex.tv session.
  final String code;

  /// Seconds until plex.tv discards an unapproved PIN, when reported. The
  /// poll loop keeps its own (shorter) cap, so this is informational.
  final int? expiresInSeconds;

  /// Parses a `POST /api/v2/pins` body, or returns `null` when the [id] or
  /// [code] is missing (so the caller reports "unusable response" instead of
  /// polling a half-built PIN).
  static PlexPin? fromJson(Map<String, dynamic> json) {
    final int? id = _asInt(json['id']);
    final String? code = _asString(json['code']);
    if (id == null || code == null || code.isEmpty) return null;
    return PlexPin(
      id: id,
      code: code,
      expiresInSeconds: _asInt(json['expiresIn']),
    );
  }

  @override
  String toString() =>
      'PlexPin(id: $id, expiresInSeconds: $expiresInSeconds, code: <omitted>)';
}

/// One device on the user's Plex account, from
/// `GET https://plex.tv/api/v2/resources` — Linthra keeps the ones that
/// [providesServer] (the user's Plex Media Servers).
///
/// Carries the **server-scoped** [accessToken] (the narrowest credential that
/// works — see docs/plex.md → Token scope) plus the [connections] the server
/// can be reached on. [toString] redacts the token.
class PlexResource {
  const PlexResource({
    required this.name,
    required this.clientIdentifier,
    this.provides = '',
    this.accessToken,
    this.owned = true,
    this.productVersion,
    this.connections = const <PlexResourceConnection>[],
  });

  /// The server's friendly name (what the picker shows). Not secret.
  final String name;

  /// The device's stable identifier. For a Plex Media Server this is its
  /// `machineIdentifier` — the same value `GET /identity` reports. Not secret.
  final String clientIdentifier;

  /// Comma-separated capabilities (`"server"`, `"client,player"`, …).
  final String provides;

  /// The **server-scoped** token plex.tv minted for this user on this server —
  /// the credential Linthra prefers over the account token. Secret: never log,
  /// never put in a URL outside the documented stream/art builders.
  final String? accessToken;

  /// Whether the account owns this server (vs. one shared with it).
  final bool owned;

  /// The server's reported version, when present. Display only.
  final String? productVersion;

  /// The addresses this server may be reachable on, in plex.tv's order.
  final List<PlexResourceConnection> connections;

  /// Whether this resource is a Plex Media Server (it `provides` "server").
  bool get providesServer =>
      provides.split(',').map((String p) => p.trim()).contains('server');

  /// Parses one resource, or returns `null` when it lacks the identity fields
  /// a picker entry needs, so a single malformed entry can't break the
  /// listing. Malformed connections are skipped the same way.
  static PlexResource? fromJson(Map<String, dynamic> json) {
    final String? name = _asString(json['name']);
    final String? clientIdentifier = _asString(json['clientIdentifier']);
    if (clientIdentifier == null || clientIdentifier.isEmpty) return null;

    final Object? rawConnections = json['connections'];
    final List<PlexResourceConnection> connections = rawConnections is List
        ? <PlexResourceConnection>[
            for (final Object? entry in rawConnections)
              if (entry is Map<String, dynamic>)
                if (PlexResourceConnection.fromJson(entry)
                    case final PlexResourceConnection c)
                  c,
          ]
        : const <PlexResourceConnection>[];

    return PlexResource(
      name: name ?? '',
      clientIdentifier: clientIdentifier,
      provides: _asString(json['provides']) ?? '',
      accessToken: _asString(json['accessToken']),
      owned: _asBool(json['owned'], fallback: true),
      productVersion: _asString(json['productVersion']),
      connections: connections,
    );
  }

  /// Redacts the access token so a resource can be safely interpolated into
  /// logs or error messages without leaking the secret.
  @override
  String toString() => 'PlexResource(name: $name, '
      'clientIdentifier: $clientIdentifier, '
      'provides: $provides, '
      'owned: $owned, '
      'productVersion: $productVersion, '
      'connections: $connections, '
      'accessToken: ${accessToken == null ? 'null' : '<redacted>'})';
}

/// One address a [PlexResource] may be reachable on.
///
/// The [uri] is what Linthra probes (e.g. a `*.plex.direct` HTTPS address or a
/// LAN address); [local]/[relay] describe what kind of path it is so the probe
/// can keep the slow plex.tv relay as the last resort. No field is a secret.
class PlexResourceConnection {
  const PlexResourceConnection({
    required this.uri,
    this.local = false,
    this.relay = false,
    this.protocol,
  });

  /// The full base address to try (scheme + host + port). Token-free.
  final String uri;

  /// Whether plex.tv classified this address as on the server's LAN.
  final bool local;

  /// Whether this address goes through the plex.tv relay (reachable from
  /// anywhere but bandwidth-limited — a last resort for streaming).
  final bool relay;

  /// `http` / `https`, when reported.
  final String? protocol;

  /// Parses one connection, or returns `null` without a usable [uri].
  static PlexResourceConnection? fromJson(Map<String, dynamic> json) {
    final String? uri = _asString(json['uri']);
    if (uri == null || uri.isEmpty) return null;
    return PlexResourceConnection(
      uri: uri,
      local: _asBool(json['local']),
      relay: _asBool(json['relay']),
      protocol: _asString(json['protocol']),
    );
  }

  @override
  String toString() => 'PlexResourceConnection(uri: $uri, local: $local, '
      'relay: $relay, protocol: $protocol)';
}

/// One Plex Home user (profile) on the signed-in account, from
/// `GET https://plex.tv/api/v2/home/users`.
///
/// Plex Home lets several people share one account — the owner plus managed
/// profiles (a partner, a kids profile). Linthra lists them right after sign-in
/// so the person can pick **whose** library to use on this device before any
/// sync runs; the picked profile's own token (minted by the separate switch
/// call) then scopes every later fetch, so a restricted profile only ever syncs
/// the libraries it is allowed to see.
///
/// Carries **no** secret: the listing has no per-user token (that is granted by
/// the switch call), only the display fields and the [uuid] the switch
/// addresses. [protected] means switching into the profile needs its PIN.
class PlexHomeUser {
  const PlexHomeUser({
    required this.uuid,
    this.id,
    this.title = '',
    this.admin = false,
    this.restricted = false,
    this.protected = false,
  });

  /// The profile's stable UUID — what the switch endpoint addresses. Not a
  /// credential.
  final String uuid;

  /// The profile's numeric id, when reported. Not a credential.
  final int? id;

  /// The profile's display name (e.g. "Dad", "Kids"). Not a credential.
  final String title;

  /// Whether this profile is the account owner/admin. They already hold the
  /// account token, so switching into them needs no extra call.
  final bool admin;

  /// Whether this is a restricted (managed) profile — its token sees only the
  /// libraries the owner shared with it.
  final bool restricted;

  /// Whether switching into this profile requires its PIN.
  final bool protected;

  /// Parses one user, or returns `null` when it lacks the [uuid] the switch
  /// call needs, so a single malformed entry can't break the whole listing.
  static PlexHomeUser? fromJson(Map<String, dynamic> json) {
    final String? uuid = _asString(json['uuid']);
    if (uuid == null || uuid.isEmpty) return null;
    return PlexHomeUser(
      uuid: uuid,
      id: _asInt(json['id']),
      title: _asString(json['title']) ?? _asString(json['username']) ?? '',
      admin: _asBool(json['admin']),
      restricted: _asBool(json['restricted']),
      protected: _asBool(json['protected']),
    );
  }

  @override
  String toString() => 'PlexHomeUser(uuid: $uuid, id: $id, title: $title, '
      'admin: $admin, restricted: $restricted, protected: $protected)';
}

/// Reads a field that plex.tv may report as either a JSON string or a number,
/// returning a `String?` either way (mirrors `plex_api.dart`).
String? _asString(Object? value) {
  if (value is String) return value;
  if (value is num) return value.toString();
  return null;
}

/// Reads an int that may arrive as a number or numeric string.
int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Reads a boolean that may arrive as a real bool (api/v2 JSON), a 0/1 number,
/// or a `"0"`/`"1"`/`"true"`/`"false"` string (older envelopes) — so a quirky
/// serializer can't flip a connection's `relay`/`local` classification.
bool _asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    if (value == '1' || value.toLowerCase() == 'true') return true;
    if (value == '0' || value.toLowerCase() == 'false') return false;
  }
  return fallback;
}
