import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/about/app_info_report.dart';

void main() {
  group('AppInfoReport.build', () {
    test('opens with the recognisable header line', () {
      final String text = AppInfoReport.build(linthraVersion: '0.1.5');

      expect(text, startsWith('Linthra app info\n'));
    });

    test('fills in the Linthra version from the supplied value', () {
      final String text = AppInfoReport.build(linthraVersion: '1.2.3');

      expect(text, contains('Linthra version: 1.2.3'));
    });

    test('fills in the Android version when one is known', () {
      final String text = AppInfoReport.build(
        linthraVersion: '0.1.5',
        androidVersion: 'Android 14 (API 34)',
      );

      expect(text, contains('Android version: Android 14 (API 34)'));
    });

    test('leaves the Android version a blank prompt when unknown', () {
      final String text = AppInfoReport.build(linthraVersion: '0.1.5');

      // The label is present as a fill-in, with no trailing value or space.
      expect(text, contains('\nAndroid version:\n'));
    });

    test(
      'leaves build number, device model, and install source as blank prompts '
      '(no dependency-free source for them)',
      () {
        final String text = AppInfoReport.build(linthraVersion: '0.1.5');

        expect(text, contains('\nBuild number:\n'));
        expect(text, contains('\nDevice model:\n'));
        expect(text, contains('\nInstall source:\n'));
      },
    );

    test('lists the music sources for the tester to pick from', () {
      final String text = AppInfoReport.build(linthraVersion: '0.1.5');

      expect(
        text,
        contains('Music source used: Local / Jellyfin / Navidrome / Subsonic'),
      );
    });

    test('ends with a blank Issue summary prompt on its own line', () {
      final String text = AppInfoReport.build(linthraVersion: '0.1.5');

      expect(text, endsWith('Issue summary:\n'));
    });

    test('keeps the field order matching the suggested template', () {
      final String text = AppInfoReport.build(
        linthraVersion: '0.1.5',
        androidVersion: 'Android 14 (API 34)',
      );

      const List<String> expected = <String>[
        'Linthra app info',
        '',
        'Linthra version: 0.1.5',
        'Build number:',
        'Android version: Android 14 (API 34)',
        'Device model:',
        'Install source:',
        'Music source used: Local / Jellyfin / Navidrome / Subsonic',
        'Issue summary:',
      ];
      expect(text, '${expected.join('\n')}\n');
    });

    test('carries no server URL, credential, or username', () {
      final String text = AppInfoReport.build(
        linthraVersion: '0.1.5',
        androidVersion: 'Android 14 (API 34)',
      );

      expect(text, isNot(contains('://')));
      expect(text, isNot(contains('http')));
      expect(text, isNot(contains('@')));
      expect(text.toLowerCase(), isNot(contains('token')));
      expect(text.toLowerCase(), isNot(contains('password')));
    });
  });
}
