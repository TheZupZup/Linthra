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

/// Restores, verifies, and refreshes the GitHub Sponsors cosmetic unlock.
class GitHubSponsorController extends AsyncNotifier<GitHubSponsorStatus> {
  @override
  Future<GitHubSponsorStatus> build() async {
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

    final String? accessToken =
        await ref.watch(githubSponsorTokenStoreProvider).read();
    if (accessToken == null) {
      return GitHubSponsorStatus.signedOut;
    }
    return _verify(accessToken);
  }

  Future<GitHubDeviceAuthorization> beginAuthorization() async {
    final GitHubSponsorClient client = ref.read(githubSponsorClientProvider);
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      return await client.requestDeviceAuthorization();
    } on Object catch (error) {
      state = AsyncData(
        GitHubSponsorStatus(
          access: GitHubSponsorAccess.error,
          message: _messageFor(error),
        ),
      );
      rethrow;
    }
  }

  Future<GitHubSponsorStatus> completeAuthorization(
    GitHubDeviceAuthorization authorization,
  ) async {
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubSponsorClient client = ref.read(githubSponsorClientProvider);
      final String accessToken = await client.pollForAccessToken(authorization);
      await ref.read(githubSponsorTokenStoreProvider).write(accessToken);
      final GitHubSponsorStatus status = await _verify(accessToken);
      state = AsyncData(status);
      return status;
    } on Object catch (error) {
      final GitHubSponsorStatus status = GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
      );
      state = AsyncData(status);
      return status;
    }
  }

  Future<GitHubSponsorStatus> refresh() async {
    state = const AsyncData(GitHubSponsorStatus.checking);
    try {
      final GitHubSponsorTokenStore store =
          ref.read(githubSponsorTokenStoreProvider);
      final String? accessToken = await store.read();
      if (accessToken == null) {
        state = const AsyncData(GitHubSponsorStatus.signedOut);
        return GitHubSponsorStatus.signedOut;
      }
      final GitHubSponsorStatus status = await _verify(accessToken);
      state = AsyncData(status);
      return status;
    } on Object catch (error) {
      final GitHubSponsorStatus status = GitHubSponsorStatus(
        access: GitHubSponsorAccess.error,
        message: _messageFor(error),
      );
      state = AsyncData(status);
      return status;
    }
  }

  Future<void> disconnect() async {
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
    );
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
