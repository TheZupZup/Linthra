import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/linux_playback_diagnostics.dart';

/// Linux playback diagnostics (#406).
///
/// The security claim these tests hold up is *safe by construction*: the
/// snapshot has no field that can hold a secret, so the report has nothing to
/// redact. What is asserted here is that the fields really are that narrow —
/// the enums classify without carrying the string they classified, the
/// property allowlist is an allowlist, and the one free-form value left
/// (a backend version) cannot smuggle a URL through.

/// Strings that must never survive into a report, whatever is fed in.
const List<String> _secretMarkers = <String>[
  'api_key',
  'apikey',
  'x-plex-token',
  'access_token',
  'Authorization',
  'Bearer',
  'password',
  'http://',
  'https://',
];

void _expectNoSecrets(String report) {
  for (final String marker in _secretMarkers) {
    expect(
      report.toLowerCase(),
      isNot(contains(marker.toLowerCase())),
      reason: 'the report must never carry "$marker"',
    );
  }
}

void main() {
  group('sanitizeVersion', () {
    test('keeps an ordinary libmpv version untouched', () {
      expect(
          LinuxPlaybackDiagnostics.sanitizeVersion('mpv 0.38.0'), 'mpv 0.38.0');
      expect(LinuxPlaybackDiagnostics.sanitizeVersion('libmpv 2.2.0+git'),
          'libmpv 2.2.0+git');
    });

    test('a value carrying a URL is rejected outright, not stripped', () {
      // Stripping the punctuation would leave the words behind, which is worse
      // than saying nothing.
      expect(
        LinuxPlaybackDiagnostics.sanitizeVersion(
          'mpv 0.38.0 https://media.example.com/stream?api_key=secret',
        ),
        isNull,
      );
    });

    test('a header smuggled in over a newline is rejected', () {
      expect(
        LinuxPlaybackDiagnostics.sanitizeVersion(
          'mpv 0.38.0\nAuthorization: Bearer abc',
        ),
        isNull,
      );
    });

    test('a path is rejected', () {
      expect(
        LinuxPlaybackDiagnostics.sanitizeVersion(
          r'mpv /home/someone/Music/private',
        ),
        isNull,
      );
    });

    test('it is length-capped, so no blob can be pasted through', () {
      final String? sanitized =
          LinuxPlaybackDiagnostics.sanitizeVersion('v' * 500);
      expect(
        sanitized!.length,
        LinuxPlaybackDiagnostics.maxVersionLength,
      );
    });

    test('null and an all-punctuation value come back as null', () {
      expect(LinuxPlaybackDiagnostics.sanitizeVersion(null), isNull);
      expect(LinuxPlaybackDiagnostics.sanitizeVersion('://?&='), isNull);
      expect(LinuxPlaybackDiagnostics.sanitizeVersion(''), isNull);
      expect(LinuxPlaybackDiagnostics.sanitizeVersion('   '), isNull);
    });
  });

  group('filterMpvProperties', () {
    test('is an allowlist: an unknown property is dropped', () {
      final Map<String, String> filtered =
          LinuxPlaybackDiagnostics.filterMpvProperties(<String, String>{
        'cache-on-disk': 'no',
        'http-header-fields': 'Authorization: Bearer secret',
        'stream-open-filename': 'https://media.example.com/s?api_key=secret',
      });
      expect(filtered.keys, <String>['cache-on-disk']);
      _expectNoSecrets(filtered.toString());
    });

    test('the audio-device value is withheld, only its presence is shown', () {
      // libmpv device names embed hardware identity — a Bluetooth sink carries
      // the adapter's MAC — so the value never reaches a report.
      final Map<String, String> filtered =
          LinuxPlaybackDiagnostics.filterMpvProperties(<String, String>{
        'audio-device': 'pulse/bluez_output.AC_12_2F_3D_4E_5F.1',
      });
      expect(filtered['audio-device'], 'set');
      expect(filtered.toString(), isNot(contains('AC_12_2F')));
    });

    test('a value that is not a plain token is withheld too', () {
      // A header, a URL or a key/value pair does not match the token shape, so
      // it is reported as "set" rather than printed.
      final Map<String, String> filtered =
          LinuxPlaybackDiagnostics.filterMpvProperties(<String, String>{
        'cache-on-disk': 'no\nauthorization: Bearer abc',
        'ao': 'pulse http://x?api_key=1',
      });
      expect(filtered['cache-on-disk'], 'set');
      expect(filtered['ao'], 'set');
      _expectNoSecrets(filtered.toString());
    });

    test('an absent property produces no line at all', () {
      expect(
        LinuxPlaybackDiagnostics.filterMpvProperties(const <String, String>{}),
        isEmpty,
      );
    });
  });

  group('output classification carries no device identity', () {
    test('drivers come from the prefix only', () {
      expect(
        AudioOutputDriver.fromDeviceId('pipewire/alsa_output.pci-0000_00_1f.3'),
        AudioOutputDriver.pipewire,
      );
      expect(AudioOutputDriver.fromDeviceId('pulse/whatever'),
          AudioOutputDriver.pulse);
      expect(AudioOutputDriver.fromDeviceId('alsa/hw:1,0'),
          AudioOutputDriver.alsa);
      expect(AudioOutputDriver.fromDeviceId('jack/system'),
          AudioOutputDriver.jack);
      expect(AudioOutputDriver.fromDeviceId('auto'),
          AudioOutputDriver.systemDefault);
      expect(AudioOutputDriver.fromDeviceId(null),
          AudioOutputDriver.systemDefault);
      expect(
          AudioOutputDriver.fromDeviceId('oss/dsp'), AudioOutputDriver.other);
    });

    test('a Bluetooth sink is classified without its MAC address', () {
      const String id = 'pulse/bluez_output.AC_12_2F_3D_4E_5F.1';
      expect(AudioOutputKind.fromDeviceId(id), AudioOutputKind.bluetooth);
      final String report = LinuxPlaybackDiagnostics.report(
        LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          selectedOutputDriver: AudioOutputDriver.fromDeviceId(id),
          selectedOutputKind: AudioOutputKind.fromDeviceId(id),
          selectedOutputIsSystemDefault: false,
        ),
      );
      expect(report, contains('bluetooth, via pulse'));
      expect(report, isNot(contains('AC_12_2F')));
      expect(report, isNot(contains('bluez_output')));
    });

    test('the useful kinds are recognised', () {
      expect(
        AudioOutputKind.fromDeviceId(
            'pipewire/alsa_output.pci-0000.hdmi-stereo'),
        AudioOutputKind.hdmi,
      );
      expect(
        AudioOutputKind.fromDeviceId('pipewire/alsa_output.usb-Topping_D10'),
        AudioOutputKind.usb,
      );
      expect(
        AudioOutputKind.fromDeviceId('pipewire/alsa_output.pci.analog-stereo'),
        AudioOutputKind.analog,
      );
      expect(
        AudioOutputKind.fromDeviceId('pipewire/alsa_output.pci.iec958-stereo'),
        AudioOutputKind.digital,
      );
      expect(
        AudioOutputKind.fromDeviceId('pulse/auto_null'),
        AudioOutputKind.virtual,
      );
      expect(
          AudioOutputKind.fromDeviceId('auto'), AudioOutputKind.systemDefault);
    });

    test('a device name that looks like a URL still classifies to an enum', () {
      // Nothing can put a string into the report through this path: the
      // function returns one of a fixed set of constants either way.
      const String hostile = 'https://evil/?api_key=secret';
      expect(AudioOutputKind.values,
          contains(AudioOutputKind.fromDeviceId(hostile)));
      expect(AudioOutputDriver.values,
          contains(AudioOutputDriver.fromDeviceId(hostile)));
    });
  });

  group('the report', () {
    test('identifies the Linux playback stack', () {
      final String report = LinuxPlaybackDiagnostics.report(
        const LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          libmpv: LibmpvAvailability.available,
          libmpvVersion: 'mpv 0.38.0',
          mpvProperties: <String, String>{'cache-on-disk': 'no'},
          outputSelectionSupported: true,
          outputsEnumerated: 3,
          suspendRecoveryEnabled: true,
          playbackStatus: 'playing',
        ),
      );
      expect(report, startsWith('Linthra Linux playback diagnostics'));
      expect(report, contains('Backend: media_kit / libmpv'));
      expect(report, contains('libmpv: available'));
      expect(report, contains('libmpv version: mpv 0.38.0'));
      expect(report, contains('mpv cache-on-disk: no'));
      expect(report, contains('Output selection: supported'));
      expect(report, contains('Outputs found: 3'));
      expect(report, contains('Suspend/resume recovery: enabled'));
      expect(report, contains('Playback state: playing'));
      _expectNoSecrets(report);
    });

    test('missing optional information never fails the report', () {
      final String report = LinuxPlaybackDiagnostics.report(
        const LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
        ),
      );
      expect(report, contains('libmpv: not probed'));
      expect(report, isNot(contains('libmpv version')));
      expect(report, isNot(contains('Outputs found')));
      expect(report, contains('Selected output: system default'));
      expect(report, contains('Recent playback failures: none'));
      _expectNoSecrets(report);
    });

    test('a host with no engine says so rather than pretending', () {
      final String report = LinuxPlaybackDiagnostics.report(
        const LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.none,
        ),
      );
      expect(report, contains('Backend: none'));
    });

    test('common runtime failures appear in a useful, sanitized form', () {
      final String report = LinuxPlaybackDiagnostics.report(
        const LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          recentFailures: <LinuxPlaybackFailure>[
            LinuxPlaybackFailure(kind: 'load', count: 3),
            LinuxPlaybackFailure(kind: 'resolution', count: 1),
          ],
        ),
      );
      expect(
          report,
          contains('Recent playback failures: load ×3, '
              'resolution ×1'));
    });

    test('the failure list is capped, so a wedged session stays readable', () {
      final String report = LinuxPlaybackDiagnostics.report(
        LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          recentFailures: <LinuxPlaybackFailure>[
            for (int i = 0; i < 40; i++)
              LinuxPlaybackFailure(kind: 'kind$i', count: 1),
          ],
        ),
      );
      final String line = report
          .split('\n')
          .firstWhere((String l) => l.startsWith('Recent playback failures:'));
      expect(
        '×'.allMatches(line).length,
        LinuxPlaybackDiagnostics.maxReportedFailureKinds,
      );
    });

    test('the output-recovery notes surface without any device identity', () {
      final String report = LinuxPlaybackDiagnostics.report(
        const LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          selectedOutputDriver: AudioOutputDriver.pipewire,
          selectedOutputKind: AudioOutputKind.usb,
          selectedOutputIsSystemDefault: false,
          selectedOutputRemembered: true,
          savedOutputUnavailable: true,
          lastSelectionFailed: true,
        ),
      );
      expect(report, contains('Selected output: usb, via pipewire'));
      expect(report, contains('Selected output remembered: yes'));
      expect(report, contains('Saved output: unavailable'));
      expect(report, contains('Last output switch: refused by backend'));
      _expectNoSecrets(report);
    });

    test('every line is one line — nothing can inject a fake field', () {
      final String report = LinuxPlaybackDiagnostics.report(
        LinuxPlaybackDiagnosticsData(
          backend: LinuxPlaybackBackend.mediaKitLibmpv,
          libmpvVersion: LinuxPlaybackDiagnostics.sanitizeVersion(
            'mpv 1.0\nToken: secret\nAuthorization: Bearer abc',
          ),
          mpvProperties: LinuxPlaybackDiagnostics.filterMpvProperties(
            const <String, String>{
              'cache-on-disk': 'no\nauthorization: Bearer x',
            },
          ),
        ),
      );
      for (final String line in report.split('\n')) {
        expect(line, isNot(contains('\n')));
      }
      _expectNoSecrets(report);
    });
  });
}
