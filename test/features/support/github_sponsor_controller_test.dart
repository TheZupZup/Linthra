import 'dart:async';
import 'dart:io';

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
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  ProviderContainer createContainer({
    String? storedToken,
    bool active = false,
    Duration revalidationInterval = const Duration(hours: 6),
    _FakeGitHubSponsorClient? client,
  }) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorRevalidationIntervalProvider.overrideWithValue(
          revalidationInterval,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(
          InMemoryGitHubSponsorTokenStore(storedToken),
        ),
        githubSponsorClientProvider.overrideWithValue(
          client ?? _FakeGitHubSponsorClient(active: active),
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

  test('active Sponsor access is periodically revalidated and relocked',
      () async {
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container = createContainer(
      storedToken: 'saved-token',
      client: client,
      revalidationInterval: const Duration(milliseconds: 10),
    );

    await container.read(githubSponsorControllerProvider.future);
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.unlocked,
    );
    expect(client.verificationCalls, 1);

    client.active = false;
    await _waitUntil(() => client.verificationCalls >= 2);

    bool isInactive() {
      final GitHubSponsorStatus? status =
          container.read(githubSponsorControllerProvider).valueOrNull;
      return status?.access == GitHubSponsorAccess.inactive;
    }

    await _waitUntil(isInactive);

    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.locked,
    );
  });

  test('failed stale revalidation fails closed instead of keeping access',
      () async {
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container = createContainer(
      storedToken: 'saved-token',
      client: client,
    );

    await container.read(githubSponsorControllerProvider.future);
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.unlocked,
    );

    client.failVerification = true;
    final GitHubSponsorController controller =
        container.read(githubSponsorControllerProvider.notifier);
    await controller.revalidateIfStale(
      now: DateTime.now().add(const Duration(hours: 7)),
    );

    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.error,
    );
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.locked,
    );
  });

  test('disconnect wins over an older in-flight Sponsor verification',
      () async {
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore('saved-token');
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    await container.read(githubSponsorControllerProvider.future);
    final Completer<GitHubSponsorVerification> delayed =
        Completer<GitHubSponsorVerification>();
    client.nextVerification = delayed;

    final Future<GitHubSponsorStatus> refresh = container
        .read(githubSponsorControllerProvider.notifier)
        .refresh();
    await _waitUntil(() => client.verificationCalls >= 2);

    await container.read(githubSponsorControllerProvider.notifier).disconnect();
    delayed.complete(
      const GitHubSponsorVerification(
        login: 'music-fan',
        hasActiveMonthlySponsorship: true,
      ),
    );
    await refresh;

    expect(await store.read(), isNull);
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.signedOut,
    );
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.locked,
    );
  });

  test('cancelling device authorization restores the previous state',
      () async {
    final ProviderContainer container = createContainer();
    await container.read(githubSponsorControllerProvider.future);

    await container
        .read(githubSponsorControllerProvider.notifier)
        .beginAuthorization();
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.checking,
    );

    container
        .read(githubSponsorControllerProvider.notifier)
        .cancelAuthorization();

    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.signedOut,
    );
  });

  test('non-GitHub distributions never start Sponsor revalidation', () async {
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.fdroid,
        ),
        githubSponsorRevalidationIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 1),
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(
          InMemoryGitHubSponsorTokenStore('saved-token'),
        ),
        githubSponsorClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    final GitHubSponsorStatus status =
        await container.read(githubSponsorControllerProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(status.access, GitHubSponsorAccess.unavailable);
    expect(client.verificationCalls, 0);
  });

  test('a failed launch-time check is an error status, not a provider error',
      () async {
    // The card only offers Disconnect for a status it can read. If the check
    // at launch threw, the saved token would be stuck and retried forever.
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore('saved-token');
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: false, failVerification: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    final GitHubSponsorStatus status =
        await container.read(githubSponsorControllerProvider.future);

    expect(status.access, GitHubSponsorAccess.error);
    expect(status.message, isNotNull);
    expect(status.connected, isTrue);
    expect(await store.read(), 'saved-token');

    await container.read(githubSponsorControllerProvider.notifier).disconnect();
    expect(await store.read(), isNull);
  });

  test('a sign-in that fails before any token is stored is not connected',
      () async {
    // Nothing was stored, so the card must not offer to disconnect anything.
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        supportDistributionProvider.overrideWithValue(
          SupportDistribution.githubRelease,
        ),
        githubSponsorTokenStoreProvider.overrideWithValue(store),
        githubSponsorClientProvider.overrideWithValue(
          _FakeGitHubSponsorClient(active: false, failAuthorization: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(githubSponsorControllerProvider.future);

    await expectLater(
      container
          .read(githubSponsorControllerProvider.notifier)
          .beginAuthorization(),
      throwsA(isA<SocketException>()),
    );

    final GitHubSponsorStatus? status =
        container.read(githubSponsorControllerProvider).valueOrNull;
    expect(status?.access, GitHubSponsorAccess.error);
    expect(status?.connected, isFalse);
  });

  test('an inactive sponsor check reports a stored authorization', () async {
    final ProviderContainer container = createContainer(
      storedToken: 'saved-token',
    );

    final GitHubSponsorStatus status =
        await container.read(githubSponsorControllerProvider.future);

    expect(status.access, GitHubSponsorAccess.inactive);
    expect(status.connected, isTrue);
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

    await container.read(githubSponsorControllerProvider.notifier).disconnect();

    expect(await store.read(), isNull);
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.signedOut,
    );
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (int attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition was not reached before the test timeout.');
}

class _FakeGitHubSponsorClient implements GitHubSponsorClient {
  _FakeGitHubSponsorClient({
    required this.active,
    this.failVerification = false,
    this.failAuthorization = false,
  });

  bool active;
  bool failVerification;
  final bool failAuthorization;
  int verificationCalls = 0;
  Completer<GitHubSponsorVerification>? nextVerification;

  @override
  bool get isConfigured => true;

  @override
  Future<GitHubDeviceAuthorization> requestDeviceAuthorization() async {
    if (failAuthorization) {
      throw const SocketException('offline');
    }
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
    verificationCalls++;
    final Completer<GitHubSponsorVerification>? delayed = nextVerification;
    if (delayed != null) {
      nextVerification = null;
      return delayed.future;
    }
    if (failVerification) {
      throw const SocketException('offline');
    }
    return GitHubSponsorVerification(
      login: 'music-fan',
      hasActiveMonthlySponsorship: active,
    );
  }
}
