import 'package:flutter/foundation.dart';

/// An authenticated Plex session: everything needed to make further authorized
/// requests to one Plex Media Server, kept in one immutable value so it can be
/// persisted as a unit and passed to the source.
///
/// Security — the token is the whole credential. Plex's `X-Plex-Token` rides in
/// an `X-Plex-Token` *header* for API calls and in a *query param* for stream/art
/// URLs, so a single leak exposes everything the token can reach. Linthra stores
/// **only** the token — preferring a **server-scoped** token over an account-wide
/// one, the narrowest blast radius if it ever leaks — plus the small amount of
/// server metadata needed to talk to that one server. The token is persisted only
/// through the `PlexSessionStore` (the production binding is encrypted on-device)
/// and must never be logged or shown in the UI. [toString] deliberately redacts
/// it so an accidental interpolation can't leak it into logs or error text.
///
/// No password is involved (phase 1 pastes a token directly), and an
/// authenticated stream/art URL is **never** part of a session — those are minted
/// on demand at play/render time and discarded. See docs/plex.md → Token safety
/// rules.
class PlexSession {
  const PlexSession({
    required this.baseUrl,
    required this.token,
    required this.machineIdentifier,
    this.serverName,
    this.serverVersion,
    this.selectedSectionKeys = const <String>[],
  });

  /// Clean base URL of the server (no trailing slash), e.g.
  /// `https://plex.example.com:32400`. API paths and the (token-bearing)
  /// stream/art URLs are built from this.
  final String baseUrl;

  /// Secret, server-scoped `X-Plex-Token`. Sent as the `X-Plex-Token` header on
  /// API calls and woven into stream/art query params only at play/render time.
  /// Never log this.
  final String token;

  /// The server's stable `machineIdentifier` (from `GET /identity`), used to
  /// recognise the same server again. Not a secret.
  final String machineIdentifier;

  /// The server's friendly name, when known. `GET /identity` doesn't report
  /// one, so the manual flow leaves this `null`; the plex.tv discovery flow (a
  /// follow-up) provides it. Not secret, display only.
  final String? serverName;

  /// The server's reported version (from `/identity`), when known. Carried so the
  /// diagnostics report can show it after a restart. Not secret, display only.
  final String? serverVersion;

  /// `key`s of the music library sections the user chose to include. Starts
  /// empty at sign-in — the library picker (a later PR) fills it — and scopes
  /// the future artist/album/track fetches (see docs/plex.md → MusicSource
  /// mapping). Section keys are not secret.
  final List<String> selectedSectionKeys;

  PlexSession copyWith({
    String? baseUrl,
    String? token,
    String? machineIdentifier,
    String? serverName,
    String? serverVersion,
    List<String>? selectedSectionKeys,
  }) {
    return PlexSession(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      machineIdentifier: machineIdentifier ?? this.machineIdentifier,
      serverName: serverName ?? this.serverName,
      serverVersion: serverVersion ?? this.serverVersion,
      selectedSectionKeys: selectedSectionKeys ?? this.selectedSectionKeys,
    );
  }

  /// Serializes for the session store. The token is included because the only
  /// caller is the (encrypted) store; do not route this through any plaintext
  /// sink.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'token': token,
        'machineIdentifier': machineIdentifier,
        if (serverName != null) 'serverName': serverName,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (selectedSectionKeys.isNotEmpty)
          'selectedSectionKeys': selectedSectionKeys,
      };

  /// Rebuilds a session from [toJson] output, or returns `null` if any required
  /// field is missing/blank (e.g. a partially written or corrupted record), so
  /// the app treats it as "not signed in" rather than crashing.
  static PlexSession? fromJson(Map<String, dynamic> json) {
    final String? baseUrl = json['baseUrl'] as String?;
    final String? token = json['token'] as String?;
    final String? machineIdentifier = json['machineIdentifier'] as String?;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    if (token == null || token.isEmpty) return null;
    if (machineIdentifier == null || machineIdentifier.isEmpty) return null;
    // Records persisted before section selection existed simply lack the key;
    // they load with an empty selection rather than failing.
    final Object? rawKeys = json['selectedSectionKeys'];
    final List<String> selectedSectionKeys = rawKeys is List
        ? rawKeys.whereType<String>().toList(growable: false)
        : const <String>[];
    return PlexSession(
      baseUrl: baseUrl,
      token: token,
      machineIdentifier: machineIdentifier,
      serverName: json['serverName'] as String?,
      serverVersion: json['serverVersion'] as String?,
      selectedSectionKeys: selectedSectionKeys,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlexSession &&
          other.baseUrl == baseUrl &&
          other.token == token &&
          other.machineIdentifier == machineIdentifier &&
          other.serverName == serverName &&
          other.serverVersion == serverVersion &&
          listEquals(other.selectedSectionKeys, selectedSectionKeys));

  @override
  int get hashCode => Object.hash(
        baseUrl,
        token,
        machineIdentifier,
        serverName,
        serverVersion,
        Object.hashAll(selectedSectionKeys),
      );

  /// Redacts the token so the session can be safely interpolated into logs or
  /// error messages without leaking the secret.
  @override
  String toString() => 'PlexSession(baseUrl: $baseUrl, '
      'machineIdentifier: $machineIdentifier, '
      'serverName: $serverName, '
      'serverVersion: $serverVersion, '
      'selectedSectionKeys: $selectedSectionKeys, token: <redacted>)';
}
