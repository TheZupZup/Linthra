import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/models/jellyfin_session.dart';
import '../../../core/sources/jellyfin/jellyfin_api.dart';
import '../../../core/sources/jellyfin/jellyfin_diagnostics.dart';
import '../../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../../core/sources/jellyfin/jellyfin_music_source.dart';
import '../../../core/sources/jellyfin/jellyfin_server_capabilities.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../data/repositories/jellyfin_session_store_provider.dart';
import '../../../data/repositories/playlist_repository_provider.dart';
import 'jellyfin_settings_providers.dart';
import 'jellyfin_settings_state.dart';
import 'jellyfin_sync_controller.dart';

/// Drives the Jellyfin settings screen: loads any saved session, tests a
/// connection, signs in, and clears settings.
///
/// It is the single coordinator between the three separated concerns — the
/// authenticator (auth), the session store (persistence), and the source
/// (library access) — so the UI only ever talks to this controller and its
/// [JellyfinSettingsState], never to HTTP or storage.
///
/// The live [session] (with its token) is kept privately for building the
/// source; it is never exposed through the public [state], never logged, and
/// the password handed to [signIn] is forwarded once and never retained.
class JellyfinSettingsController extends Notifier<JellyfinSettingsState> {
  JellyfinSession? _session;
  late final Future<void> _initialLoad;

  /// The live signed-in session, or `null` when not connected. Used to build a
  /// [JellyfinMusicSource]; callers must not log it.
  JellyfinSession? get session => _session;

  @override
  JellyfinSettingsState build() {
    // Load any persisted session in the background; until it lands the UI shows
    // the disconnected state, then flips to connected if one is found. The
    // future is retained so startup can await it (see [ensureLoaded]).
    _initialLoad = _loadPersisted();
    return const JellyfinSettingsState();
  }

  /// Completes once the persisted session has been loaded (or confirmed absent).
  ///
  /// `main` awaits this at startup so the signed-in source is ready *before* the
  /// user can tap play. Without it, the first Jellyfin stream after launch could
  /// race the background load, see no session, and fail with "not signed in" —
  /// which made streaming look like it required a prior download. Idempotent:
  /// repeated calls return the same in-flight/completed load.
  Future<void> ensureLoaded() => _initialLoad;

  Future<void> _loadPersisted() async {
    final JellyfinSession? saved;
    try {
      saved = await ref.read(jellyfinSessionStoreProvider).read();
    } catch (_) {
      // A storage hiccup must not break startup or playback; stay disconnected
      // and let the user reconnect in Settings. No secret is involved here.
      return;
    }
    if (saved == null) {
      return;
    }
    _session = saved;
    state = JellyfinSettingsState(
      phase: JellyfinConnectionPhase.connected,
      baseUrl: saved.baseUrl,
      username: saved.userName,
      serverName: saved.serverName,
      serverVersion: saved.serverVersion,
      productName: saved.productName,
      statusMessage: _connectedMessage(saved),
    );
  }

  /// Tests that [url] points to a reachable Jellyfin server. Returns whether it
  /// succeeded; details land in [state]. Needs no credentials.
  Future<bool> testConnection(String url) async {
    state = JellyfinSettingsState(
      phase: JellyfinConnectionPhase.testing,
      baseUrl: url,
      username: state.username,
      serverName: state.serverName,
      serverVersion: state.serverVersion,
      productName: state.productName,
    );
    try {
      final JellyfinServerInfo info =
          await ref.read(jellyfinAuthenticatorProvider).testConnection(url);
      state = JellyfinSettingsState(
        phase: JellyfinConnectionPhase.tested,
        baseUrl: url,
        username: state.username,
        serverName: info.serverName,
        serverVersion: info.version,
        productName: info.productName,
        statusMessage:
            'Connected to ${info.serverName} (Jellyfin ${info.version}).',
      );
      return true;
    } on JellyfinException catch (error) {
      _setFailure(error.message,
          kind: error.kind, url: url, username: state.username);
      return false;
    }
  }

  /// Signs in with [url] + [username] + [password], persists the resulting
  /// session, and flips to connected. Returns whether it succeeded.
  ///
  /// The password is forwarded to the authenticator once and never stored.
  Future<bool> signIn({
    required String url,
    required String username,
    required String password,
  }) async {
    state = JellyfinSettingsState(
      phase: JellyfinConnectionPhase.signingIn,
      baseUrl: url,
      username: username,
      serverName: state.serverName,
      serverVersion: state.serverVersion,
      productName: state.productName,
    );
    try {
      final JellyfinSession newSession =
          await ref.read(jellyfinAuthenticatorProvider).signIn(
                rawUrl: url,
                username: username,
                password: password,
                serverInfo: _knownServerInfo(),
              );
      await ref.read(jellyfinSessionStoreProvider).write(newSession);
      _session = newSession;
      state = JellyfinSettingsState(
        phase: JellyfinConnectionPhase.connected,
        baseUrl: newSession.baseUrl,
        username: newSession.userName,
        serverName: newSession.serverName,
        serverVersion: newSession.serverVersion,
        productName: newSession.productName,
        statusMessage: _connectedMessage(newSession),
      );
      return true;
    } on JellyfinException catch (error) {
      _setFailure(error.message,
          kind: error.kind, url: url, username: username);
      return false;
    }
  }

  /// Clears the saved session and resets to the disconnected state.
  ///
  /// Also tears down this account's *derived* state so nothing lingers — or
  /// crosses over to a different account on the next sign-in: the server-synced
  /// favourites and imported Jellyfin playlists are dropped (on-device
  /// favourites and local-only playlists are kept), and the now-stale
  /// "Synced N tracks" status is reset.
  Future<void> clear() async {
    await ref.read(jellyfinSessionStoreProvider).clear();
    _session = null;
    try {
      await ref.read(favoritesRepositoryProvider).clearRemote();
    } catch (_) {
      // A storage hiccup must not block sign-out; the session is already gone.
    }
    try {
      await ref.read(playlistRepositoryProvider).clearRemote();
    } catch (_) {
      // Same: never let a playlist-store hiccup block sign-out.
    }
    ref.invalidate(jellyfinSyncControllerProvider);
    state = const JellyfinSettingsState(
      statusMessage: 'Signed out. Your Jellyfin settings were cleared.',
    );
  }

  /// Reports an error without dropping an existing connection: a failed test or
  /// re-auth keeps any session that's still valid, it just surfaces the message
  /// (and the error [kind] for the diagnostics report).
  void _setFailure(
    String message, {
    JellyfinErrorKind? kind,
    String? url,
    String? username,
  }) {
    final JellyfinSession? current = _session;
    state = JellyfinSettingsState(
      phase: current != null
          ? JellyfinConnectionPhase.connected
          : JellyfinConnectionPhase.disconnected,
      baseUrl: current?.baseUrl ?? url,
      username: current?.userName ?? username,
      // While a session still stands, keep its server identity; when
      // disconnected, drop any previously-known server so a failed test of a
      // *different* address can't report the old server in diagnostics.
      serverName: current?.serverName,
      serverVersion: current?.serverVersion,
      productName: current?.productName,
      statusMessage: current != null ? _connectedMessage(current) : null,
      errorMessage: message,
      errorKind: kind,
    );
  }

  /// The server info already known from a prior connection test or the loaded
  /// session, so sign-in needn't re-read it. Null when nothing is known yet.
  JellyfinServerInfo? _knownServerInfo() {
    final String? name = state.serverName;
    final String? version = state.serverVersion;
    if (name == null || name.isEmpty || version == null || version.isEmpty) {
      return null;
    }
    return JellyfinServerInfo(
      serverName: name,
      version: version,
      productName: state.productName,
    );
  }

  /// A secret-free diagnostics report for the "Copy Jellyfin diagnostics"
  /// action, assembled from display-safe state only — never the token,
  /// password, or a full authenticated URL (the address is reduced to its host).
  String diagnosticsReport() {
    final String? version = state.serverVersion;
    return JellyfinDiagnostics.describe(
      appVersion: AppInfo.version,
      connectionState: _connectionStateLabel(),
      serverHost: JellyfinDiagnostics.hostOnly(state.baseUrl),
      serverName: state.serverName,
      serverVersion: version,
      productName: state.productName,
      versionSupport:
          version != null ? jellyfinServerSupportFor(version) : null,
      lastErrorKind: state.errorKind?.name,
    );
  }

  String _connectionStateLabel() {
    switch (state.phase) {
      case JellyfinConnectionPhase.connected:
        return 'connected';
      case JellyfinConnectionPhase.tested:
        return 'tested (not signed in)';
      case JellyfinConnectionPhase.testing:
        return 'testing';
      case JellyfinConnectionPhase.signingIn:
        return 'signing in';
      case JellyfinConnectionPhase.disconnected:
        return 'disconnected';
    }
  }

  String _connectedMessage(JellyfinSession session) {
    final String who =
        (session.userName != null && session.userName!.isNotEmpty)
            ? session.userName!
            : 'you';
    final String where =
        (session.serverName != null && session.serverName!.isNotEmpty)
            ? ' on ${session.serverName}'
            : '';
    return 'Signed in as $who$where.';
  }
}

final jellyfinSettingsControllerProvider =
    NotifierProvider<JellyfinSettingsController, JellyfinSettingsState>(
  JellyfinSettingsController.new,
);

/// The Jellyfin library source for the current session, or `null` when not
/// connected.
///
/// This is the seam that syncs the Jellyfin catalog into the
/// `MusicLibraryRepository` (via `JellyfinSyncController`) and that the playback
/// resolver reads to mint streaming URLs at play time. It rebuilds when the
/// connection toggles, reading the live session from the controller.
final jellyfinMusicSourceProvider = Provider<JellyfinMusicSource?>((ref) {
  final bool connected = ref.watch(
    jellyfinSettingsControllerProvider.select((s) => s.isConnected),
  );
  if (!connected) {
    return null;
  }
  final JellyfinSession? session =
      ref.read(jellyfinSettingsControllerProvider.notifier).session;
  if (session == null) {
    return null;
  }
  return JellyfinMusicSource(
    session: session,
    client: ref.read(jellyfinClientProvider),
  );
});
