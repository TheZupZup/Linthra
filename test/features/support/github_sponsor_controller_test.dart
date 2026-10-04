import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/github_device_authorization.dart';
import 'package:linthra/core/models/github_sponsor_status.dart';
import 'package:linthra/core/models/github_sponsor_verification.dart';
import 'package:linthra/core/repositories/github_sponsor_token_store.dart';
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
    GitHubSponsorTokenStore? store,
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
          store ?? InMemoryGitHubSponsorTokenStore(storedToken),
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

    final Future<GitHubSponsorStatus> refresh =
        container.read(githubSponsorControllerProvider.notifier).refresh();
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

  test('refresh exits checking if the stored token changes mid-verification',
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

    final Future<GitHubSponsorStatus> refresh =
        container.read(githubSponsorControllerProvider.notifier).refresh();
    await _waitUntil(() => client.verificationCalls >= 2);

    await store.write('replacement-token');
    delayed.complete(
      const GitHubSponsorVerification(
        login: 'music-fan',
        hasActiveMonthlySponsorship: true,
      ),
    );
    final GitHubSponsorStatus status = await refresh;

    expect(status.access, GitHubSponsorAccess.error);
    expect(status.connected, isTrue);
    expect(await store.read(), 'replacement-token');
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.error,
    );
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.locked,
    );
  });

  test('refresh exits checking if secure storage fails during confirmation',
      () async {
    final _ControllableGitHubSponsorTokenStore store =
        _ControllableGitHubSponsorTokenStore('saved-token');
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

    final Future<GitHubSponsorStatus> refresh =
        container.read(githubSponsorControllerProvider.notifier).refresh();
    await _waitUntil(() => client.verificationCalls >= 2);

    store.failReads = true;
    delayed.complete(
      const GitHubSponsorVerification(
        login: 'music-fan',
        hasActiveMonthlySponsorship: true,
      ),
    );
    final GitHubSponsorStatus status = await refresh;

    expect(status.access, GitHubSponsorAccess.error);
    expect(status.connected, isFalse);
    expect(
      container.read(githubSponsorControllerProvider).valueOrNull?.access,
      GitHubSponsorAccess.error,
    );
    expect(
      container.read(supporterEntitlementProvider),
      SupporterEntitlement.locked,
    );
  });
  test('cancelling device authorization restores the previous state', () async {
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

  test('completing sign-in exits checking if the token changes mid-check',
      () async {
    final InMemoryGitHubSponsorTokenStore store =
        InMemoryGitHubSponsorTokenStore();
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container =
        createContainer(store: store, client: client);
    await container.read(githubSponsorControllerProvider.future);
    final GitHubSponsorController controller =
        container.read(githubSponsorControllerProvider.notifier);

    final GitHubDeviceAuthorization authorization =
        await controller.beginAuthorization();
    final Completer<GitHubSponsorVerification> delayed =
        Completer<GitHubSponsorVerification>();
    client.nextVerification = delayed;
    final Future<GitHubSponsorStatus> completing =
        controller.completeAuthorization(authorization);
    await _waitUntil(() => client.verificationCalls >= 1);

    await store.write('replacement-token');
    delayed.complete(
      const GitHubSponsorVerification(
        login: 'music-fan',
        hasActiveMonthlySponsorship: true,
      ),
    );
    final GitHubSponsorStatus status = await completing;

    expect(status.access, GitHubSponsorAccess.error);
    expect(status.connected, isTrue);
    expect(_access(container), GitHubSponsorAccess.error);
    expect(_entitlement(container), SupporterEntitlement.locked);
  });

  test('completing sign-in exits checking if secure storage fails mid-check',
      () async {
    final _ControllableGitHubSponsorTokenStore store =
        _ControllableGitHubSponsorTokenStore(null);
    final _FakeGitHubSponsorClient client =
        _FakeGitHubSponsorClient(active: true);
    final ProviderContainer container =
        createContainer(store: store, client: client);
    await container.read(githubSponsorControllerProvider.future);
    final GitHubSponsorController controller =
        container.read(githubSponsorControllerProvider.notifier);

    final GitHubDeviceAuthorization authorization =
        await controller.beginAuthorization();
    final Completer<GitHubSponsorVerification> delayed =
        Completer<GitHubSponsorVerification>();
    client.nextVerification = delayed;
    final Future<GitHubSponsorStatus> completing =
        controller.completeAuthorization(authorization);
    await _waitUntil(() => client.verificationCalls >= 1);

    store.failReads = true;
    delayed.complete(
      const GitHubSponsorVerification(
        login: 'music-fan',
        hasActiveMonthlySponsorship: true,
      ),
    );
    final GitHubSponsorStatus status = await completing;

    expect(status.access, GitHubSponsorAccess.error);
    expect(status.connected, isFalse);
    expect(_access(container), GitHubSponsorAccess.error);
    expect(_entitlement(container), SupporterEntitlement.locked);
  });

  group('the launch check', () {
    test('a slow check of the old token cannot overwrite a newer sign-in',
        () async {
      // Riverpod applies a build's result even after a newer operation set
      // the state. The saved account was a sponsor; before GitHub answers
      // for it, the user signs in with a different account that is not.
      final InMemoryGitHubSponsorTokenStore store =
          InMemoryGitHubSponsorTokenStore('old-token');
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: false);
      final Completer<GitHubSponsorVerification> launchCheck =
          Completer<GitHubSponsorVerification>();
      client.nextVerification = launchCheck;
      final ProviderContainer container = createContainer(
        store: store,
        client: client,
        revalidationInterval: const Duration(milliseconds: 10),
      );
      container.read(githubSponsorControllerProvider);
      await _waitUntil(() => client.verificationCalls >= 1);

      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);
      final GitHubSponsorStatus signedIn = await controller
          .completeAuthorization(await controller.beginAuthorization());
      expect(signedIn.access, GitHubSponsorAccess.inactive);

      launchCheck.complete(
        const GitHubSponsorVerification(
          login: 'old-sponsor',
          hasActiveMonthlySponsorship: true,
        ),
      );
      await _flushAsyncWork();

      expect(_access(container), GitHubSponsorAccess.inactive);
      expect(_entitlement(container), SupporterEntitlement.locked);
      expect(await store.read(), 'new-token');

      // Nor did the late answer start a lease for the old token.
      final int verifications = client.verificationCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.verificationCalls, verifications);
    });

    test('a slow check cannot undo a disconnect', () async {
      final InMemoryGitHubSponsorTokenStore store =
          InMemoryGitHubSponsorTokenStore('saved-token');
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: true);
      final Completer<GitHubSponsorVerification> launchCheck =
          Completer<GitHubSponsorVerification>();
      client.nextVerification = launchCheck;
      final ProviderContainer container =
          createContainer(store: store, client: client);
      container.read(githubSponsorControllerProvider);
      await _waitUntil(() => client.verificationCalls >= 1);

      await container
          .read(githubSponsorControllerProvider.notifier)
          .disconnect();
      launchCheck.complete(
        const GitHubSponsorVerification(
          login: 'music-fan',
          hasActiveMonthlySponsorship: true,
        ),
      );
      await _flushAsyncWork();

      expect(await store.read(), isNull);
      expect(_access(container), GitHubSponsorAccess.signedOut);
      expect(_entitlement(container), SupporterEntitlement.locked);
    });

    test('secure storage that cannot be read is an error status', () async {
      // Not a provider error: the card can only explain a status it reads.
      final _ControllableGitHubSponsorTokenStore store =
          _ControllableGitHubSponsorTokenStore('saved-token')..failReads = true;
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: true);
      final ProviderContainer container =
          createContainer(store: store, client: client);

      final GitHubSponsorStatus status =
          await container.read(githubSponsorControllerProvider.future);

      expect(status.access, GitHubSponsorAccess.error);
      expect(status.message, isNotNull);
      expect(status.connected, isFalse);
      expect(client.verificationCalls, 0);
      expect(_entitlement(container), SupporterEntitlement.locked);
    });

    test('a reload never keeps the previous active result unlocked', () async {
      // Riverpod keeps the previous value while a provider rebuilds.
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: true);
      final ProviderContainer container =
          createContainer(storedToken: 'saved-token', client: client);
      await container.read(githubSponsorControllerProvider.future);
      expect(_entitlement(container), SupporterEntitlement.unlocked);

      final Completer<GitHubSponsorVerification> recheck =
          Completer<GitHubSponsorVerification>();
      client.nextVerification = recheck;
      container.invalidate(githubSponsorControllerProvider);
      expect(_entitlement(container), SupporterEntitlement.locked);
      await _waitUntil(() => client.verificationCalls >= 2);
      expect(_entitlement(container), SupporterEntitlement.locked);

      recheck.complete(
        const GitHubSponsorVerification(
          login: 'music-fan',
          hasActiveMonthlySponsorship: true,
        ),
      );
      await container.read(githubSponsorControllerProvider.future);
      expect(_entitlement(container), SupporterEntitlement.unlocked);
    });
  });

  group('closing the sign-in dialog', () {
    test('after GitHub returned a token keeps the new connection', () async {
      // Android back can close the dialog while the new token is verified.
      // The token is already stored, so the account must stay connected.
      final InMemoryGitHubSponsorTokenStore store =
          InMemoryGitHubSponsorTokenStore();
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: false);
      final ProviderContainer container =
          createContainer(store: store, client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final GitHubDeviceAuthorization authorization =
          await controller.beginAuthorization();
      final Completer<GitHubSponsorVerification> verification =
          Completer<GitHubSponsorVerification>();
      client.nextVerification = verification;
      final Future<GitHubSponsorStatus> completing =
          controller.completeAuthorization(authorization);
      await _waitUntil(() => client.verificationCalls >= 1);

      controller.cancelAuthorization();
      verification.complete(
        const GitHubSponsorVerification(
          login: 'music-fan',
          hasActiveMonthlySponsorship: false,
        ),
      );
      final GitHubSponsorStatus status = await completing;

      expect(status.access, GitHubSponsorAccess.inactive);
      expect(_access(container), GitHubSponsorAccess.inactive);
      expect(
        container.read(githubSponsorControllerProvider).valueOrNull?.connected,
        isTrue,
      );
      expect(await store.read(), 'new-token');
    });

    test('while waiting for GitHub restores the earlier connection', () async {
      final InMemoryGitHubSponsorTokenStore store =
          InMemoryGitHubSponsorTokenStore('old-token');
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: false);
      final ProviderContainer container =
          createContainer(store: store, client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final GitHubDeviceAuthorization authorization =
          await controller.beginAuthorization();
      final Completer<String> poll = Completer<String>();
      client.nextAccessToken = poll;
      final Future<GitHubSponsorStatus> completing =
          controller.completeAuthorization(authorization);
      await _waitUntil(() => client.pollCalls >= 1);

      controller.cancelAuthorization();

      GitHubSponsorStatus? status =
          container.read(githubSponsorControllerProvider).valueOrNull;
      expect(status?.access, GitHubSponsorAccess.inactive);
      expect(status?.connected, isTrue);

      // GitHub approves the abandoned flow later: nothing is stored for it.
      poll.complete('late-token');
      await completing;
      status = container.read(githubSponsorControllerProvider).valueOrNull;
      expect(status?.access, GitHubSponsorAccess.inactive);
      expect(status?.connected, isTrue);
      expect(await store.read(), 'old-token');
    });

    test('while waiting for GitHub stops the polling too', () async {
      // Otherwise every abandoned attempt keeps asking GitHub until its code
      // expires, and back-and-retry stacks those loops up.
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: false);
      final ProviderContainer container = createContainer(client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final GitHubDeviceAuthorization authorization =
          await controller.beginAuthorization();
      client.nextAccessToken = Completer<String>();
      unawaited(controller.completeAuthorization(authorization));
      await _waitUntil(() => client.pollCalls >= 1);
      expect(client.pollCancelled?.call(), isFalse);

      controller.cancelAuthorization();

      expect(client.pollCancelled?.call(), isTrue);
    });

    test('after a failed poll goes back to the earlier connection', () async {
      // Nothing changed: the old token is still the one stored.
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: false);
      final ProviderContainer container =
          createContainer(storedToken: 'old-token', client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final GitHubDeviceAuthorization authorization =
          await controller.beginAuthorization();
      final Completer<String> poll = Completer<String>();
      client.nextAccessToken = poll;
      final Future<GitHubSponsorStatus> completing =
          controller.completeAuthorization(authorization);
      poll.completeError(
        const GitHubSponsorAuthenticationException(
          'GitHub sign-in was cancelled.',
        ),
      );
      expect((await completing).access, GitHubSponsorAccess.error);

      controller.cancelAuthorization();

      final GitHubSponsorStatus? status =
          container.read(githubSponsorControllerProvider).valueOrNull;
      expect(status?.access, GitHubSponsorAccess.inactive);
      expect(status?.connected, isTrue);
    });

    test('of a sign-in begun while active asks GitHub again', () async {
      // Reinstating the old active result would also restart its lease
      // without asking GitHub.
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: true);
      final ProviderContainer container =
          createContainer(storedToken: 'saved-token', client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      client.active = false;
      await controller.beginAuthorization();
      controller.cancelAuthorization();

      expect(_access(container), isNot(GitHubSponsorAccess.active));
      expect(_entitlement(container), SupporterEntitlement.locked);
      await _waitUntil(
        () => _access(container) == GitHubSponsorAccess.inactive,
      );
      expect(client.verificationCalls, 2);
    });
  });

  group('disconnect', () {
    test('wins over an older failure still reading secure storage', () async {
      final _ControllableGitHubSponsorTokenStore store =
          _ControllableGitHubSponsorTokenStore('saved-token');
      final _FakeGitHubSponsorClient client =
          _FakeGitHubSponsorClient(active: true);
      final ProviderContainer container =
          createContainer(store: store, client: client);
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final Completer<GitHubSponsorVerification> failing =
          Completer<GitHubSponsorVerification>();
      client.nextVerification = failing;
      final Future<GitHubSponsorStatus> refresh = controller.refresh();
      await _waitUntil(() => client.verificationCalls >= 2);

      // The failed check asks the keyring whether anything is still
      // connected, and the keyring is slow to answer.
      final Completer<void> keyring = Completer<void>();
      store.readGate = keyring;
      failing.completeError(const SocketException('offline'));
      await _waitUntil(() => store.heldReads >= 1);

      store.readGate = null;
      await controller.disconnect();
      keyring.complete();
      await refresh;

      expect(await store.read(), isNull);
      expect(_access(container), GitHubSponsorAccess.signedOut);
      expect(_entitlement(container), SupporterEntitlement.locked);
    });

    test('locks before secure storage finishes clearing', () async {
      final _ControllableGitHubSponsorTokenStore store =
          _ControllableGitHubSponsorTokenStore('saved-token');
      final ProviderContainer container = createContainer(
        store: store,
        client: _FakeGitHubSponsorClient(active: true),
      );
      await container.read(githubSponsorControllerProvider.future);
      expect(_entitlement(container), SupporterEntitlement.unlocked);

      final Completer<void> clearing = Completer<void>();
      store.clearGate = clearing;
      final Future<void> disconnecting =
          container.read(githubSponsorControllerProvider.notifier).disconnect();

      expect(_entitlement(container), SupporterEntitlement.locked);
      clearing.complete();
      await disconnecting;
      expect(_access(container), GitHubSponsorAccess.signedOut);
      expect(await store.read(), isNull);
    });

    test('cannot erase the token of a sign-in made while clearing', () async {
      // Disconnect locks at once and offers Connect GitHub again before the
      // keyring has finished removing the old token. A sign-in completed in
      // that window must not have its new token erased by the older clear.
      final _ControllableGitHubSponsorTokenStore store =
          _ControllableGitHubSponsorTokenStore('old-token');
      final ProviderContainer container = createContainer(
        store: store,
        client: _FakeGitHubSponsorClient(active: true),
      );
      await container.read(githubSponsorControllerProvider.future);
      final GitHubSponsorController controller =
          container.read(githubSponsorControllerProvider.notifier);

      final Completer<void> clearing = Completer<void>();
      store.clearGate = clearing;
      final Future<void> disconnecting = controller.disconnect();
      final Future<GitHubSponsorStatus> signingIn = controller
          .completeAuthorization(await controller.beginAuthorization());
      await _flushAsyncWork();

      clearing.complete();
      await disconnecting;
      final GitHubSponsorStatus status = await signingIn;

      expect(status.access, GitHubSponsorAccess.active);
      expect(await store.read(), 'new-token');
      expect(_entitlement(container), SupporterEntitlement.unlocked);
    });

    test('that cannot clear secure storage stays locked and connected',
        () async {
      final _ControllableGitHubSponsorTokenStore store =
          _ControllableGitHubSponsorTokenStore('saved-token');
      final ProviderContainer container = createContainer(
        store: store,
        client: _FakeGitHubSponsorClient(active: true),
      );
      await container.read(githubSponsorControllerProvider.future);

      store.failClears = true;
      await container
          .read(githubSponsorControllerProvider.notifier)
          .disconnect();

      final GitHubSponsorStatus? status =
          container.read(githubSponsorControllerProvider).valueOrNull;
      expect(status?.access, GitHubSponsorAccess.error);
      expect(status?.message, isNotNull);
      expect(status?.connected, isTrue);
      expect(_entitlement(container), SupporterEntitlement.locked);
    });
  });
}

GitHubSponsorAccess? _access(ProviderContainer container) =>
    container.read(githubSponsorControllerProvider).valueOrNull?.access;

SupporterEntitlement _entitlement(ProviderContainer container) =>
    container.read(supporterEntitlementProvider);

/// Lets every already-completed future run its continuation.
Future<void> _flushAsyncWork() => Future<void>.delayed(Duration.zero);

Future<void> _waitUntil(bool Function() condition) async {
  for (int attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition was not reached before the test timeout.');
}

class _ControllableGitHubSponsorTokenStore implements GitHubSponsorTokenStore {
  _ControllableGitHubSponsorTokenStore(this._token);

  String? _token;
  bool failReads = false;
  bool failClears = false;

  /// Holds every read until completed, like a keyring that is slow to answer.
  Completer<void>? readGate;
  int heldReads = 0;

  /// Holds clear() until completed.
  Completer<void>? clearGate;

  @override
  Future<String?> read() async {
    final Completer<void>? gate = readGate;
    if (gate != null) {
      heldReads++;
      await gate.future;
    }
    if (failReads) {
      throw const FileSystemException('secure storage unavailable');
    }
    return _token;
  }

  @override
  Future<void> write(String accessToken) async {
    _token = accessToken;
  }

  @override
  Future<void> clear() async {
    await clearGate?.future;
    if (failClears) {
      throw const FileSystemException('secure storage unavailable');
    }
    _token = null;
  }
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
  int pollCalls = 0;
  Completer<String>? nextAccessToken;

  /// What the controller handed the last poll to say it was cancelled.
  bool Function()? pollCancelled;

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
    GitHubDeviceAuthorization authorization, {
    bool Function()? isCancelled,
  }) async {
    pollCalls++;
    pollCancelled = isCancelled;
    final Completer<String>? delayed = nextAccessToken;
    if (delayed != null) {
      nextAccessToken = null;
      return delayed.future;
    }
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
