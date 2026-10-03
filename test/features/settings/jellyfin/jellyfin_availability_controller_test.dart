import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/lifecycle/app_visibility.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/connectivity_service.dart';
import 'package:linthra/core/services/reachability.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/source_availability.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_jellyfin_session_store.dart';
import 'package:linthra/data/repositories/jellyfin_session_store_provider.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_availability_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_controller.dart';
import 'package:linthra/features/settings/jellyfin/jellyfin_settings_providers.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_client.dart';

const JellyfinSession _session = JellyfinSession(
  baseUrl: 'http://192.168.22.1:8096',
  userId: 'user-1',
  accessToken: 'tok',
  deviceId: 'device-1',
  userName: 'alice',
);

/// A client whose session probe is held open until the test releases it, so the
/// `checking` window can be observed rather than raced.
class _GatedJellyfinClient extends FakeJellyfinClient {
  _GatedJellyfinClient();

  Completer<void>? gate;

  @override
  Future<void> verifySession(JellyfinSession session) async {
    final Completer<void>? held = gate;
    if (held != null) await held.future;
    return super.verifySession(session);
  }
}

/// A device whose connection changes are reported as [changes] delivers them.
class _Network implements ConnectivityService {
  final StreamController<NetworkStatus> changes =
      StreamController<NetworkStatus>.broadcast();

  @override
  Stream<NetworkStatus> get statusStream => changes.stream;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

ProviderContainer _container({
  JellyfinSession? saved,
  required FakeJellyfinClient client,
  Duration? poll,
  ConnectivityService? network,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      jellyfinSessionStoreProvider.overrideWithValue(
        InMemoryJellyfinSessionStore(initialSession: saved),
      ),
      jellyfinClientProvider.overrideWithValue(client),
      jellyfinAvailabilityPollIntervalProvider.overrideWithValue(poll),
      if (network != null) ...<Override>[
        connectivityServiceProvider.overrideWithValue(network),
        // A host that reports connection changes (Android, or Linux's
        // network monitor portal).
        hostPlatformProvider.overrideWithValue(HostPlatform.android),
      ],
    ],
  );
  addTearDown(container.dispose);
  container.listen(jellyfinAvailabilityProvider, (_, __) {});
  return container;
}

Future<void> _settle() async {
  for (int i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('reports notConfigured with no saved session, and never probes',
      () async {
    final client = FakeJellyfinClient();
    final container = _container(client: client);
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.notConfigured);
    expect(client.verifyCount, 0,
        reason: 'nothing configured means nothing to reach');
  });

  test('shows "checking" while the first probe is in flight, hiding nothing',
      () async {
    final client = _GatedJellyfinClient()..gate = Completer<void>();
    final container = _container(saved: _session, client: client);
    await _settle();

    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.checking);
    // A library must not blink out while we are still asking.
    expect(container.read(jellyfinAvailabilityProvider).hidesTracks, isFalse);

    client.gate!.complete();
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);
  });

  test('probes a restored session at startup and records the outcome',
      () async {
    final client =
        FakeJellyfinClient(verifyError: JellyfinException.notReachable());
    final container = _container(saved: _session, client: client);
    await _settle();

    expect(client.verifyCount, 1);
    final state = container.read(jellyfinAvailabilityProvider);
    expect(state.status, SourceAvailability.unreachable);
    expect(state.lastCheckedAt, isNotNull);
    expect(state.hidesTracks, isTrue);
  });

  test('an unwrapped transport fault is never reported as available', () async {
    final client = _ThrowingClient();
    final container = _container(saved: _session, client: client);
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.unreachable);
  });

  test('noteReachability is ignored while nothing is configured', () async {
    final client = FakeJellyfinClient();
    final container = _container(client: client);
    await _settle();

    container
        .read(jellyfinAvailabilityProvider.notifier)
        .noteReachability(ReachabilityStatus.serverUnreachable);

    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.notConfigured);
  });

  test('a stale in-flight probe cannot overwrite a newer answer', () async {
    final client = _GatedJellyfinClient()
      ..gate = Completer<void>()
      ..verifyError = JellyfinException.notReachable();
    final container = _container(saved: _session, client: client);
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.checking);

    // The playback path learns the server is fine while the slow probe is still
    // hanging; the probe's later, stale "unreachable" must not win.
    container
        .read(jellyfinAvailabilityProvider.notifier)
        .noteReachability(ReachabilityStatus.reachable);
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);

    client.gate!.complete();
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);
  });

  test('signing out returns to notConfigured without a probe', () async {
    final client = FakeJellyfinClient();
    final container = _container(saved: _session, client: client);
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);

    await container.read(jellyfinSettingsControllerProvider.notifier).clear();
    await _settle();

    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.notConfigured);
  });

  test('the background poll re-probes a configured server', () async {
    final client =
        FakeJellyfinClient(verifyError: JellyfinException.notReachable());
    final container = _container(
      saved: _session,
      client: client,
      // The production override turns polling on; here it is compressed so the
      // recovery can be observed without a 45 s wait.
      poll: const Duration(milliseconds: 20),
    );
    await _settle();
    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.unreachable);

    // Back on the network: the poll picks it up with no user action at all.
    client.verifyError = null;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _settle();

    expect(container.read(jellyfinAvailabilityProvider).status,
        SourceAvailability.available);
    expect(client.verifyCount, greaterThan(1));
  });

  group('a connection that comes back', () {
    // The poll is off here (as between two 45 s polls), so only the network
    // change itself can bring the library back.
    test('re-probes a server it found unreachable', () async {
      final _Network network = _Network();
      addTearDown(network.changes.close);
      final client =
          FakeJellyfinClient(verifyError: JellyfinException.notReachable());
      final container =
          _container(saved: _session, client: client, network: network);
      await _settle();
      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.unreachable);

      // Wi-Fi rejoined (or the laptop woke up and its network came back),
      // and the server answers again.
      client.verifyError = null;
      network.changes.add(NetworkStatus.wifi);
      await _settle();

      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available,
          reason: 'the library stays hidden until the next poll');
    });

    test('going offline, or a change while off screen, probes nothing',
        () async {
      final _Network network = _Network();
      addTearDown(network.changes.close);
      final client = FakeJellyfinClient();
      final container =
          _container(saved: _session, client: client, network: network);
      await _settle();
      final int probes = client.verifyCount;

      network.changes.add(NetworkStatus.offline);
      await _settle();
      container.read(appVisibilityProvider.notifier).onHidden();
      await _settle();
      network.changes.add(NetworkStatus.wifi);
      await _settle();

      expect(client.verifyCount, probes);
    });
  });

  group('the poll follows app visibility (battery)', () {
    test('stops while the app is off screen, without probing on the way out',
        () async {
      final client = FakeJellyfinClient();
      final container = _container(
        saved: _session,
        client: client,
        poll: const Duration(milliseconds: 20),
      );
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();
      final int whileVisible = client.verifyCount;
      expect(whileVisible, greaterThan(1), reason: 'polling while on screen');

      // Screen off: playback keeps this isolate alive, so an ungated timer
      // would keep probing the server for the whole session.
      container.read(appVisibilityProvider.notifier).onHidden();
      await _settle();
      expect(client.verifyCount, whileVisible,
          reason: 'going off screen must not itself probe');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();
      expect(client.verifyCount, whileVisible,
          reason: 'no background probes while the UI is hidden');

      // And nothing was hidden by standing down: the last answer still stands.
      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);
    });

    test('resumes polling when the app comes back', () async {
      final client = FakeJellyfinClient();
      final container = _container(
        saved: _session,
        client: client,
        poll: const Duration(milliseconds: 20),
      );
      await _settle();
      container.read(appVisibilityProvider.notifier).onHidden();
      await _settle();
      final int whileHidden = client.verifyCount;

      container.read(appVisibilityProvider.notifier).onShown();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();
      expect(client.verifyCount, greaterThan(whileHidden));
    });

    test('a visibility flip never blinks the library back to checking',
        () async {
      final client = FakeJellyfinClient();
      final container = _container(saved: _session, client: client);
      await _settle();
      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);

      container.read(appVisibilityProvider.notifier).onHidden();
      container.read(appVisibilityProvider.notifier).onShown();
      await _settle();

      expect(container.read(jellyfinAvailabilityProvider).status,
          SourceAvailability.available);
    });
  });
}

/// A client whose probe throws something the Jellyfin layer never wrapped.
class _ThrowingClient extends FakeJellyfinClient {
  @override
  Future<void> verifySession(JellyfinSession session) async {
    throw StateError('socket exploded');
  }
}
