import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/audiobookshelf_session.dart';
import '../../../core/repositories/secure_storage_exception.dart';
import '../../../core/services/local_network/local_network_access.dart';
import '../../../core/sources/audiobookshelf/audiobookshelf_api.dart';
import '../../../core/sources/audiobookshelf/audiobookshelf_exception.dart';
import '../../../data/repositories/audiobookshelf_session_store_provider.dart';
import '../local_network/local_network_providers.dart';
import 'audiobookshelf_settings_providers.dart';
import 'audiobookshelf_settings_state.dart';

/// Drives the Audiobookshelf connection screen: loads any saved session, tests
/// an address, signs in, lists the libraries, and signs out.
///
/// The single coordinator between the three separated concerns — the
/// authenticator (auth), the session store (persistence), and the client
/// (library access) — so the UI only ever talks to this controller and its
/// [AudiobookshelfSettingsState], never to HTTP or storage.
///
/// This is the audiobook seam and it stays on its own side of it: nothing here
/// touches the music providers, the music catalog, or the source preference.
///
/// The live [session] (with its tokens) is kept privately for later audiobook
/// work; it is never exposed through the public [state], never logged, and the
/// password handed to [signIn] is forwarded once (to obtain the tokens) and
/// never retained.
class AudiobookshelfSettingsController
    extends Notifier<AudiobookshelfSettingsState> {
  AudiobookshelfSession? _session;
  late final Future<void> _initialLoad;

  /// Counts the sign-ins [_session] has belonged to: the saved one restored,
  /// each new sign-in, each sign-out. Renewing the tokens keeps the count, as
  /// it is still the same sign-in.
  int _signIns = 0;

  /// The address a [testConnection] last succeeded for, with the status it
  /// returned. A sign-in for that same address reuses it instead of asking the
  /// server for `/status` a second time; any other address re-confirms.
  String? _testedBaseUrl;
  AudiobookshelfServerStatus? _testedStatus;

  /// Session changes (a sign-in, a sign-out, a token renewal) reach the
  /// keyring and [_session] one at a time, in the order they were asked for.
  /// Without this a renewal saved just after a sign-out cleared the keyring
  /// would put the signed-out account back on disk.
  Future<void> _sessionChanges = Future<void>.value();

  /// The token renewal in flight, and the session it renews. Every request
  /// that finds the access token expired waits on this one rather than
  /// starting its own: the server rotates the refresh token, so a second
  /// renewal with the same one would be turned down.
  Future<AudiobookshelfSession?>? _renewal;
  AudiobookshelfSession? _renewing;

  /// The session whose refresh token the server turned down. Its requests
  /// don't ask again; only a new sign-in replaces it.
  AudiobookshelfSession? _refused;

  /// A renewed session the keyring refused to save, and whether saving it is
  /// being tried again. It is used anyway, since the tokens it replaced may
  /// already be dead on the server, and the next request retries the save.
  AudiobookshelfSession? _unsaved;

  /// What the card says while [_unsaved] is waiting to be saved: kept on
  /// every connected state until the save lands, so the request that
  /// triggered the renewal doesn't wipe the warning out by succeeding.
  String? _unsavedWarning;
  bool _retryingSave = false;

  /// The live signed-in session, or `null` when not connected. Callers must not
  /// log it.
  AudiobookshelfSession? get session => _session;

  /// Which sign-in [session] belongs to. What was loaded under one sign-in
  /// survives a token renewal, but not a sign-out and a new sign-in, even to
  /// the same account.
  int get currentSignIn => _signIns;

  @override
  AudiobookshelfSettingsState build() {
    _initialLoad = _loadPersisted();
    return const AudiobookshelfSettingsState();
  }

  /// Completes once the persisted session has been loaded (or confirmed
  /// absent). `main` awaits this at startup so the connection is already known
  /// by the first frame. Idempotent.
  Future<void> ensureLoaded() => _initialLoad;

  Future<void> _loadPersisted() async {
    final AudiobookshelfSession? saved;
    try {
      saved = await ref.read(audiobookshelfSessionStoreProvider).read();
    } catch (error) {
      // A keyring that is missing, locked or denied must not break startup:
      // stay disconnected, but say so (statically, credential-free) so a user
      // who *was* signed in isn't left wondering where their server went. A
      // missing or corrupt record already reads back as null inside the store
      // and stays silent.
      //
      // Only when nothing has taken over the card in the meantime: a locked
      // keyring can block this read behind an unlock prompt for as long as the
      // user leaves it there, and a sign-in that already started (or finished)
      // in that time owns the state now.
      if (_session == null &&
          state.phase == AudiobookshelfConnectionPhase.disconnected &&
          state.errorMessage == null) {
        state = AudiobookshelfSettingsState(
          errorMessage: "Couldn't restore your saved Audiobookshelf sign-in "
              'from this device. ${_storageRemedy(error)}',
        );
      }
      return;
    }
    if (saved == null) {
      return;
    }
    _session = saved;
    _signIns++;
    state = AudiobookshelfSettingsState(
      phase: AudiobookshelfConnectionPhase.connected,
      baseUrl: saved.baseUrl,
      username: saved.userName,
      serverVersion: saved.serverVersion,
      statusMessage: _connectedMessage(saved.userName),
    );
  }

  /// Tests that [url] points at a reachable Audiobookshelf server. Returns
  /// whether it succeeded; details land in [state].
  ///
  /// No credentials are sent: Audiobookshelf answers `/status` unauthenticated,
  /// which is exactly what makes it safe to check an address the user just
  /// typed before any password goes near it.
  Future<bool> testConnection(String url) async {
    state = AudiobookshelfSettingsState(
      phase: AudiobookshelfConnectionPhase.testing,
      baseUrl: url,
      username: state.username,
    );
    try {
      await requireLocalNetworkFor(ref, url);
      final AudiobookshelfServerStatus status =
          await ref.read(audiobookshelfAuthenticatorProvider).testConnection(
                url,
              );
      _testedBaseUrl = url;
      _testedStatus = status;
      state = AudiobookshelfSettingsState(
        phase: AudiobookshelfConnectionPhase.tested,
        baseUrl: url,
        username: state.username,
        serverVersion: status.serverVersion,
        statusMessage: _reachableMessage(status),
      );
      return true;
    } catch (error) {
      final AudiobookshelfException failure = _typed(error);
      _forgetTestedStatus();
      _setFailure(failure.message, kind: failure.kind, url: url);
      return false;
    }
  }

  /// Signs in with [url] + [username] + [password], persists the resulting
  /// session, and flips to connected. Returns whether it succeeded.
  ///
  /// The password is forwarded once to obtain the tokens and never stored.
  Future<bool> signIn({
    required String url,
    required String username,
    required String password,
  }) async {
    state = AudiobookshelfSettingsState(
      phase: AudiobookshelfConnectionPhase.signingIn,
      baseUrl: url,
      username: username,
    );
    try {
      await requireLocalNetworkFor(ref, url);
      final AudiobookshelfSession newSession =
          await ref.read(audiobookshelfAuthenticatorProvider).signIn(
                rawUrl: url,
                username: username,
                password: password,
                // Only for the very address the test confirmed, never another.
                serverStatus: url == _testedBaseUrl ? _testedStatus : null,
              );
      final bool adopted = await _serially(() async {
        try {
          await ref.read(audiobookshelfSessionStoreProvider).write(newSession);
        } catch (error) {
          // The new session couldn't reach the keyring. Adopting it anyway
          // would look signed in until the next launch and then silently be
          // gone, so don't: report it and let the user fix the keyring and
          // retry. The tokens are dropped here rather than kept anywhere else.
          _setFailure(
            "Couldn't save your Audiobookshelf sign-in on this device. "
            '${_storageRemedy(error)}',
            url: url,
            username: username,
          );
          return false;
        }
        _session = newSession;
        _signIns++;
        _unsaved = null;
        _unsavedWarning = null;
        _refused = null;
        return true;
      });
      if (!adopted) return false;
      _forgetTestedStatus();
      state = AudiobookshelfSettingsState(
        phase: AudiobookshelfConnectionPhase.connected,
        baseUrl: newSession.baseUrl,
        username: newSession.userName,
        serverVersion: newSession.serverVersion,
        statusMessage: _connectedMessage(newSession.userName),
      );
      // Show what the account can actually see straight away, so a successful
      // sign-in ends on real libraries rather than on "connected, probably".
      // Fire-and-forget: sign-in returns now and the listing reports itself.
      unawaited(refreshLibraries());
      return true;
    } catch (error) {
      final AudiobookshelfException failure = _typed(error);
      _setFailure(failure.message,
          kind: failure.kind, url: url, username: username);
      return false;
    }
  }

  /// [error] as the [AudiobookshelfException] it reports. Anything else (a
  /// response that broke parsing, say) still has to end a test or sign-in,
  /// or the card would stay busy until a restart.
  static AudiobookshelfException _typed(Object error) =>
      error is AudiobookshelfException
          ? error
          : error is LocalNetworkBlockedException
              ? AudiobookshelfException(error.message,
                  kind: AudiobookshelfErrorKind.notReachable)
              : AudiobookshelfException.unsupportedResponse();

  /// Runs [request] for [session], renewing the tokens once when the server
  /// says the access token has expired (a 401), then running [request] once
  /// more with the new ones.
  ///
  /// [request] is handed the session to use: [session], or its renewal.
  /// Callers that check whether a response still belongs on screen compare
  /// accounts ([AudiobookshelfSession.isSameAccountAs]) rather than session
  /// identity, since a renewal replaces the session object.
  ///
  /// Throws [AudiobookshelfException.sessionExpired] when the tokens can't be
  /// renewed without the password or the renewed ones are turned down too,
  /// and whatever the renewal or the second attempt throws otherwise. Never
  /// more than one renewal and one retry.
  Future<T> authorized<T>(
    AudiobookshelfSession session,
    Future<T> Function(AudiobookshelfSession session) request,
  ) async {
    _retryUnsavedSave();
    // Tokens renewed since the caller picked [session] up are used straight
    // away rather than after a 401 of their own.
    final AudiobookshelfSession? live = _session;
    final AudiobookshelfSession first =
        live != null && live.isSameAccountAs(session) ? live : session;
    try {
      return await request(first);
    } on AudiobookshelfException catch (error) {
      // A 403 is a permission the account doesn't have, not an expired
      // token; renewing would not change the answer.
      if (error.kind != AudiobookshelfErrorKind.unauthorized ||
          error.statusCode != 401) {
        rethrow;
      }
      final AudiobookshelfSession? renewed = await _renewAfter(first);
      if (renewed == null) throw AudiobookshelfException.sessionExpired();
      try {
        return await request(renewed);
      } on AudiobookshelfException catch (retryError) {
        if (retryError.kind != AudiobookshelfErrorKind.unauthorized ||
            retryError.statusCode != 401) {
          rethrow;
        }
        // Turned down with tokens the server has only just handed out:
        // renewing again would spend the next refresh token the same way, on
        // every request. Only a new sign-in gets past this.
        if (identical(_session, renewed)) _refused = renewed;
        throw AudiobookshelfException.sessionExpired();
      }
    }
  }

  /// The session to retry with after [stale] got a 401, renewing it if no
  /// one has yet, or `null` when only the password can help.
  Future<AudiobookshelfSession?> _renewAfter(AudiobookshelfSession stale) {
    final AudiobookshelfSession? current = _session;
    // Signed out, or somebody else signed in, while the request was out: the
    // session it was turned down for is gone.
    if (current == null || !current.isSameAccountAs(stale)) {
      return Future<AudiobookshelfSession?>.value();
    }
    // Another request renewed the tokens after this one went out with the
    // old ones: retry with the new ones rather than rotating again.
    if (!identical(current, stale)) {
      return Future<AudiobookshelfSession?>.value(current);
    }
    if (identical(_refused, stale)) {
      return Future<AudiobookshelfSession?>.value();
    }
    final Future<AudiobookshelfSession?>? inFlight = _renewal;
    if (inFlight != null && identical(_renewing, stale)) return inFlight;
    _renewing = stale;
    final Future<AudiobookshelfSession?> renewal =
        _renew(stale).whenComplete(() {
      if (identical(_renewing, stale)) {
        _renewing = null;
        _renewal = null;
      }
    });
    _renewal = renewal;
    return renewal;
  }

  Future<AudiobookshelfSession?> _renew(AudiobookshelfSession stale) async {
    final String? refreshToken = stale.refreshToken;
    // Audiobookshelf before 2.26 gives no refresh token. Its token doesn't
    // expire, so a 401 there means the password is the only way back.
    if (refreshToken == null) return null;
    final AudiobookshelfAuthResult result;
    try {
      result = await ref.read(audiobookshelfClientProvider).refreshTokens(
            baseUrl: stale.baseUrl,
            refreshToken: refreshToken,
          );
    } on AudiobookshelfException catch (error) {
      if (error.kind == AudiobookshelfErrorKind.unauthorized) {
        // Expired, already traded in, or revoked on the server.
        if (identical(_session, stale)) _refused = stale;
        return null;
      }
      // Unreachable or a server error: the refresh token wasn't spent, and
      // the next request can try again.
      rethrow;
    }
    if (result.userId != stale.userId) {
      // Tokens for some other account are never adopted.
      throw AudiobookshelfException.unsupportedResponse();
    }
    final AudiobookshelfSession renewed = AudiobookshelfSession(
      baseUrl: stale.baseUrl,
      userId: stale.userId,
      accessToken: result.accessToken,
      // Exactly what the server sent: the old refresh token is spent once
      // traded in, so it is not kept as a fallback.
      refreshToken: result.refreshToken,
      userName: stale.userName,
      defaultLibraryId: stale.defaultLibraryId,
      serverVersion: stale.serverVersion,
    );
    return _serially(() async {
      // A sign-out or another sign-in landed while the server was answering
      // and owns the session now: these tokens belong to nobody.
      if (!identical(_session, stale)) return null;
      try {
        await ref.read(audiobookshelfSessionStoreProvider).write(renewed);
        _unsaved = null;
        _unsavedWarning = null;
      } catch (error) {
        // The renewal already happened on the server, and the tokens on disk
        // may stop working any moment, so the new ones are used anyway. The
        // save is tried again with the next request; until it lands, a
        // restart may need a fresh sign-in, and the card says so.
        _unsaved = renewed;
        _unsavedWarning = "Couldn't save your renewed Audiobookshelf sign-in "
            'on this device, so you may have to sign in again after '
            'restarting Linthra. ${_storageRemedy(error)}';
        state = _connectedState(
          renewed,
          isLoadingLibraries: state.isLoadingLibraries,
        );
      }
      _session = renewed;
      return renewed;
    });
  }

  /// Tries again to save a renewed session the keyring refused, without
  /// holding up the request that triggered it.
  void _retryUnsavedSave() {
    final AudiobookshelfSession? unsaved = _unsaved;
    if (unsaved == null || _retryingSave) return;
    _retryingSave = true;
    unawaited(_serially(() async {
      if (!identical(_session, unsaved) || !identical(_unsaved, unsaved)) {
        return;
      }
      try {
        await ref.read(audiobookshelfSessionStoreProvider).write(unsaved);
        if (identical(_unsaved, unsaved)) {
          final String? warning = _unsavedWarning;
          _unsaved = null;
          _unsavedWarning = null;
          // Saved now, so the restart warning no longer holds. Whatever error
          // it was shown beside still does.
          final String? shown = state.errorMessage;
          if (warning != null && shown != null && shown.endsWith(warning)) {
            final String rest =
                shown.substring(0, shown.length - warning.length).trimRight();
            state = _connectedState(
              unsaved,
              isLoadingLibraries: state.isLoadingLibraries,
              errorMessage: rest.isEmpty ? null : rest,
              errorKind: rest.isEmpty ? null : state.errorKind,
            );
          }
        }
      } catch (_) {
        // Still refused. The session in memory keeps working, and the next
        // request tries again.
      }
    }).whenComplete(() => _retryingSave = false));
  }

  /// Runs [change] once every session change asked for before it is done.
  Future<T> _serially<T>(Future<T> Function() change) {
    final Future<T> result = _sessionChanges.then((_) => change());
    // A change that fails must not hold up the ones queued after it.
    _sessionChanges = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Lists the libraries this account can see. A no-op when not connected.
  ///
  /// A failure here is not a lost connection: the session is still good, the
  /// listing just didn't come back, so it surfaces as a message and leaves the
  /// connected state alone.
  Future<void> refreshLibraries() async {
    final AudiobookshelfSession? current = _session;
    if (current == null) return;
    final int signIn = _signIns;
    // A new attempt drops the previous listing's error, so a retry that works
    // doesn't leave the old failure sitting under a fresh list.
    state = _connectedState(current, isLoadingLibraries: true);
    try {
      final List<AudiobookshelfLibraryDto> libraries = await authorized(
        current,
        ref.read(audiobookshelfClientProvider).fetchLibraries,
      );
      // A sign-out (or another sign-in, even to the same account) that landed
      // while this was in flight owns the state now; don't paint a stale
      // listing over it. A renewal of the tokens is not that.
      if (signIn != _signIns) return;
      state = _connectedState(
        current,
        libraries: <AudiobookshelfLibrarySummary>[
          for (final AudiobookshelfLibraryDto library in libraries)
            AudiobookshelfLibrarySummary(
              id: library.id,
              name: library.name,
              mediaType: library.mediaType,
            ),
        ],
      );
    } on AudiobookshelfException catch (error) {
      if (signIn != _signIns) return;
      // The listing failed, the session didn't: stay connected and say what
      // went wrong.
      state = _connectedState(
        current,
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// The connected state for [session], rebuilt from the session itself rather
  /// than copied from the previous state, so a stale error or spinner can't
  /// survive into it.
  AudiobookshelfSettingsState _connectedState(
    AudiobookshelfSession session, {
    List<AudiobookshelfLibrarySummary>? libraries,
    bool isLoadingLibraries = false,
    String? errorMessage,
    AudiobookshelfErrorKind? errorKind,
  }) {
    return AudiobookshelfSettingsState(
      phase: AudiobookshelfConnectionPhase.connected,
      baseUrl: session.baseUrl,
      username: session.userName,
      serverVersion: session.serverVersion,
      libraries: libraries ?? state.libraries,
      isLoadingLibraries: isLoadingLibraries,
      statusMessage: _connectedMessage(session.userName),
      errorMessage: _withUnsavedWarning(errorMessage),
      errorKind: errorKind,
    );
  }

  /// [message] followed by the unsaved-renewal warning while there is one, so
  /// a request failing in the meantime doesn't hide that a restart may need a
  /// fresh sign-in.
  String? _withUnsavedWarning(String? message) {
    final String? warning = _unsavedWarning;
    if (message == null) return warning;
    if (warning == null) return message;
    return '$message\n\n$warning';
  }

  /// Clears the saved session and resets to the disconnected state.
  Future<void> clear() => _serially(() async {
        try {
          await ref.read(audiobookshelfSessionStoreProvider).clear();
        } catch (error) {
          // The tokens would stay in the keyring; report it rather than
          // pretending the sign-out happened. Nothing else is torn down, so a
          // retry after unlocking the keyring completes the same sign-out.
          _setFailure(
            "Couldn't remove your Audiobookshelf sign-in from this device. "
            '${_storageRemedy(error)}',
          );
          return;
        }
        _session = null;
        _signIns++;
        _unsaved = null;
        _unsavedWarning = null;
        _refused = null;
        _forgetTestedStatus();
        state = const AudiobookshelfSettingsState(
          statusMessage:
              'Signed out. Your Audiobookshelf settings were cleared.',
        );
      });

  void _forgetTestedStatus() {
    _testedBaseUrl = null;
    _testedStatus = null;
  }

  /// The user-facing tail for a secure-storage failure: what went wrong with
  /// the keyring and what to do about it. Never carries any part of the value
  /// that was being read or written (see [SecureStorageException]).
  String _storageRemedy(Object error) =>
      error is SecureStorageException ? error.remedy : 'Try again.';

  /// Reports an error without dropping an existing connection: a failed test or
  /// re-auth keeps any session that's still valid, it just surfaces the message.
  void _setFailure(
    String message, {
    AudiobookshelfErrorKind? kind,
    String? url,
    String? username,
  }) {
    final AudiobookshelfSession? current = _session;
    if (current != null) {
      state = _connectedState(current, errorMessage: message, errorKind: kind);
      return;
    }
    state = AudiobookshelfSettingsState(
      baseUrl: url,
      username: username,
      serverVersion: state.serverVersion,
      errorMessage: message,
      errorKind: kind,
    );
  }

  String _connectedMessage(String? userName) {
    if (userName == null || userName.isEmpty) {
      return 'Signed in to Audiobookshelf.';
    }
    return 'Signed in as $userName.';
  }

  String _reachableMessage(AudiobookshelfServerStatus status) {
    final String? version = status.serverVersion;
    if (version == null || version.isEmpty) {
      return 'Reached an Audiobookshelf server. Sign in to continue.';
    }
    return 'Reached Audiobookshelf $version. Sign in to continue.';
  }
}

final audiobookshelfSettingsControllerProvider = NotifierProvider<
    AudiobookshelfSettingsController, AudiobookshelfSettingsState>(
  AudiobookshelfSettingsController.new,
);
