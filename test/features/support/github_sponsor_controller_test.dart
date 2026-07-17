import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/github_device_authorization.dart';
import 'package:linthra/core/models/github_sponsor_status.dart';
import 'package:linthra/core/models/github_sponsor_verification.dart';
import 'package:linthra/core/services/github_sponsor_client.dart';
import 'package:linthra/data/repositories/github_sponsor_token_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_github_sponsor_token_store.dart';
import 'package:linthra/data/services/github_sponsor_client_provider.dart';
import 'package:linthra/features/support/github_sponsor_controller.dart';
import 'package:linthra/features/support/support_actions_provider.dart';

void main() {
  ProviderContainer createContainer({
    String? storedToken,
    bool active = false,
  }) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(
          InMemoryGitHubSponsorTokenStore(storedToken),
        ),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: active),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('GitHub APK starts signed out without a saved token', () async {
    final ProviderContainer container = createContainer();

    final GitHubSponsorStatus status =
        await container.read(githubSponsorControllerProvider.future);

    expect(status.access, GitHubSponsorAccess.signedOut);
  });

  test('restores and verifies an active monthly sponsor', () async {
    final ProviderContainer container = createContainer(
      storedToken: 'saved-token',
      active: true,
    );

    final GitHubSponsorStatus status =
        await container.read(githubSponsorControllerProvider.future);

    expect(status.access, GitHubSponsorAccess.active);
    expect(status.login, 'music-fan');
  });

  test('completed device flow stores token and unlocks active sponsor',
      () async {
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(githubSponsorControllerProvider.future);

    final GitHubDeviceAuthorization authorization = await container
        .read(githubSponsorControllerProvider.notifier)
        .beginAuthorization();
    final GitHubSponsorStatus status = await container
        .read(githubSponsorControllerProvider.notifier)
        .completeAuthorization(authorization);

    expect(status.access, GitHubSponsorAccess.active);
    expect(await store.read(), 'new-token');
  });

  test('inactive sponsor remains locked but keeps authorization for refresh',
      () async {
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(githubSponsorControllerProvider.future);

    final GitHubDeviceAuthorization authorization = await container
        .read(githubSponsorControllerProvider.notifier)
        .beginAuthorization();
    final GitHubSponsorStatus status = await container
        .read(githubSponsorControllerProvider.notifier)
        .completeAuthorization(authorization);

    expect(status.access, GitHubSponsorAccess.inactive);
    expect(await store.read(), 'new-token');
  });

  test('disconnect clears the stored GitHub authorization', () async {
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore('saved-token');
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(githubSponsorControllerProvider.future);

    await container
        .read(githubSponsorControllerProvider.notifier)
        .disconnect();

    expect(await store.read(), isNull);
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.signedOut,
    );
  });
}

class _FakeGitHubSponsorClient implements GitHubSponsorClient {
  _FakeGitHubSponsorClient({required this.active});

  final bool active;

  @override
  bool get isConfigured => true;

  @override
  Future<GitHubDeviceAuthorization> requestDeviceAuthorization() async {
    return GitHubDeviceAuthorization(
      deviceCode: 'device-code',
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://github.com/login/device'),
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      pollInterval: Duration.zero,
    );
  }

  @override
  Future<String> pollForAccessToken(
    GitHubDeviceAuthorization authorization,
  ) async {
    return 'new-token';
  }

  @override
  Future<GitHubSponsorVerification> verifySponsorship(
    String accessToken,
  ) async {
    return GitHubSponsorVerification(
      login: 'music-fan',
      hasActiveMonthlySponsorship: active,
    );
  }
}
