import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/plex_session.dart';
import '../../../core/sources/plex/plex_api.dart';
import '../../../core/sources/plex/plex_exception.dart';
import '../../../core/sources/plex/plex_music_source.dart';
import '../../../data/repositories/plex_session_store_provider.dart';
import 'plex_settings_providers.dart';
import 'plex_settings_state.dart';

/// Drives the Plex settings card: loads any saved session, tests a connection,
/// connects (verify + persist), discovers the server's music libraries, saves
/// the user's library selection, and disconnects.
///
/// The single coordinator between the separated concerns — the authenticator
/// (verify a URL + token against `/identity`), the session store (encrypted
/// persistence), the client (library-section discovery), and the source
/// (library access) — so the UI only ever talks to this controller and its
/// [PlexSettingsState], never to HTTP or storage.
///
/// Token safety: the live [session] (with its token) is kept privately for
/// building the source; it is never exposed through the public [state], never
/// logged, and the token handed to [connect]/[testConnection] is forwarded
/// once to the authenticator and never retained here. Every error message
/// surfaced through the state comes from a static, token-free [PlexException]
/// factory. See docs/plex.md → Token safety rules.
class PlexSettingsController extends Notifier<PlexSettingsState> {
  PlexSession? _session;
  late final Future<void> _initialLoad;

  /// Whether the music libraries were already fetched once for the current
  /// connection, so [loadSectionsIfNeeded] stays a no-op on rebuilds (and a
  /// server with zero music libraries isn't re-polled on every Settings open).
  bool _sectionsLoadAttempted = false;

  /// The live signed-in session, or `null` when not connected. Used to build a
  /// [PlexMusicSource]; callers must not log it ([PlexSession.toString]
  /// redacts the token regardless).
  PlexSession? get session => _session;

  @override
  PlexSettingsState build() {
    _initialLoad = _loadPersisted();
    return const PlexSettingsState();
  }

  /// Completes once the persisted session has been loaded (or confirmed
  /// absent). `main` awaits this at startup so a Plex track can stream on the
  /// first tap and `plex-thumb:` covers can resolve from the first frame.
  /// Idempotent.
  Future<void> ensureLoaded() => _initialLoad;

  Future<void> _loadPersisted() async {
    final PlexSession? saved;
    try {
      saved = await ref.read(plexSessionStoreProvider).read();
    } catch (_) {
      // A storage hiccup must not break startup; stay disconnected. (A
      // missing/corrupt record already reads back as null inside the store.)
      return;
    }
    if (saved == null) {
      return;
    }
    _session = saved;
    // Re-announce the identifier this install presented when it connected, so
    // the server keeps seeing the same client across restarts.
    ref
        .read(plexPersistedClientIdentifierProvider.notifier)
        .publish(saved.clientIdentifier);
    state = PlexSettingsState(
      phase: PlexConnectionPhase.connected,
      baseUrl: saved.baseUrl,
      serverName: saved.serverName,
      serverVersion: saved.serverVersion,
      selectedSectionKeys: saved.selectedSectionKeys,
      statusMessage: _connectedMessage(saved),
    );
  }

  /// Tests that [url] + [token] reach a Plex Media Server that accepts them,
  /// without persisting anything. Returns whether it succeeded; details land
  /// in [state]. The token is forwarded once and never stored.
  Future<bool> testConnection({
    required String url,
    required String token,
  }) async {
    state = PlexSettingsState(
      phase: PlexConnectionPhase.testing,
      baseUrl: url,
    );
    try {
      final PlexServerIdentity identity =
          await ref.read(plexAuthenticatorProvider).testConnection(
                rawUrl: url,
                token: token,
              );
      state = PlexSettingsState(
        phase: PlexConnectionPhase.tested,
        baseUrl: url,
        serverVersion: identity.version,
        statusMessage: 'Found your Plex Media Server'
            '${identity.version != null ? ' (${identity.version})' : ''} '
            'and it accepted the token.',
      );
      return true;
    } on PlexException catch (error) {
      _setFailure(error, url: url);
      return false;
    }
  }

  /// Connects with [url] + [token]: verifies them against `/identity`,
  /// persists the resulting session (token encrypted at rest), flips to
  /// connected, and fetches the server's music libraries for the picker.
  /// Returns whether the connection succeeded (a failure to *list libraries*
  /// afterwards does not fail the connect — it surfaces as a retryable error).
  Future<bool> connect({
    required String url,
    required String token,
  }) async {
    state = PlexSettingsState(
      phase: PlexConnectionPhase.connecting,
      baseUrl: url,
    );
    final PlexSession newSession;
    try {
      newSession = await ref.read(plexAuthenticatorProvider).signIn(
            rawUrl: url,
            token: token,
          );
    } on PlexException catch (error) {
      _setFailure(error, url: url);
      return false;
    }

    // Persist the client identifier the verify above announced, so every
    // later launch presents the same install to the server.
    final PlexSession stamped = newSession.copyWith(
      clientIdentifier: ref.read(plexClientIdentityProvider).clientIdentifier,
    );
    try {
      await ref.read(plexSessionStoreProvider).write(stamped);
    } catch (_) {
      // Without persistence the connection would silently vanish on restart;
      // fail honestly instead. Nothing sensitive is kept in memory either.
      state = const PlexSettingsState(
        errorMessage: "Couldn't save your Plex session on this device. "
            'Try again.',
      );
      return false;
    }

    _session = stamped;
    _sectionsLoadAttempted = false;
    ref
        .read(plexPersistedClientIdentifierProvider.notifier)
        .publish(stamped.clientIdentifier);
    state = PlexSettingsState(
      phase: PlexConnectionPhase.connected,
      baseUrl: stamped.baseUrl,
      serverName: stamped.serverName,
      serverVersion: stamped.serverVersion,
      statusMessage: _connectedMessage(stamped),
    );
    // Fetch the music libraries for the picker right away. Best-effort: a
    // listing failure keeps the connection and surfaces a retryable error.
    await refreshSections();
    return true;
  }

  /// Fetches the music libraries once for the current connection if they
  /// haven't been loaded yet. The connected settings view calls this when it
  /// appears (e.g. after a restart restored the session); rebuilds and a
  /// zero-library server stay no-ops.
  Future<void> loadSectionsIfNeeded() async {
    if (!state.isConnected ||
        state.isLoadingSections ||
        _sectionsLoadAttempted) {
      return;
    }
    await refreshSections();
  }

  /// (Re)fetches the server's library sections and keeps only the music ones
  /// for the picker. A failure stays on the connected state and surfaces a
  /// friendly, token-free error the user can retry from.
  Future<void> refreshSections() async {
    final PlexSession? current = _session;
    if (current == null || state.isLoadingSections) {
      return;
    }
    _sectionsLoadAttempted = true;
    state = state.copyWith(
        isLoadingSections: true, errorMessage: null, errorKind: null);
    try {
      final List<PlexDirectory> all =
          await ref.read(plexClientProvider).fetchSections(
                baseUrl: current.baseUrl,
                token: current.token,
              );
      final List<PlexLibrarySection> music = <PlexLibrarySection>[
        for (final PlexDirectory directory in all)
          if (directory.isMusic)
            PlexLibrarySection(key: directory.key, title: directory.title),
      ];
      state = state.copyWith(sections: music, isLoadingSections: false);
    } on PlexException catch (error) {
      state = state.copyWith(
        isLoadingSections: false,
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// Includes or excludes one music library [sectionKey] and persists the
  /// updated selection into the session.
  Future<void> toggleSection(String sectionKey, {required bool included}) {
    final List<String> keys = List<String>.of(state.selectedSectionKeys);
    if (included && !keys.contains(sectionKey)) {
      keys.add(sectionKey);
    } else if (!included) {
      keys.remove(sectionKey);
    }
    return setSelectedSections(keys);
  }

  /// Saves [sectionKeys] as the selected music libraries: updates the live
  /// session (which scopes every future fetch) and persists it, so the choice
  /// survives a restart. An empty list is valid — connected, nothing chosen
  /// yet.
  Future<void> setSelectedSections(List<String> sectionKeys) async {
    final PlexSession? current = _session;
    if (current == null) {
      return;
    }
    final List<String> keys = List<String>.unmodifiable(sectionKeys);
    final PlexSession updated = current.copyWith(selectedSectionKeys: keys);
    try {
      await ref.read(plexSessionStoreProvider).write(updated);
    } catch (_) {
      // Keep state and store consistent: don't apply a selection that won't
      // survive a restart.
      state = state.copyWith(
        errorMessage: "Couldn't save your library selection. Try again.",
        errorKind: null,
      );
      return;
    }
    _session = updated;
    state = state.copyWith(
      selectedSectionKeys: keys,
      errorMessage: null,
      errorKind: null,
    );
  }

  /// Disconnects Plex: removes the saved session (the only thing Plex
  /// persists) and resets to the signed-out state. Other providers' data is
  /// untouched — this clears the Plex store and nothing else.
  Future<void> disconnect() async {
    try {
      await ref.read(plexSessionStoreProvider).clear();
    } catch (_) {
      // The token would stay at rest; report it rather than pretending.
      state = state.copyWith(
        errorMessage:
            "Couldn't remove your Plex session from this device. Try again.",
        errorKind: null,
      );
      return;
    }
    _session = null;
    _sectionsLoadAttempted = false;
    ref.read(plexPersistedClientIdentifierProvider.notifier).publish(null);
    state = const PlexSettingsState(
      statusMessage: 'Disconnected. Your Plex session was removed from this '
          'device.',
    );
  }

  /// Reports a failure without dropping an existing connection: a failed test
  /// or re-connect attempt keeps any session that's still valid — the
  /// connected state is rebuilt from the live session — and just surfaces the
  /// (token-free) message.
  void _setFailure(PlexException error, {String? url}) {
    final PlexSession? current = _session;
    if (current != null) {
      state = PlexSettingsState(
        phase: PlexConnectionPhase.connected,
        baseUrl: current.baseUrl,
        serverName: current.serverName,
        serverVersion: current.serverVersion,
        sections: state.sections,
        selectedSectionKeys: current.selectedSectionKeys,
        statusMessage: _connectedMessage(current),
        errorMessage: error.message,
        errorKind: error.kind,
      );
      return;
    }
    state = PlexSettingsState(
      baseUrl: url,
      errorMessage: error.message,
      errorKind: error.kind,
    );
  }

  String _connectedMessage(PlexSession session) {
    final String? version = session.serverVersion;
    final String where =
        (session.serverName != null && session.serverName!.isNotEmpty)
            ? session.serverName!
            : 'your Plex server';
    return 'Connected to $where'
        '${version != null && version.isNotEmpty ? ' (Plex Media Server $version)' : ''}.';
  }
}

final plexSettingsControllerProvider =
    NotifierProvider<PlexSettingsController, PlexSettingsState>(
  PlexSettingsController.new,
);

/// The Plex library source for the current session, or `null` when not
/// connected.
///
/// The "register the provider" seam of the Plex plan (issue #178 /
/// docs/plex.md): the playback router and the render-time artwork resolver
/// read this, so `plex:<ratingKey>` track URIs and `plex-thumb:` artwork
/// references resolve end to end once a session exists. With no session it
/// stays `null` — every `plex:` track fails resolution with a friendly "not
/// signed in" and every `plex-thumb:` reference keeps its placeholder, exactly
/// as before the connection UI shipped.
///
/// Watches the whole settings state (not just the connected flag) because a
/// library-selection change also swaps the session behind the source — the
/// selected section keys scope every fetch. Rebuilds are cheap: the source is
/// a thin orchestrator over the shared client.
final plexMusicSourceProvider = Provider<PlexMusicSource?>((ref) {
  ref.watch(plexSettingsControllerProvider);
  final PlexSession? session =
      ref.read(plexSettingsControllerProvider.notifier).session;
  if (session == null) {
    return null;
  }
  return PlexMusicSource(
    session: session,
    client: ref.read(plexClientProvider),
  );
});
