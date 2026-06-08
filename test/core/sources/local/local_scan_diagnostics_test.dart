import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/sources/local/local_scan_diagnostics.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

void main() {
  setUp(() {
    LocalScanDiagnostics.reset();
    SafeEventLog.instance.clear();
  });

  tearDown(() {
    LocalScanDiagnostics.reset();
    SafeEventLog.instance.clear();
  });

  group('LocalScanDiagnostics', () {
    test('starts with no recorded scan', () {
      expect(LocalScanDiagnostics.last, isNull);
    });

    test('record stores the latest report', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 5,
        audioCandidates: 4,
        skippedUnsupported: 1,
        readFailures: 0,
      );

      LocalScanDiagnostics.record(report);

      expect(LocalScanDiagnostics.last, same(report));
    });

    test('record drops a breadcrumb into the shared event log', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 5,
        audioCandidates: 4,
        skippedUnsupported: 1,
        readFailures: 2,
      );

      LocalScanDiagnostics.record(report);

      expect(SafeEventLog.instance.lines, contains(startsWith('scan: ')));
    });
  });

  group('LocalScanDiagnostics.describe', () {
    test('summarizes a completed scan as structural counts only', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 10,
        audioCandidates: 7,
        skippedUnsupported: 3,
        readFailures: 1,
      );

      final summary = LocalScanDiagnostics.describe(report);

      expect(summary, contains('folder=selected'));
      expect(summary, contains('kind=saf'));
      expect(summary, contains('visited=10'));
      expect(summary, contains('audio=7'));
      expect(summary, contains('skipped=3'));
      expect(summary, contains('readFailures=1'));
      expect(summary, isNot(contains('error=')));
    });

    test('summarizes a failure with the error kind', () {
      const report = LocalScanReport.failure(
        folderSelected: true,
        isContentUri: false,
        error: LocalScanError.unexpected,
      );

      final summary = LocalScanDiagnostics.describe(report);

      expect(summary, contains('kind=path'));
      expect(summary, contains('error=unexpected'));
    });

    test('a summary carries no path, URI, or file name', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 1,
        audioCandidates: 1,
        skippedUnsupported: 0,
        readFailures: 0,
      );

      final summary = LocalScanDiagnostics.describe(report);

      expect(summary.toLowerCase(), isNot(contains('content://')));
      expect(summary, isNot(contains('/storage/')));
      expect(summary.toLowerCase(), isNot(contains('.mp3')));
    });
  });
}
