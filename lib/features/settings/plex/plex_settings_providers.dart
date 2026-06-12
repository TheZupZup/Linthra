import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/sources/plex/http_plex_client.dart';
import '../../../core/sources/plex/http_plex_tv_client.dart';
import '../../../core/sources/plex/plex_authenticator.dart';
import '../../../core/sources/plex/plex_client.dart';
import '../../../core/sources/plex/plex_pin_auth.dart';
import '../../../core/sources/plex/plex_tv_client.dart';

/// A fallback `X-Plex-Client-Identifier`, generated once per app launch.
///
/// Used only until a session exists: the identifier announced at sign-in is
/// persisted **with** the session (see `PlexSession.clientIdentifier`), so
/// every later launch presents the same client identity to the server —
/// mirroring how `JellyfinAuthenticator` mints a `deviceId` per sign-in and
/// `JellyfinSession` keeps it. Same generator shape as Jellyfin's: 16 secure
/// random bytes as hex. Not a secret; it never grants access on its own.
final _launchPlexClientIdentifierProvider = Provider<String>((ref) {
  final Random rng = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
});

/// Publishes the `X-Plex-Client-Identifier` persisted with the current
/// session, or `null` when no session exists (the launch fallback then
/// applies).
///
/// A deliberately tiny channel between the settings controller (which loads /
/// creates / clears the session, and writes here) and
/// [plexClientIdentityProvider] (which reads here): the identity must NOT
/// depend on the controller directly, because the controller itself reaches
/// the client (identity → client → authenticator → controller would be a
/// dependency cycle). Not a secret.
class PlexPersistedClientIdentifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Announces [identifier] as the persisted client identifier (`null` =
  /// signed out, fall back to the per-launch one).
  void publish(String? identifier) => state = identifier;
}

final plexPersistedClientIdentifierProvider =
    NotifierProvider<PlexPersistedClientIdentifier, String?>(
  PlexPersistedClientIdentifier.new,
);

/// The `X-Plex-*` client identity Linthra announces on every Plex request.
///
/// Plex expects each client install to identify itself alongside the auth
/// token (see `PlexClientIdentity`). The identifier prefers the one persisted
/// with the current session — stable across restarts for the life of the
/// connection — and falls back to a fresh per-launch value before the first
/// sign-in. The remaining fields are static app metadata. None of this is
/// secret.
final plexClientIdentityProvider = Provider<PlexClientIdentity>((ref) {
  final String? persisted = ref.watch(plexPersistedClientIdentifierProvider);
  return PlexClientIdentity(
    clientIdentifier:
        persisted ?? ref.watch(_launchPlexClientIdentifierProvider),
    product: AppInfo.name,
    version: AppInfo.version,
    platform: _platformName(),
    device: AppInfo.name,
  );
});

/// The `X-Plex-Platform` value for the platform this build runs on.
String _platformName() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Android';
    case TargetPlatform.iOS:
      return 'iOS';
    case TargetPlatform.linux:
      return 'Linux';
    case TargetPlatform.macOS:
      return 'macOS';
    case TargetPlatform.windows:
      return 'Windows';
    case TargetPlatform.fuchsia:
      return 'Fuchsia';
  }
}

/// The HTTP seam for all Plex networking.
///
/// Defaults to the real [HttpPlexClient]; tests override it with a
/// `FakePlexClient` that returns canned responses, so the whole settings/auth
/// flow can be exercised without a server. This is the single place production
/// wires the concrete client — `main` needs no override because the default is
/// already the real one.
final plexClientProvider = Provider<PlexClient>((ref) {
  return HttpPlexClient(identity: ref.watch(plexClientIdentityProvider));
});

/// Coordinates URL validation + the manual token verify on top of
/// [plexClientProvider].
///
/// The settings controller depends on this rather than on the client directly,
/// keeping authentication (produce a session) separate from the controller's
/// orchestration (when to test, connect, persist, clear). This is the
/// **manual / advanced** path; the primary "Connect with Plex" flow lives
/// behind [plexPinAuthProvider].
final plexAuthenticatorProvider = Provider<PlexAuthenticator>((ref) {
  return PlexAuthenticator(ref.watch(plexClientProvider));
});

/// The HTTP seam for all **plex.tv** (account service) networking.
///
/// Defaults to the real [HttpPlexTvClient]; tests override it with a fake
/// returning canned PIN/resource responses, so the whole "Connect with Plex"
/// flow runs without plex.tv. Watches the same client identity as the PMS
/// client: plex.tv binds a PIN to the `X-Plex-Client-Identifier` that minted
/// it, so both hosts must see the same identity.
final plexTvClientProvider = Provider<PlexTvClient>((ref) {
  return HttpPlexTvClient(identity: ref.watch(plexClientIdentityProvider));
});

/// Coordinates the plex.tv PIN sign-in flow (mint PIN → browser → poll →
/// servers → verified session) on top of [plexTvClientProvider] and
/// [plexClientProvider].
///
/// Tests override this with a [PlexPinAuth] built on fakes and an instant
/// `wait`, so the poll loop runs without real delays.
final plexPinAuthProvider = Provider<PlexPinAuth>((ref) {
  return PlexPinAuth(
    tvClient: ref.watch(plexTvClientProvider),
    serverClient: ref.watch(plexClientProvider),
    identity: ref.watch(plexClientIdentityProvider),
  );
});
