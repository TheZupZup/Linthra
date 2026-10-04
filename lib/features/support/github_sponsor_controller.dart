import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/github_device_authorization.dart';
import '../../core/models/github_sponsor_status.dart';
import '../../core/models/github_sponsor_verification.dart';
import '../../core/repositories/github_sponsor_token_store.dart';
import '../../core/services/github_sponsor_client.dart';
import '../../data/repositories/github_sponsor_token_store_provider.dart';
import '../../data/services/github_sponsor_client_provider.dart';
import 'support_actions_provider.dart';

/// How long a successful GitHub Sponsor verification may stay trusted without
/// another check.
///
/// The timer is a lease, not a cache: when it expires the controller enters the
/// fail-closed checking state before asking GitHub again. Tests override this
/// provider with a short duration.
final githubSponsorRevalidationIntervalProvider = Provider<Duration>(
  (ref) => const Duration(hours: 6),
);

/// Restores, verifies, and refreshes the GitHub Sponsors cosmetic unlock.
///
/// Every operation, the launch check included, takes a new epoch. Whatever an
/// older operation was still waiting on (GitHub, secure storage) is dropped
/// when it returns, so a late answer never writes over a newer status: the
/// newest operation decides, and a disconnect always wins.
class GitHubSponsorController extends AsyncNotifier<GitHubSponsorStatus> {
  Timer? _revalidationTimer;
  DateTime? _lastActiveVerificationAt;
  int _operationEpoch = 0;

  /// The device flow that closing its dialog can still abandon: begun, with
  /// no token from GitHub yet.
  _PendingAuthorization? _pendingAuthorization;

  @override
  Future<GitHubSponsorStatus> build() async {
    // Riverpod applies a build's result even after a newer operation set the
    // state, so without an epoch a slow launch check of the old token would
    // write over a newer sign-in or a disconnect. Disposal supersedes
    // everything still in flight.
    final int operation = _startOperation();
    _pendingAuthorization = null;
    ref.onDispose(() {
      _startOperation();
      _pendingAuthorization = null;
    });

    final SupportDistribution distribution =
        ref.watch(supportDistributionProvider);
    if (distribution != SupportDistribution.githubRelease) {
      return GitHubSponsorStatus.unavailable;
    }

    final GitHubSponsorClient client = ref.watch(githubSponsorClientProvider);
    if (!client.isConfigured) {
      return const GitHubSponsorStatus(
        access: GitHubSponsorAccess.unavailable,
        message: 'GitHub sponsor verification is not configured in this APK.',
      );
    }

    final GitHubSponsorTokenStore store =
        ref.watch(githubSponsorTokenStoreProvider);
    // Same handling as refresh(): a failed launch-time check (secure storage
    // that cannot be read, offline, a revoked token, a bad response) is an
    // error status, not a provider error, so the card can still show why and
    // offer to disconnect.
    String? accessToken;
    try {
      accessToken = await store.read();
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      if (accessToken == null) {
        return GitHubSponsorStatus.signedOut;
      }

      final GitHubSponsorStatus status = await _verify(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      return GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
        // A store that cannot be read counts as nothing stored, the same as
        // in _hasStoredAuthorization.
        connected: accessToken != null,
      );
    }
  }

  Future<GitHubDeviceAuthorization> beginAuthorization() async {
    final _PendingAuthorization pending = _PendingAuthorization(
      statusToRestore: _restorableStatus(state),
    );
    final int operation = _startOperation();
    _pendingAuthorization = pending;
    final GitHubSponsorClient client = ref.read(githubSponsorClientProvider);
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubDeviceAuthorization authorization =
          await client.requestDeviceAuthorization();
      if (operation != _operationEpoch) {
        throw const GitHubSponsorAuthenticationException(
          'GitHub authorization was cancelled.',
        );
      }
      return authorization;
    } on Object catch (error) {
      if (operation == _operationEpoch) {
        // No dialog opens for a flow that never started, so there is nothing
        // left to cancel.
        _pendingAuthorization = null;
        await _finishWithError(operation, _messageFor(error));
      }
      rethrow;
    }
  }

  /// Abandons a device flow GitHub has not handed a token to yet, returning
  /// to the status from before it began.
  ///
  /// The dialog can be closed before any token exists. Without this reset,
  /// the flow leaves the provider in checking forever and the Connect GitHub
  /// button stays disabled until the process restarts.
  ///
  /// Once GitHub returned a token, closing the dialog no longer abandons the
  /// flow: the token is stored, and the verification that follows decides
  /// the status, so Check again and Disconnect stay available for it. This is
  /// then a no-op, as it is when no flow is pending at all.
  void cancelAuthorization() {
    final _PendingAuthorization? pending = _pendingAuthorization;
    if (pending == null) {
      return;
    }
    _startOperation();
    _pendingAuthorization = null;

    final GitHubSponsorStatus? previous = pending.statusToRestore;
    if (previous == null) {
      // Nothing settled and locked to go back to: ask GitHub again instead
      // of reinstating an old result.
      unawaited(refresh());
      return;
    }
    state = AsyncData(previous);
  }

  Future<GitHubSponsorStatus> completeAuthorization(
    GitHubDeviceAuthorization authorization,
  ) async {
    // Still the same device flow (a retry after a failed poll included): it
    // stays cancellable until GitHub hands over a token.
    final _PendingAuthorization? pending = _pendingAuthorization;
    final int operation = _startOperation();
    _pendingAuthorization = pending;
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubSponsorClient client = ref.read(githubSponsorClientProvider);
      final String accessToken = await client.pollForAccessToken(authorization);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }

      // GitHub handed over a token: from here the flow finishes on its own.
      _pendingAuthorization = null;
      await ref.read(githubSponsorTokenStoreProvider).write(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }

      final GitHubSponsorStatus status = await _verify(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      final bool tokenMatches = await _tokenStillMatches(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      if (!tokenMatches) {
        return await _finishTokenConfirmationFailure(operation);
      }

      state = AsyncData(status);
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      return _finishWithError(operation, _messageFor(error));
    }
  }

  Future<GitHubSponsorStatus> refresh() async {
    final int operation = _startOperation();
    _pendingAuthorization = null;
    // Expired Sponsor access fails closed while GitHub is being checked. A
    // stale active result is never kept on screen during a network request.
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubSponsorTokenStore store =
          ref.read(githubSponsorTokenStoreProvider);
      final String? accessToken = await store.read();
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      if (accessToken == null) {
        state = const AsyncData(GitHubSponsorStatus.signedOut);
        return GitHubSponsorStatus.signedOut;
      }

      final GitHubSponsorStatus status = await _verify(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      final bool tokenMatches = await _tokenStillMatches(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      if (!tokenMatches) {
        return await _finishTokenConfirmationFailure(operation);
      }

      state = AsyncData(status);
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      return _finishWithError(operation, _messageFor(error));
    }
  }

  /// Rechecks an active entitlement when its successful verification is stale.
  ///
  /// The periodic timer normally does this. The app also calls this on resume
  /// because Android may suspend Dart timers while Linthra is backgrounded.
  Future<void> revalidateIfStale({DateTime? now}) async {
    if (ref.read(supportDistributionProvider) !=
        SupportDistribution.githubRelease) {
      return;
    }
    if (state.valueOrNull?.hasActiveMonthlySponsorship != true) {
      return;
    }

    final DateTime? lastVerified = _lastActiveVerificationAt;
    final Duration interval =
        ref.read(githubSponsorRevalidationIntervalProvider);
    final DateTime current = now ?? DateTime.now();
    if (lastVerified != null && current.difference(lastVerified) < interval) {
      return;
    }

    await refresh();
  }

  /// Forgets the stored GitHub authorization.
  ///
  /// Locks before secure storage is cleared, so the palette never stays
  /// unlocked while the token is being removed, or after removing it failed.
  Future<void> disconnect() async {
    final int operation = _startOperation();
    _pendingAuthorization = null;
    _lastActiveVerificationAt = null;
    state = const AsyncData(GitHubSponsorStatus.signedOut);
    try {
      await ref.read(githubSponsorTokenStoreProvider).clear();
    } on Object {
      if (operation != _operationEpoch) {
        return;
      }
      // The token is still stored, and checked again at the next launch, so
      // there is still something to disconnect.
      state = const AsyncData(
        GitHubSponsorStatus(
          access: GitHubSponsorAccess.error,
          message: 'Could not remove the GitHub authorization from this '
              'device. Try again.',
          connected: true,
        ),
      );
    }
  }

  /// Supersedes every operation still in flight and stops the lease timer.
  int _startOperation() {
    _cancelRevalidation();
    return ++_operationEpoch;
  }

  Future<GitHubSponsorStatus> _verify(String accessToken) async {
    final GitHubSponsorVerification verification = await ref
        .read(githubSponsorClientProvider)
        .verifySponsorship(accessToken);
    return GitHubSponsorStatus(
      access: verification.hasActiveMonthlySponsorship
          ? GitHubSponsorAccess.active
          : GitHubSponsorAccess.inactive,
      login: verification.login,
      message: verification.hasActiveMonthlySponsorship
          ? null
          : 'This GitHub account does not have an active monthly sponsorship.',
      connected: true,
    );
  }

  void _recordVerification(GitHubSponsorStatus status) {
    _cancelRevalidation();
    if (!status.hasActiveMonthlySponsorship) {
      _lastActiveVerificationAt = null;
      return;
    }

    _lastActiveVerificationAt = DateTime.now();
    final Duration interval =
        ref.read(githubSponsorRevalidationIntervalProvider);
    if (interval <= Duration.zero) {
      return;
    }

    _revalidationTimer = Timer(interval, () {
      _revalidationTimer = null;
      unawaited(refresh());
    });
  }

  void _cancelRevalidation() {
    _revalidationTimer?.cancel();
    _revalidationTimer = null;
  }

  Future<bool> _tokenStillMatches(String expected) async {
    try {
      return await ref.read(githubSponsorTokenStoreProvider).read() == expected;
    } on Object {
      return false;
    }
  }

  Future<GitHubSponsorStatus> _finishTokenConfirmationFailure(int operation) {
    return _finishWithError(
      operation,
      'GitHub authorization changed while checking. Try again.',
    );
  }

  /// Settles [operation] on a locked error status, unless a newer operation
  /// took over while secure storage was asked whether anything is still
  /// connected.
  Future<GitHubSponsorStatus> _finishWithError(
    int operation,
    String message,
  ) async {
    final bool connected = await _hasStoredAuthorization();
    if (operation != _operationEpoch) {
      return _currentStatus;
    }

    final GitHubSponsorStatus status = GitHubSponsorStatus(
      access: GitHubSponsorAccess.error,
      message: message,
      connected: connected,
    );
    state = AsyncData(status);
    _cancelRevalidation();
    return status;
  }

  GitHubSponsorStatus get _currentStatus =>
      state.valueOrNull ?? GitHubSponsorStatus.signedOut;

  /// Whether a token is stored, so an error status can say whether there is
  /// anything to disconnect. A store that cannot be read counts as nothing
  /// stored: there is then nothing Linthra could send either.
  Future<bool> _hasStoredAuthorization() async {
    try {
      return await ref.read(githubSponsorTokenStoreProvider).read() != null;
    } on Object {
      return false;
    }
  }

  String _messageFor(Object error) {
    if (error is GitHubSponsorAuthenticationException) {
      return error.message;
    }
    return 'GitHub sponsor verification failed. Try again.';
  }

  /// The status a cancelled device flow may go back to: only a settled one
  /// that grants nothing. A check still in flight, or an active result whose
  /// lease the flow may outlive, is asked again instead of reinstated.
  static GitHubSponsorStatus? _restorableStatus(
    AsyncValue<GitHubSponsorStatus> value,
  ) {
    final GitHubSponsorStatus? status = value.valueOrNull;
    if (value.isLoading ||
        value.hasError ||
        status == null ||
        status.access == GitHubSponsorAccess.checking ||
        status.hasActiveMonthlySponsorship) {
      return null;
    }
    return status;
  }
}

/// A device flow GitHub has not handed a token to yet.
class _PendingAuthorization {
  const _PendingAuthorization({required this.statusToRestore});

  /// What closing the dialog goes back to. Null: ask GitHub again.
  final GitHubSponsorStatus? statusToRestore;
}

final githubSponsorControllerProvider =
    AsyncNotifierProvider<GitHubSponsorController, GitHubSponsorStatus>(
  GitHubSponsorController.new,
);
