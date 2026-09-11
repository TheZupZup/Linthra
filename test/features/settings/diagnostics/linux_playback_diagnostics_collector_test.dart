import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/models/audio_output_device.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/audio_output_device_service.dart';
import 'package:linthra/core/services/linux_mpv_probe.dart';
import 'package:linthra/core/services/playback_controller.dart';
import 'package:linthra/data/repositories/audio_output_device_service_provider.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_preferences.dart';
import 'package:linthra/data/repositories/playback_preferences_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/diagnostics/linux_playback_diagnostics_collector.dart';
import 'package:linthra/features/settings/diagnostics/linux_playback_diagnostics_section.dart';
import 'package:linthra/features/settings/playback/audio_output_controller.dart';

import '../../player/fake_playback_controller.dart';

/// A libmpv that answers whatever the test says, including not at all.
class _FakeProbe implements LinuxMpvProbe {
  _FakeProbe({
    this.availability = LibmpvAvailability.available,
    this.version,
  });

  final LibmpvAvailability availability;
  final String? version;

  @override
  Future<LinuxMpvProbeResult> probe() async =>
      (availability: availability, version: version);
}

/// A stand-in for libmpv's device list.
class _FakeOutputService implements AudioOutputDeviceService {
  _FakeOutputService({this.isSupported = true, this.available = const []});

  @override
  final bool isSupported;

  final List<AudioOutputDevice> available;

  @override
  Future<List<AudioOutputDevice>> devices() async => available;

  @override
  Future<bool> select(AudioOutputDevice device) async => true;
}

const AudioOutputDevice _usbDac = AudioOutputDevice(
  id: 'pipewire/alsa_output.usb-Topping_D10-00.analog-stereo',
  label: 'Topping D10',
);

/// Builds a container for the collector.
///
/// The playback controller is always overridden: reading the real one on a
/// Linux host would construct `LinuxPlaybackController`, which loads libmpv —
/// exactly the native dependency these tests exist to stay free of.
ProviderContainer _containerFor({
  HostPlatform host = HostPlatform.linux,
  LinuxMpvProbe? probe,
  AudioOutputDeviceService? outputs,
  Map<String, String> mpvProperties = const <String, String>{},
  PlaybackController? controller,
}) {
  final PlaybackController playback = controller ?? _fakeController();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      hostPlatformProvider.overrideWithValue(host),
      linuxMpvProbeProvider.overrideWithValue(probe ?? _FakeProbe()),
      audioOutputDeviceServiceProvider
          .overrideWithValue(outputs ?? _FakeOutputService()),
      linuxMpvPropertiesProvider.overrideWithValue(() => mpvProperties),
      playbackPreferencesProvider
          .overrideWithValue(InMemoryPlaybackPreferences()),
      playbackControllerProvider.overrideWithValue(playback),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

FakePlaybackController _fakeController() {
  final FakePlaybackController controller = FakePlaybackController();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  setUp(SafeEventLog.instance.clear);
  tearDown(SafeEventLog.instance.clear);

  group('what the collector gathers', () {
    test('a Linux host reports the media_kit/libmpv stack', () async {
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container = _containerFor(
        probe: _FakeProbe(version: 'mpv 0.38.0'),
        mpvProperties: const <String, String>{'cache-on-disk': 'no'},
        controller: controller,
      );

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.backend, LinuxPlaybackBackend.mediaKitLibmpv);
      expect(data.libmpv, LibmpvAvailability.available);
      expect(data.libmpvVersion, 'mpv 0.38.0');
      expect(data.mpvProperties['cache-on-disk'], 'no');
      expect(data.outputSelectionSupported, isTrue);
      expect(data.suspendRecoveryEnabled, isTrue);
      expect(data.playbackStatus, 'idle');
    });

    test('nothing playing means "not probed", not "unavailable"', () async {
      final ProviderContainer container = _containerFor(
          probe: _FakeProbe(availability: LibmpvAvailability.notProbed));

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.libmpv, LibmpvAvailability.notProbed);
      expect(data.libmpvVersion, isNull);
    });

    test('a backend that will not answer reads as unavailable, not available',
        () async {
      // The failure the report exists to show. A wedged libmpv that a live
      // player cannot query must never read as a healthy backend.
      final ProviderContainer container = _containerFor(
        probe: _FakeProbe(availability: LibmpvAvailability.unavailable),
      );

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.libmpv, LibmpvAvailability.unavailable);
      expect(
        LinuxPlaybackDiagnostics.report(data),
        contains('libmpv: unavailable'),
      );
    });

    test('an enumeration that failed is not reported as zero outputs',
        () async {
      // A successful enumeration always carries the system default, so an
      // empty list means the backend did not answer (#402 reports it that
      // way) — never "this machine has no outputs".
      final ProviderContainer container = _containerFor();
      await container.read(audioOutputControllerProvider.notifier).refresh();

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.outputEnumerationFailed, isTrue);
      expect(data.outputsEnumerated, isNull);
      final String report = LinuxPlaybackDiagnostics.report(data);
      expect(report, contains('Outputs found: unknown'));
      expect(report, isNot(contains('Outputs found: 0')));
    });

    test('a real enumeration still reports its count', () async {
      final ProviderContainer container = _containerFor(
        outputs: _FakeOutputService(
          available: const <AudioOutputDevice>[
            AudioOutputDevice.systemDefault,
            _usbDac,
          ],
        ),
      );
      await container.read(audioOutputControllerProvider.notifier).refresh();

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.outputEnumerationFailed, isFalse);
      expect(data.outputsEnumerated, 2);
      expect(
        LinuxPlaybackDiagnostics.report(data),
        contains('Outputs found: 2'),
      );
    });

    test('the selected output is reduced to a driver and a kind', () async {
      final ProviderContainer container = _containerFor(
        outputs: _FakeOutputService(
          available: const <AudioOutputDevice>[
            AudioOutputDevice.systemDefault,
            _usbDac,
          ],
        ),
      );
      await container
          .read(audioOutputControllerProvider.notifier)
          .select(_usbDac);

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.selectedOutputDriver, AudioOutputDriver.pipewire);
      expect(data.selectedOutputKind, AudioOutputKind.usb);
      expect(data.selectedOutputIsSystemDefault, isFalse);

      // The device name itself never reaches the report.
      final String report = LinuxPlaybackDiagnostics.report(data);
      expect(report, isNot(contains('Topping')));
      expect(report, isNot(contains('alsa_output')));
      expect(report, contains('usb, via pipewire'));
    });

    test('a backend that cannot route outputs is reported as unsupported',
        () async {
      final ProviderContainer container = _containerFor(
        outputs: _FakeOutputService(isSupported: false),
      );

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.outputSelectionSupported, isFalse);
      expect(data.outputsEnumerated, isNull);
      expect(
        LinuxPlaybackDiagnostics.report(data),
        contains('Output selection: unsupported'),
      );
    });

    test('a host with no on-device engine is reported honestly', () async {
      final ProviderContainer container =
          _containerFor(host: HostPlatform.android);

      final LinuxPlaybackDiagnosticsData data = await container
          .read(linuxPlaybackDiagnosticsCollectorProvider)
          .collect();

      expect(data.backend, LinuxPlaybackBackend.none);
      expect(data.libmpv, LibmpvAvailability.notProbed);
      expect(data.outputSelectionSupported, isFalse);
    });
  });

  group('recent failures come from the safe event log', () {
    test('playback errors are aggregated by kind, most frequent first', () {
      final SafeEventLog log = SafeEventLog()
        ..record('error', 'load')
        ..record('lifecycle', 'paused')
        ..record('error', 'resolution')
        ..record('error', 'load')
        ..record('error', 'load');

      final List<LinuxPlaybackFailure> failures =
          LinuxPlaybackDiagnosticsCollector.recentFailures(log);

      expect(failures, <LinuxPlaybackFailure>[
        const LinuxPlaybackFailure(kind: 'load', count: 3),
        const LinuxPlaybackFailure(kind: 'resolution', count: 1),
      ]);
    });

    test('non-error breadcrumbs are not playback failures', () {
      final SafeEventLog log = SafeEventLog()
        ..record('lifecycle', 'resumed')
        ..record('output', 'local');
      expect(
        LinuxPlaybackDiagnosticsCollector.recentFailures(log),
        isEmpty,
      );
    });

    test('the log itself is bounded, so the report cannot grow', () {
      final SafeEventLog log = SafeEventLog(capacity: 5);
      for (int i = 0; i < 100; i++) {
        log.record('error', 'kind$i');
      }
      expect(
        LinuxPlaybackDiagnosticsCollector.recentFailures(log).length,
        lessThanOrEqualTo(5),
      );
    });
  });

  group('the card', () {
    Future<void> pump(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LinuxPlaybackDiagnosticsSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the actions stack rather than cramp at the 420px minimum',
        (tester) async {
      // 420x600 is the Linux window's enforced minimum (linux/runner). Side by
      // side at 2x text each button would get ~170px and wrap its label onto
      // four lines.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _containerFor(),
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: LinuxPlaybackDiagnosticsSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Size copy = tester.getSize(
        find.widgetWithText(FilledButton, 'Copy playback report'),
      );
      final Size show =
          tester.getSize(find.widgetWithText(OutlinedButton, 'Show report'));
      // Stacked: each button spans the card rather than sharing a row.
      expect(copy.width, greaterThan(300));
      expect(show.width, greaterThan(300));
      expect(
        tester
            .getTopLeft(find.widgetWithText(OutlinedButton, 'Show report'))
            .dy,
        greaterThan(
          tester
                  .getBottomLeft(
                    find.widgetWithText(FilledButton, 'Copy playback report'),
                  )
                  .dy -
              1,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide card still puts the actions side by side',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _containerFor(),
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LinuxPlaybackDiagnosticsSection(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .getTopLeft(find.widgetWithText(OutlinedButton, 'Show report'))
            .dy,
        tester
            .getTopLeft(
              find.widgetWithText(FilledButton, 'Copy playback report'),
            )
            .dy,
      );
    });

    testWidgets('renders nothing off Linux', (tester) async {
      await pump(tester, _containerFor(host: HostPlatform.android));
      expect(find.text('Linux playback'), findsNothing);
    });

    testWidgets('shows a report and copies it', (tester) async {
      final List<MethodCall> clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') clipboard.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pump(
        tester,
        _containerFor(probe: _FakeProbe(version: 'mpv 0.38.0')),
      );

      expect(find.text('Linux playback'), findsOneWidget);
      await tester.tap(find.text('Show report'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Linthra Linux playback diagnostics'),
          findsOneWidget);

      await tester.tap(find.text('Copy playback report'));
      await tester.pumpAndSettle();

      expect(clipboard, hasLength(1));
      final String copied = (clipboard.single.arguments
          as Map<Object?, Object?>)['text']! as String;
      expect(copied, contains('Backend: media_kit / libmpv'));
      expect(copied, contains('libmpv version: mpv 0.38.0'));
      for (final String marker in <String>[
        'api_key',
        'authorization',
        'bearer',
        'http://',
        'https://',
      ]) {
        expect(copied.toLowerCase(), isNot(contains(marker)));
      }
    });
  });
}
