import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/audiobookshelf_session.dart';
import '../../../core/repositories/secure_storage_exception.dart';
import '../../../core/sources/audiobookshelf/audiobookshelf_api.dart';
import '../../../core/sources/audiobookshelf/audiobookshelf_exception.dart';
import '../../../data/repositories/audiobookshelf_session_store_provider.dart';
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

  /// The address a [testConnection] last succeeded for, with the status it
  /// returned. A sign-in for that same address reuses it instead of asking the
  /// server for `/status` a second time; any other address re-confirms.
  String? _testedBaseUrl;
  AudiobookshelfServerStatus? _testedStatus;

  /// The live signed-in session, or `null` when not connected. Callers must not
  /// log it.
  AudiobookshelfSession? get session => _session;

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
      final AudiobookshelfSession newSession =
          await ref.read(audiobookshelfAuthenticatorProvider).signIn(
                rawUrl: url,
                username: username,
                password: password,
                // Only for the very address the test confirmed, never another.
                serverStatus: url == _testedBaseUrl ? _testedStatus : null,
              );
      try {
        await ref.read(audiobookshelfSessionStoreProvider).write(newSession);
      } catch (error) {
        // The new session couldn't reach the keyring. Adopting it anyway would
        // look signed in until the next launch and then silently be gone, so
        // don't: report it and let the user fix the keyring and retry. The
        // tokens are dropped here rather than kept anywhere else.
        _setFailure(
          "Couldn't save your Audiobookshelf sign-in on this device. "
          '${_storageRemedy(error)}',
          url: url,
          username: username,
        );
        return false;
      }
      _session = newSession;
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
          : AudiobookshelfException.unsupportedResponse();

  /// Lists the libraries this account can see. A no-op when not connected.
  ///
  /// A failure here is not a lost connection: the session is still good, the
  /// listing just didn't come back, so it surfaces as a message and leaves the
  /// connected state alone.
  Future<void> refreshLibraries() async {
    final AudiobookshelfSession? current = _session;
    if (current == null) return;
    // A new attempt drops the previous listing's error, so a retry that works
    // doesn't leave the old failure sitting under a fresh list.
    state = _connectedState(current, isLoadingLibraries: true);
    try {
      final List<AudiobookshelfLibraryDto> libraries =
          await ref.read(audiobookshelfClientProvider).fetchLibraries(current);
      // A sign-out (or another sign-in) that landed while this was in flight
      // owns the state now; don't paint a stale account's libraries over it.
      if (!identical(_session, current)) return;
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
      if (!identical(_session, current)) return;
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
      errorMessage: errorMessage,
      errorKind: errorKind,
    );
  }

  /// Clears the saved session and resets to the disconnected state.
  Future<void> clear() async {
    try {
      await ref.read(audiobookshelfSessionStoreProvider).clear();
    } catch (error) {
      // The tokens would stay in the keyring; report it rather than pretending
      // the sign-out happened. Nothing else is torn down, so a retry after
      // unlocking the keyring completes the same sign-out.
      _setFailure(
        "Couldn't remove your Audiobookshelf sign-in from this device. "
        '${_storageRemedy(error)}',
      );
      return;
    }
    _session = null;
    _forgetTestedStatus();
    state = const AudiobookshelfSettingsState(
      statusMessage: 'Signed out. Your Audiobookshelf settings were cleared.',
    );
  }

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
