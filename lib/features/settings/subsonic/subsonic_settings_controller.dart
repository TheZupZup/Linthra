import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/subsonic_session.dart';
import '../../../core/sources/music_provider.dart';
import '../../../core/sources/subsonic/subsonic_api.dart';
import '../../../core/sources/subsonic/subsonic_exception.dart';
import '../../../core/sources/subsonic/subsonic_music_source.dart';
import '../../../data/repositories/subsonic_session_store_provider.dart';
import '../../library/source_preference_controller.dart';
import 'subsonic_settings_providers.dart';
import 'subsonic_settings_state.dart';
import 'subsonic_sync_controller.dart';

/// Drives the Subsonic/Navidrome settings screen: loads any saved session,
/// tests a connection, signs in, and clears settings.
///
/// The single coordinator between the three separated concerns — the
/// authenticator (auth), the session store (persistence), and the source
/// (library access) — so the UI only ever talks to this controller and its
/// [SubsonicSettingsState], never to HTTP or storage.
///
/// The live [session] (with its salt+token) is kept privately for building the
/// source; it is never exposed through the public [state], never logged, and the
/// password handed to [signIn]/[testConnection] is forwarded once (to derive the
/// token) and never retained.
class SubsonicSettingsController extends Notifier<SubsonicSettingsState> {
  SubsonicSession? _session;
  late final Future<void> _initialLoad;

  /// The live signed-in session, or `null` when not connected. Used to build a
  /// [SubsonicMusicSource]; callers must not log it.
  SubsonicSession? get session => _session;

  @override
  SubsonicSettingsState build() {
    _initialLoad = _loadPersisted();
    return const SubsonicSettingsState();
  }

  /// Completes once the persisted session has been loaded (or confirmed absent).
  /// `main` awaits this at startup so a synced Subsonic track can stream on the
  /// first tap. Idempotent.
  Future<void> ensureLoaded() => _initialLoad;

  Future<void> _loadPersisted() async {
    final SubsonicSession? saved;
    try {
      saved = await ref.read(subsonicSessionStoreProvider).read();
    } catch (_) {
      // A storage hiccup must not break startup or playback; stay disconnected.
      return;
    }
    if (saved == null) {
      return;
    }
    _session = saved;
    state = SubsonicSettingsState(
      phase: SubsonicConnectionPhase.connected,
      baseUrl: saved.baseUrl,
      username: saved.username,
      serverType: saved.serverType,
      serverVersion: saved.serverVersion,
      apiVersion: saved.apiVersion,
      statusMessage: _connectedMessage(saved.username, saved.serverType),
    );
  }

  /// Tests that [url] + credentials reach a Subsonic server that accepts them.
  /// Returns whether it succeeded; details land in [state]. The password is
  /// forwarded once (to derive the token) and never stored.
  Future<bool> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    state = SubsonicSettingsState(
      phase: SubsonicConnectionPhase.testing,
      baseUrl: url,
      username: username,
    );
    try {
      final SubsonicServerInfo info =
          await ref.read(subsonicAuthenticatorProvider).testConnection(
                rawUrl: url,
                username: username,
                password: password,
              );
      state = SubsonicSettingsState(
        phase: SubsonicConnectionPhase.tested,
        baseUrl: url,
        username: username,
        serverType: info.type,
        serverVersion: info.serverVersion,
        apiVersion: info.apiVersion,
        statusMessage: 'Connected to ${info.displayProduct}'
            '${info.serverVersion != null ? ' ${info.serverVersion}' : ''}.',
      );
      return true;
    } on SubsonicException catch (error) {
      _setFailure(error.message,
          kind: error.kind, url: url, username: username);
      return false;
    }
  }

  /// Signs in with [url] + [username] + [password], persists the resulting
  /// session (only its derived salt+token), and flips to connected. Returns
  /// whether it succeeded.
  Future<bool> signIn({
    required String url,
    required String username,
    required String password,
  }) async {
    state = SubsonicSettingsState(
      phase: SubsonicConnectionPhase.signingIn,
      baseUrl: url,
      username: username,
    );
    try {
      final SubsonicSession newSession =
          await ref.read(subsonicAuthenticatorProvider).signIn(
                rawUrl: url,
                username: username,
                password: password,
              );
      await ref.read(subsonicSessionStoreProvider).write(newSession);
      _session = newSession;
      // The just-signed-in server becomes the active/default provider for
      // picking among duplicate sources: a song that also lives on Jellyfin now
      // prefers Navidrome/Subsonic. Persisted and best-effort.
      unawaited(
        ref
            .read(librarySourcePriorityProvider.notifier)
            .markPreferred(MusicProviders.subsonic.sourceId),
      );
      state = SubsonicSettingsState(
        phase: SubsonicConnectionPhase.connected,
        baseUrl: newSession.baseUrl,
        username: newSession.username,
        serverType: newSession.serverType,
        serverVersion: newSession.serverVersion,
        apiVersion: newSession.apiVersion,
        statusMessage:
            _connectedMessage(newSession.username, newSession.serverType),
      );
      return true;
    } on SubsonicException catch (error) {
      _setFailure(error.message,
          kind: error.kind, url: url, username: username);
      return false;
    }
  }

  /// Clears the saved session and resets to the disconnected state, also
  /// resetting the now-stale "Synced N tracks" status so it can't linger into a
  /// later sign-in. (Subsonic favourites are on-device only, so there are no
  /// server-synced favourites to drop here.)
  Future<void> clear() async {
    await ref.read(subsonicSessionStoreProvider).clear();
    _session = null;
    ref.invalidate(subsonicSyncControllerProvider);
    state = const SubsonicSettingsState(
      statusMessage: 'Signed out. Your Subsonic settings were cleared.',
    );
  }

  /// Reports an error without dropping an existing connection: a failed test or
  /// re-auth keeps any session that's still valid, it just surfaces the message.
  void _setFailure(
    String message, {
    SubsonicErrorKind? kind,
    String? url,
    String? username,
  }) {
    final SubsonicSession? current = _session;
    state = SubsonicSettingsState(
      phase: current != null
          ? SubsonicConnectionPhase.connected
          : SubsonicConnectionPhase.disconnected,
      baseUrl: current?.baseUrl ?? url,
      username: current?.username ?? username,
      serverType: current?.serverType ?? state.serverType,
      serverVersion: current?.serverVersion ?? state.serverVersion,
      apiVersion: current?.apiVersion ?? state.apiVersion,
      statusMessage: current != null
          ? _connectedMessage(current.username, current.serverType)
          : null,
      errorMessage: message,
      errorKind: kind,
    );
  }

  String _connectedMessage(String username, String? serverType) {
    final String where = (serverType != null && serverType.isNotEmpty)
        ? ' on ${serverType[0].toUpperCase()}${serverType.substring(1)}'
        : '';
    return 'Signed in as $username$where.';
  }
}

final subsonicSettingsControllerProvider =
    NotifierProvider<SubsonicSettingsController, SubsonicSettingsState>(
  SubsonicSettingsController.new,
);

/// The Subsonic library source for the current session, or `null` when not
/// connected.
///
/// The seam that syncs the Subsonic catalog into the `MusicLibraryRepository`
/// (via `SubsonicSyncController`) and that the playback/cast/download paths read
/// to mint URLs at use time. It rebuilds when the connection toggles, reading
/// the live session from the controller.
final subsonicMusicSourceProvider = Provider<SubsonicMusicSource?>((ref) {
  final bool connected = ref.watch(
    subsonicSettingsControllerProvider.select((s) => s.isConnected),
  );
  if (!connected) {
    return null;
  }
  final SubsonicSession? session =
      ref.read(subsonicSettingsControllerProvider.notifier).session;
  if (session == null) {
    return null;
  }
  return SubsonicMusicSource(
    session: session,
    client: ref.read(subsonicClientProvider),
  );
});
