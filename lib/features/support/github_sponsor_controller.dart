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
class GitHubSponsorController extends AsyncNotifier<GitHubSponsorStatus> {
  Timer? _revalidationTimer;
  DateTime? _lastActiveVerificationAt;
  GitHubSponsorStatus? _statusBeforeAuthorization;
  int _operationEpoch = 0;

  @override
  Future<GitHubSponsorStatus> build() async {
    ref.onDispose(() {
      _revalidationTimer?.cancel();
      _revalidationTimer = null;
    });

    final SupportDistribution distribution =
        ref.watch(supportDistributionProvider);
    if (distribution != SupportDistribution.githubRelease) {
      _cancelRevalidation();
      return GitHubSponsorStatus.unavailable;
    }

    final GitHubSponsorClient client = ref.watch(githubSponsorClientProvider);
    if (!client.isConfigured) {
      _cancelRevalidation();
      return const GitHubSponsorStatus(
        access: GitHubSponsorAccess.unavailable,
        message: 'GitHub sponsor verification is not configured in this APK.',
      );
    }

    final String? accessToken =
        await ref.watch(githubSponsorTokenStoreProvider).read();
    if (accessToken == null) {
      _cancelRevalidation();
      return GitHubSponsorStatus.signedOut;
    }
    // Same handling as refresh(): a failed launch-time check (offline, a
    // revoked token, a bad response) is an error status, not a provider
    // error, so the card can still show why and offer to disconnect.
    try {
      final GitHubSponsorStatus status = await _verify(accessToken);
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      _cancelRevalidation();
      return GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
        connected: true,
      );
    }
  }

  Future<GitHubDeviceAuthorization> beginAuthorization() async {
    final int operation = ++_operationEpoch;
    _statusBeforeAuthorization = state.valueOrNull;
    _cancelRevalidation();
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
        state = AsyncData(
          GitHubSponsorStatus(
            access: GitHubSponsorAccess.error,
            message: _messageFor(error),
            connected: await _hasStoredAuthorization(),
          ),
        );
        _statusBeforeAuthorization = null;
      }
      rethrow;
    }
  }

  /// Restores the state that existed before a device-flow attempt.
  ///
  /// The dialog can be cancelled before any token exists. Without this reset,
  /// beginAuthorization leaves the provider in checking forever and the
  /// Connect GitHub button stays disabled until the process restarts.
  void cancelAuthorization() {
    ++_operationEpoch;
    _cancelRevalidation();
    final GitHubSponsorStatus previous =
        _statusBeforeAuthorization ?? GitHubSponsorStatus.signedOut;
    _statusBeforeAuthorization = null;
    state = AsyncData(previous);
    _recordVerification(previous);
  }

  Future<GitHubSponsorStatus> completeAuthorization(
    GitHubDeviceAuthorization authorization,
  ) async {
    final int operation = ++_operationEpoch;
    _statusBeforeAuthorization = null;
    _cancelRevalidation();
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubSponsorClient client = ref.read(githubSponsorClientProvider);
      final String accessToken = await client.pollForAccessToken(authorization);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }

      await ref.read(githubSponsorTokenStoreProvider).write(accessToken);
      if (operation != _operationEpoch) {
        return _currentStatus;
      }

      final GitHubSponsorStatus status = await _verify(accessToken);
      if (operation != _operationEpoch ||
          !await _tokenStillMatches(accessToken)) {
        return _currentStatus;
      }

      state = AsyncData(status);
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      final GitHubSponsorStatus status = GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
        connected: await _hasStoredAuthorization(),
      );
      state = AsyncData(status);
      _cancelRevalidation();
      return status;
    }
  }

  Future<GitHubSponsorStatus> refresh() async {
    final int operation = ++_operationEpoch;
    _statusBeforeAuthorization = null;
    _cancelRevalidation();
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
      if (operation != _operationEpoch ||
          !await _tokenStillMatches(accessToken)) {
        return _currentStatus;
      }

      state = AsyncData(status);
      _recordVerification(status);
      return status;
    } on Object catch (error) {
      if (operation != _operationEpoch) {
        return _currentStatus;
      }
      final GitHubSponsorStatus status = GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
        connected: await _hasStoredAuthorization(),
      );
      state = AsyncData(status);
      _cancelRevalidation();
      return status;
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

  Future<void> disconnect() async {
    ++_operationEpoch;
    _statusBeforeAuthorization = null;
    _cancelRevalidation();
    await ref.read(githubSponsorTokenStoreProvider).clear();
    state = const AsyncData(GitHubSponsorStatus.signedOut);
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
}

final githubSponsorControllerProvider =
    AsyncNotifierProvider<GitHubSponsorController, GitHubSponsorStatus>(
  GitHubSponsorController.new,
);
