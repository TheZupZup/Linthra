import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/jellyfin_session.dart';
import '../../../core/sources/jellyfin/jellyfin_api.dart';
import '../../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../../core/sources/jellyfin/jellyfin_music_source.dart';
import '../../../data/repositories/jellyfin_session_store_provider.dart';
import 'jellyfin_settings_providers.dart';
import 'jellyfin_settings_state.dart';

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

  /// The live signed-in session, or `null` when not connected. Used to build a
  /// [JellyfinMusicSource]; callers must not log it.
  JellyfinSession? get session => _session;

  @override
  JellyfinSettingsState build() {
    // Load any persisted session in the background; until it lands the UI shows
    // the disconnected state, then flips to connected if one is found.
    _loadPersisted();
    return const JellyfinSettingsState();
  }

  Future<void> _loadPersisted() async {
    final JellyfinSession? saved =
        await ref.read(jellyfinSessionStoreProvider).read();
    if (saved == null) {
      return;
    }
    _session = saved;
    state = JellyfinSettingsState(
      phase: JellyfinConnectionPhase.connected,
      baseUrl: saved.baseUrl,
      username: saved.userName,
      serverName: saved.serverName,
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
        statusMessage:
            'Connected to ${info.serverName} (Jellyfin ${info.version}).',
      );
      return true;
    } on JellyfinException catch (error) {
      _setFailure(error.message, url: url, username: state.username);
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
    );
    try {
      final JellyfinSession newSession =
          await ref.read(jellyfinAuthenticatorProvider).signIn(
                rawUrl: url,
                username: username,
                password: password,
                serverName: state.serverName,
              );
      await ref.read(jellyfinSessionStoreProvider).write(newSession);
      _session = newSession;
      state = JellyfinSettingsState(
        phase: JellyfinConnectionPhase.connected,
        baseUrl: newSession.baseUrl,
        username: newSession.userName,
        serverName: newSession.serverName,
        statusMessage: _connectedMessage(newSession),
      );
      return true;
    } on JellyfinException catch (error) {
      _setFailure(error.message, url: url, username: username);
      return false;
    }
  }

  /// Clears the saved session and resets to the disconnected state.
  Future<void> clear() async {
    await ref.read(jellyfinSessionStoreProvider).clear();
    _session = null;
    state = const JellyfinSettingsState(
      statusMessage: 'Signed out. Your Jellyfin settings were cleared.',
    );
  }

  /// Reports an error without dropping an existing connection: a failed test or
  /// re-auth keeps any session that's still valid, it just surfaces the message.
  void _setFailure(String message, {String? url, String? username}) {
    final JellyfinSession? current = _session;
    state = JellyfinSettingsState(
      phase: current != null
          ? JellyfinConnectionPhase.connected
          : JellyfinConnectionPhase.disconnected,
      baseUrl: current?.baseUrl ?? url,
      username: current?.userName ?? username,
      serverName: current?.serverName ?? state.serverName,
      statusMessage: current != null ? _connectedMessage(current) : null,
      errorMessage: message,
    );
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
/// This is the seam a future PR uses to sync the Jellyfin catalog into the
/// `MusicLibraryRepository` (and to resolve streaming URLs). It rebuilds when
/// the connection toggles, reading the live session from the controller.
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
