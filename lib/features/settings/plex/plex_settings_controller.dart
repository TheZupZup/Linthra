import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/external_link_launcher_provider.dart';
import '../../../core/models/plex_session.dart';
import '../../../core/sources/plex/plex_api.dart';
import '../../../core/sources/plex/plex_exception.dart';
import '../../../core/sources/plex/plex_music_source.dart';
import '../../../core/sources/plex/plex_pin_auth.dart';
import '../../../core/sources/plex/plex_tv_api.dart';
import '../../../data/repositories/plex_session_store_provider.dart';
import 'plex_settings_providers.dart';
import 'plex_settings_state.dart';
import 'plex_sync_controller.dart';

/// Drives the Plex settings card: loads any saved session, runs the
/// "Connect with Plex" browser sign-in (PIN → server picker → session), tests
/// or connects a manually typed URL + token (the advanced fallback),
/// discovers the server's music libraries, saves the user's library selection
/// (kicking a background catalog sync so the Library screen follows it), and
/// disconnects (also dropping the synced Plex rows, which are unplayable
/// without a session).
///
/// The single coordinator between the separated concerns — the PIN auth flow
/// ([PlexPinAuth]), the manual authenticator (verify a URL + token against
/// `/identity`), the session store (encrypted persistence), the client
/// (library-section discovery), and the source (library access) — so the UI
/// only ever talks to this controller and its [PlexSettingsState], never to
/// HTTP or storage.
///
/// Token safety: the live [session] (with its token) is kept privately for
/// building the source; it is never exposed through the public [state], never
/// logged, and the token handed to [connect]/[testConnection] is forwarded
/// once to the authenticator and never retained here. The sign-in flow's
/// account token and token-bearing server resources live only in private
/// fields for the duration of the flow ([state] gets display-safe
/// [PlexServerChoice]s instead) and are released the moment the flow ends —
/// connected, cancelled, or failed. Every error message surfaced through the
/// state comes from a static, token-free [PlexException] factory. See
/// docs/plex.md → Token safety rules.
class PlexSettingsController extends Notifier<PlexSettingsState> {
  PlexSession? _session;
  late final Future<void> _initialLoad;

  /// Monotonic id of the current "Connect with Plex" attempt. Every await in
  /// the flow re-checks it afterwards, so a cancel / disconnect / newer
  /// attempt makes the superseded continuation drop its result instead of
  /// clobbering fresh state — the polling loop can outlive several user
  /// actions while the user is away in the browser.
  int _linkAttempt = 0;

  /// The account token granted by the sign-in, held **only** between the PIN
  /// approval and the server pick (it's what authorizes the resources call
  /// and the fallback when a server has no scoped token). Never exposed
  /// through [state], never logged, nulled by [_resetLinkFlow].
  String? _accountToken;

  /// The token-bearing server resources behind the display-safe
  /// [PlexSettingsState.servers] choices. Private for the same reason as
  /// [_accountToken]; cleared with it.
  List<PlexResource> _flowServers = const <PlexResource>[];

  /// The active sign-in link, kept so "Open the sign-in page again" can
  /// re-launch the same PIN's page after the user closed the browser tab.
  PlexPinLink? _activeLink;

  /// True from the moment a "Connect with Plex" flow starts until it connects,
  /// is cancelled, or is superseded — i.e. while the flow owns the card.
  ///
  /// Broader than the phase-based [PlexSettingsState.isLinkFlowActive]: it
  /// stays true through the flow's `connecting` **probe** too, which shares
  /// the `connecting` phase with the manual form and so can't be told apart by
  /// phase alone. The startup restore consults this (not the phase) so a slow
  /// secure-storage read landing mid-flow — on success **or** failure — can't
  /// clobber the visible sign-in with a restored session or a restore error.
  bool _linkFlowOwnsCard = false;

  /// Whether the music libraries were already fetched once for the current
  /// connection, so [loadSectionsIfNeeded] stays a no-op on rebuilds (and a
  /// server with zero music libraries isn't re-polled on every Settings open).
  bool _sectionsLoadAttempted = false;

  /// Set once a user action (connect/disconnect) has taken ownership of the
  /// session while the startup restore was still reading storage. The restore
  /// then discards its stale result instead of overwriting a fresh connect or
  /// resurrecting a just-cleared session — secure-storage reads can be slow on
  /// real devices, so this race is reachable.
  bool _restoreSuperseded = false;

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
      // A storage hiccup must not break startup; stay disconnected but say
      // so (statically, token-free), so a user who *was* connected isn't left
      // wondering where their server went. (A missing/corrupt record already
      // reads back as null inside the store and stays silent.) But if a
      // "Connect with Plex" flow has since taken over the card, leave it
      // alone — replacing it with a disconnected restore error would strip
      // the user's Cancel/reopen controls while the poll keeps running.
      if (!_restoreSuperseded && _session == null && !_linkFlowOwnsCard) {
        state = const PlexSettingsState(
          errorMessage: "Couldn't restore your saved Plex connection from "
              'this device. If you use Plex, connect again below.',
        );
      }
      return;
    }
    // A connect/disconnect that landed while this read was in flight owns the
    // session now; applying the stale result would overwrite it.
    if (_restoreSuperseded || _session != null) {
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
    if (_linkFlowOwnsCard) {
      // A "Connect with Plex" flow started while this slow read was still in
      // flight and owns the card now — including its `connecting` probe, which
      // [PlexSettingsState.isLinkFlowActive] wouldn't catch. The restored
      // session stays live behind it (a cancel rebuilds the connected view
      // from it); only the visible state must not be clobbered.
      return;
    }
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

  /// Connects with a manually typed [url] + [token] (the advanced fallback
  /// flow): verifies them against `/identity`, then persists and finishes
  /// like every connect ([_completeConnect]). Returns whether the connection
  /// succeeded (a failure to *list libraries* afterwards does not fail the
  /// connect — it surfaces as a retryable error).
  Future<bool> connect({
    required String url,
    required String token,
  }) async {
    // A manual connect supersedes any sign-in flow still polling.
    _resetLinkFlow();
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
    return _completeConnect(newSession);
  }

  /// Starts the "Connect with Plex" browser sign-in: mints a plex.tv PIN,
  /// opens the hosted approval page in the browser, polls until the user
  /// approves it, then fetches the account's Plex Media Servers — connecting
  /// straight away when there is exactly one, otherwise showing the server
  /// picker ([selectServer] finishes it). Safe to call while connected: the
  /// existing session stays live (and is restored on cancel/failure) until a
  /// new one actually lands, which is what makes this the "reconnect" action
  /// for an expired token too.
  Future<void> connectWithPlex() async {
    if (state.isBusy || state.isLinkFlowActive) return;
    final int attempt = ++_linkAttempt;
    // The flow now owns the card; the startup restore must not clobber it
    // (on success or failure) until it connects, cancels, or is superseded.
    _linkFlowOwnsCard = true;

    // Immediate feedback while the PIN is minted; keep the current card
    // context (server fields, sections, selection) so a cancel or failure
    // can restore the connected view exactly as it was.
    state = state.copyWith(
      phase: PlexConnectionPhase.linking,
      servers: const <PlexServerChoice>[],
      statusMessage: 'Contacting plex.tv…',
      errorMessage: null,
      errorKind: null,
    );

    final PlexPinLink link;
    try {
      link = await ref.read(plexPinAuthProvider).begin();
    } on PlexException catch (error) {
      if (_linkAttempt != attempt) return;
      _resetLinkFlow();
      _setFailure(error);
      return;
    }
    if (_linkAttempt != attempt) return;
    _activeLink = link;

    final bool opened =
        await ref.read(externalLinkLauncherProvider).open(link.authUrl);
    if (_linkAttempt != attempt) return;
    if (!opened) {
      _resetLinkFlow();
      _setFailure(PlexException.browserUnavailable());
      return;
    }
    state = state.copyWith(
      statusMessage: 'Approve Linthra on the Plex sign-in page that just '
          'opened, then come back here.',
    );

    final String? accountToken;
    try {
      accountToken = await ref.read(plexPinAuthProvider).waitForAuthToken(
            link.pinId,
            isCancelled: () => _linkAttempt != attempt,
          );
    } on PlexException catch (error) {
      if (_linkAttempt != attempt) return;
      _resetLinkFlow();
      _setFailure(error);
      return;
    }
    // Cancelled (null) or superseded: someone else owns the card now.
    if (_linkAttempt != attempt || accountToken == null) return;

    state = state.copyWith(
      phase: PlexConnectionPhase.loadingServers,
      statusMessage: 'Signed in. Finding your Plex Media Servers…',
    );

    final List<PlexResource> servers;
    try {
      servers = await ref
          .read(plexPinAuthProvider)
          .fetchServers(accountToken: accountToken);
    } on PlexException catch (error) {
      if (_linkAttempt != attempt) return;
      _resetLinkFlow();
      _setFailure(error);
      return;
    }
    if (_linkAttempt != attempt) return;

    // The flow now holds secrets (account token, per-server tokens) — only
    // until a server is connected, the flow is cancelled, or it fails.
    _accountToken = accountToken;
    _flowServers = servers;

    if (servers.length == 1) {
      // One server: nothing to choose, connect to it directly.
      await _connectToFlowServer(servers.single, attempt);
      return;
    }
    // Several servers (the user picks) — or none (the picker's empty state).
    state = state.copyWith(
      phase: PlexConnectionPhase.pickingServer,
      servers: _choicesFor(servers),
      statusMessage: null,
    );
  }

  /// Connects to the picked server from the server picker. Returns whether
  /// the connection succeeded; a failure returns to the picker with a
  /// friendly error so another server (or the same one) can be tried.
  Future<bool> selectServer(String clientIdentifier) async {
    if (state.phase != PlexConnectionPhase.pickingServer) return false;
    for (final PlexResource server in _flowServers) {
      if (server.clientIdentifier == clientIdentifier) {
        return _connectToFlowServer(server, _linkAttempt);
      }
    }
    return false;
  }

  /// Abandons the "Connect with Plex" flow at any of its stages, releasing
  /// the in-memory account token and restoring the card to where it was
  /// (the still-live connected session, or the signed-out form).
  void cancelPlexLink() {
    if (!state.isLinkFlowActive) return;
    _resetLinkFlow();
    _restoreIdleState();
  }

  /// Re-opens the sign-in page for the active link — for when the user
  /// closed the browser tab before approving. The PIN (and its poll) keep
  /// running; this only re-hands the same page to the browser.
  Future<void> reopenPlexSignIn() async {
    final PlexPinLink? link = _activeLink;
    if (link == null || state.phase != PlexConnectionPhase.linking) return;
    final bool opened =
        await ref.read(externalLinkLauncherProvider).open(link.authUrl);
    if (!opened && state.phase == PlexConnectionPhase.linking) {
      final PlexException error = PlexException.browserUnavailable();
      state = state.copyWith(
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// Probes and persists one of the sign-in flow's servers, preferring its
  /// server-scoped token (see [PlexPinAuth.connectToServer]).
  Future<bool> _connectToFlowServer(PlexResource server, int attempt) async {
    final String? accountToken = _accountToken;
    if (accountToken == null) return false;
    state = state.copyWith(
      phase: PlexConnectionPhase.connecting,
      servers: _choicesFor(_flowServers),
      statusMessage: 'Connecting to '
          '${server.name.isNotEmpty ? server.name : 'your Plex server'}…',
      errorMessage: null,
      errorKind: null,
    );
    final PlexSession newSession;
    try {
      newSession = await ref.read(plexPinAuthProvider).connectToServer(
            server: server,
            accountToken: accountToken,
          );
    } on PlexException catch (error) {
      if (_linkAttempt != attempt) return false;
      // Back to the picker: with several servers another can be tried, and
      // with one the retry (tap it again) or Cancel is right there.
      state = state.copyWith(
        phase: PlexConnectionPhase.pickingServer,
        statusMessage: null,
        errorMessage: error.message,
        errorKind: error.kind,
      );
      return false;
    }
    if (_linkAttempt != attempt) return false;
    return _completeConnect(newSession);
  }

  /// The shared tail of every successful verify — manual form and sign-in
  /// flow alike: stamps the announced client identifier, persists the session
  /// (token encrypted at rest), flips to connected, fetches the music
  /// libraries for the picker, and brings the synced catalog in step.
  ///
  /// Reconnecting to the **same** server (recognised by its
  /// `machineIdentifier`, e.g. after rotating or re-granting the token) keeps
  /// the existing library selection and refreshes the synced catalog against
  /// it — wiping the selection would silently empty the user's Plex library
  /// on the next sync. A different server starts with a clean (empty)
  /// selection, and any rows the previous server synced are dropped quietly:
  /// their ratingKeys belong to another machine and could never play.
  Future<bool> _completeConnect(PlexSession newSession) async {
    final PlexSession? previous = _session;
    final bool sameServer = previous != null &&
        previous.machineIdentifier == newSession.machineIdentifier;
    // Persist the client identifier the verify above announced, so every
    // later launch presents the same install to the server — and carry the
    // library selection (and any already-known server name) over a
    // same-server reconnect. A fresh name from the sign-in flow wins over a
    // remembered one (the server may have been renamed).
    final PlexSession stamped = newSession.copyWith(
      clientIdentifier: ref.read(plexClientIdentityProvider).clientIdentifier,
      serverName:
          newSession.serverName ?? (sameServer ? previous.serverName : null),
      selectedSectionKeys:
          sameServer ? previous.selectedSectionKeys : const <String>[],
    );
    try {
      await ref.read(plexSessionStoreProvider).write(stamped);
    } catch (_) {
      // The new connection couldn't be persisted; without that it would
      // silently vanish on restart, so don't adopt it. The sign-in flow's
      // in-memory tokens are released here. A previous session, if any, is
      // untouched — the failed write didn't replace it at rest, and [_session]
      // still holds it — so restore its connected view with the error rather
      // than dropping to a disconnected card while [plexMusicSourceProvider]
      // keeps serving it ([_setFailure] rebuilds from the live [_session], or
      // shows a plain signed-out error when there is none).
      _resetLinkFlow();
      _setFailure(const PlexException(
        "Couldn't save your Plex session on this device. Try again.",
      ));
      return false;
    }

    _session = stamped;
    _sectionsLoadAttempted = false;
    _restoreSuperseded = true;
    // The flow is complete: release the account token and the token-bearing
    // resources. Only the (encrypted) session keeps a credential now.
    _resetLinkFlow();
    ref
        .read(plexPersistedClientIdentifierProvider.notifier)
        .publish(stamped.clientIdentifier);
    // A fresh connection gets a fresh sync status — the old "Synced N tracks"
    // line described the previous session.
    ref.invalidate(plexSyncControllerProvider);
    state = PlexSettingsState(
      phase: PlexConnectionPhase.connected,
      baseUrl: stamped.baseUrl,
      serverName: stamped.serverName,
      serverVersion: stamped.serverVersion,
      selectedSectionKeys: stamped.selectedSectionKeys,
      statusMessage: _connectedMessage(stamped),
    );
    // Fetch the music libraries for the picker right away. Best-effort: a
    // listing failure keeps the connection and surfaces a retryable error.
    await refreshSections();
    if (stamped.selectedSectionKeys.isNotEmpty) {
      // Same-server reconnect with a kept selection: bring the catalog back
      // in step without blocking the connect.
      unawaited(_syncInBackground());
    } else {
      // First connect or a different server: drop any rows a previous server
      // synced. The catalog refills once the user selects libraries.
      unawaited(_clearCatalogQuietly());
    }
    return true;
  }

  /// Invalidates any in-flight sign-in attempt (its continuations see a newer
  /// [_linkAttempt] and drop their results) and releases the flow's
  /// in-memory secrets.
  void _resetLinkFlow() {
    _linkAttempt++;
    _accountToken = null;
    _flowServers = const <PlexResource>[];
    _activeLink = null;
    _linkFlowOwnsCard = false;
  }

  /// Restores the card to its resting state: the connected view rebuilt from
  /// the still-live session, or the pristine signed-out state.
  void _restoreIdleState() {
    final PlexSession? current = _session;
    if (current != null) {
      state = PlexSettingsState(
        phase: PlexConnectionPhase.connected,
        baseUrl: current.baseUrl,
        serverName: current.serverName,
        serverVersion: current.serverVersion,
        sections: state.sections,
        sectionsLoaded: state.sectionsLoaded,
        selectedSectionKeys: current.selectedSectionKeys,
        statusMessage: _connectedMessage(current),
      );
      return;
    }
    state = const PlexSettingsState();
  }

  /// The display-safe picker projections of the flow's server resources —
  /// the only shape of them that may reach [state].
  List<PlexServerChoice> _choicesFor(List<PlexResource> servers) {
    return List<PlexServerChoice>.unmodifiable(<PlexServerChoice>[
      for (final PlexResource server in servers)
        PlexServerChoice(
          clientIdentifier: server.clientIdentifier,
          name: server.name.isNotEmpty ? server.name : 'Plex Media Server',
          productVersion: server.productVersion,
          owned: server.owned,
        ),
    ]);
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
      state = state.copyWith(
        sections: music,
        isLoadingSections: false,
        sectionsLoaded: true,
      );
      await _pruneVanishedSelection(music);
    } on PlexException catch (error) {
      state = state.copyWith(
        isLoadingSections: false,
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// Drops selected section keys that no longer exist on the server (the
  /// music library was deleted or re-created server-side), so the selection
  /// can't hold an invisible entry the picker shows no checkbox for — one
  /// that would 404 every sync with no way to deselect it.
  ///
  /// Only runs against a **successful** sections fetch: a transient listing
  /// failure must never shrink the selection. Quiet best-effort: if the
  /// pruned selection can't be persisted the stale keys simply remain until
  /// the next refresh, and no sync is kicked here — the next sync (manual or
  /// selection-driven) drops the vanished section's tracks.
  Future<void> _pruneVanishedSelection(List<PlexLibrarySection> music) async {
    final PlexSession? current = _session;
    if (current == null || current.selectedSectionKeys.isEmpty) {
      return;
    }
    final Set<String> available = <String>{
      for (final PlexLibrarySection section in music) section.key,
    };
    final List<String> kept = <String>[
      for (final String key in current.selectedSectionKeys)
        if (available.contains(key)) key,
    ];
    if (kept.length == current.selectedSectionKeys.length) {
      return;
    }
    final PlexSession updated =
        current.copyWith(selectedSectionKeys: List<String>.unmodifiable(kept));
    try {
      await ref.read(plexSessionStoreProvider).write(updated);
    } catch (_) {
      return;
    }
    _session = updated;
    state = state.copyWith(selectedSectionKeys: updated.selectedSectionKeys);
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
    // Keep the catalog in step with the new selection without blocking the
    // checkbox tap; the sync controller coalesces rapid toggles into one
    // re-run and reports progress through its own state.
    unawaited(_syncInBackground());
  }

  /// Disconnects Plex: removes the saved session, resets to the signed-out
  /// state, resets the sync status, and removes the synced Plex tracks from
  /// the local catalog — without a session (and with no offline cache in
  /// phase 1) they are permanently unplayable rows. Other providers' data is
  /// untouched: only the Plex store and the catalog's `plex` slice change.
  /// Any sign-in flow still in flight is abandoned (and its in-memory tokens
  /// released) along the way.
  Future<void> disconnect() async {
    _resetLinkFlow();
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
    _restoreSuperseded = true;
    ref.read(plexPersistedClientIdentifierProvider.notifier).publish(null);
    // The old "Synced N tracks" status described the session that just ended.
    ref.invalidate(plexSyncControllerProvider);
    bool catalogCleared = true;
    try {
      await ref.read(plexSyncControllerProvider.notifier).removeSyncedCatalog();
    } catch (_) {
      // Best-effort: the session is already gone (the part that matters for
      // the token); stale rows are replaced by the next successful sync.
      catalogCleared = false;
    }
    state = PlexSettingsState(
      statusMessage: catalogCleared
          ? 'Disconnected. Your Plex session and synced Plex tracks were '
              'removed from this device.'
          : 'Disconnected. Your Plex session was removed from this device.',
    );
  }

  /// Runs the catalog sync for the current selection without blocking the
  /// caller. Failures are swallowed here on purpose: the sync controller
  /// reports its own progress and errors through `PlexSyncState`, and a
  /// backgrounded kick must never surface a raw error past this seam.
  Future<void> _syncInBackground() async {
    try {
      await ref
          .read(plexSyncControllerProvider.notifier)
          .syncAfterSelectionChange();
    } catch (_) {
      // Reported through PlexSyncState; nothing to add here.
    }
  }

  /// Removes the synced Plex rows from the catalog without reporting through
  /// any state — used when a connect made them stale (different server).
  Future<void> _clearCatalogQuietly() async {
    try {
      await ref.read(plexSyncControllerProvider.notifier).removeSyncedCatalog();
    } catch (_) {
      // Best-effort: stale rows are replaced by the next successful sync.
    }
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
        sectionsLoaded: state.sectionsLoaded,
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
