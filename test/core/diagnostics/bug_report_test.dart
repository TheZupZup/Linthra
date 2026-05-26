import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/bug_report.dart';

void main() {
  const String diagnostics = 'Linthra diagnostics\n'
      'App version: 0.1.0-test\n'
      'Jellyfin host: music.example.com\n'
      'Last error: none';

  group('BugReport.markdown', () {
    test('lays out all sections with a fenced diagnostics block', () {
      final String report = BugReport.markdown(diagnostics: diagnostics);

      expect(report, contains('# Linthra bug report'));
      expect(report, contains('## Summary'));
      expect(report, contains('## What happened'));
      expect(report, contains('## Steps to reproduce'));
      expect(report, contains('## Expected behavior'));
      expect(report, contains('## Diagnostics'));
      expect(report, contains('```text\n$diagnostics\n```'));
    });

    test('fills blank fields with a placeholder and a steps scaffold', () {
      final String report = BugReport.markdown(diagnostics: diagnostics);

      expect(report, contains(BugReport.fieldPlaceholder));
      expect(report, contains(BugReport.stepsScaffold));
    });

    test('uses the provided field values when present', () {
      final String report = BugReport.markdown(
        summary: 'Crash on play',
        whatHappened: 'It crashed',
        steps: '1. open\n2. play',
        expected: 'It plays',
        diagnostics: diagnostics,
      );

      expect(report, contains('## Summary\nCrash on play'));
      expect(report, contains('## What happened\nIt crashed'));
      expect(report, contains('## Steps to reproduce\n1. open\n2. play'));
      expect(report, contains('## Expected behavior\nIt plays'));
      expect(report, isNot(contains(BugReport.fieldPlaceholder)));
    });

    test('appends a Recent app events section only when provided', () {
      final String without = BugReport.markdown(diagnostics: diagnostics);
      expect(without, isNot(contains('## Recent app events')));

      final String withEvents = BugReport.markdown(
        diagnostics: diagnostics,
        recentEvents: 'lifecycle: resumed\noutput: cast',
      );
      expect(withEvents, contains('## Recent app events'));
      expect(
        withEvents,
        contains('```text\nlifecycle: resumed\noutput: cast\n```'),
      );
    });

    test('treats blank recent events as absent', () {
      final String report = BugReport.markdown(
        diagnostics: diagnostics,
        recentEvents: '   ',
      );
      expect(report, isNot(contains('## Recent app events')));
    });

    test('embeds the diagnostics verbatim and adds nothing secret', () {
      final String report = BugReport.markdown(diagnostics: diagnostics);
      expect(report, isNot(contains('api_key')));
      expect(report.toLowerCase(), isNot(contains('password')));
    });
  });

  group('BugReport.newIssueUrl', () {
    test('targets the repo issues/new with a bug label and prefilled body', () {
      final Uri url = BugReport.newIssueUrl(
        body: 'Hello world\nLine two',
        title: 'My bug',
      );

      expect(url.scheme, 'https');
      expect(url.host, 'github.com');
      expect(url.path, '/thezupzup/linthra/issues/new');
      expect(url.queryParameters['labels'], 'bug');
      expect(url.queryParameters['title'], 'My bug');
      // The body round-trips through URL decoding intact.
      expect(url.queryParameters['body'], 'Hello world\nLine two');
    });

    test('omits the title when blank', () {
      final Uri url = BugReport.newIssueUrl(body: 'x');
      expect(url.queryParameters.containsKey('title'), isFalse);
    });
  });

  group('BugReport.issueTitle', () {
    test('uses the trimmed summary, or a default when blank', () {
      expect(BugReport.issueTitle('  Crash on play  '), 'Crash on play');
      expect(BugReport.issueTitle(''), 'Bug report');
      expect(BugReport.issueTitle('   '), 'Bug report');
    });

    test('truncates a very long summary', () {
      final String title = BugReport.issueTitle('x' * 100);
      expect(title.length, lessThanOrEqualTo(72));
      expect(title, endsWith('...'));
    });
  });
}
