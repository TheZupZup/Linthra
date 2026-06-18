import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/about/bug_report_email.dart';

void main() {
  group('BugReportEmail.mailtoUri', () {
    test('addresses the support inbox with the bug-report subject', () {
      final Uri uri = BugReportEmail.mailtoUri();

      expect(uri.scheme, 'mailto');
      expect(uri.path, 'support@linthra.ca');
      // queryParameters round-trips the percent-encoding back to plain text.
      expect(uri.queryParameters['subject'], 'Linthra bug report');
    });

    test('prefills the fill-in body template', () {
      final String body = BugReportEmail.mailtoUri().queryParameters['body']!;

      expect(body, BugReportEmail.body);
      // The prompts a tester fills in are all present and in order.
      expect(body, contains('What happened:'));
      expect(body, contains('What I expected:'));
      expect(body, contains('Steps to reproduce:\n1.\n2.\n3.'));
      expect(body, contains('Device:'));
      expect(body, contains('Android version:'));
      expect(body, contains('Linthra version:'));
      expect(
        body,
        contains('Music source: Local / Jellyfin / Navidrome / Subsonic'),
      );
      expect(body, contains('Additional notes:'));
    });

    test('encodes spaces as %20, never as + (mail apps render + literally)',
        () {
      final Uri uri = BugReportEmail.mailtoUri();

      expect(uri.query, contains('subject=Linthra%20bug%20report'));
      expect(uri.query, isNot(contains('+')));
    });
  });
}
