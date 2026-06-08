import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

void main() {
  group('LocalScanReport', () {
    test('a completed scan carries its counts and no error', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 12,
        audioCandidates: 9,
        skippedUnsupported: 3,
        readFailures: 0,
      );

      expect(report.folderSelected, isTrue);
      expect(report.isContentUri, isTrue);
      expect(report.filesVisited, 12);
      expect(report.audioCandidates, 9);
      expect(report.skippedUnsupported, 3);
      expect(report.readFailures, 0);
      expect(report.error, isNull);
      expect(report.hadError, isFalse);
    });

    test('the failure factory zeroes the counts and records the kind', () {
      const report = LocalScanReport.failure(
        folderSelected: true,
        isContentUri: true,
        error: LocalScanError.safTraversal,
      );

      expect(report.error, LocalScanError.safTraversal);
      expect(report.hadError, isTrue);
      expect(report.filesVisited, 0);
      expect(report.audioCandidates, 0);
      expect(report.skippedUnsupported, 0);
      expect(report.readFailures, 0);
    });

    test('carries folders-visited, imported, and recursive when given', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 12,
        foldersVisited: 4,
        audioCandidates: 9,
        importedTracks: 8,
        skippedUnsupported: 3,
        readFailures: 0,
        recursive: true,
      );

      expect(report.foldersVisited, 4);
      expect(report.importedTracks, 8);
      expect(report.recursive, isTrue);
    });

    test('defaults folders/imported to 0 and recursive to true', () {
      const report = LocalScanReport(
        folderSelected: true,
        isContentUri: false,
        filesVisited: 1,
        audioCandidates: 1,
        skippedUnsupported: 0,
        readFailures: 0,
      );

      expect(report.foldersVisited, 0);
      expect(report.importedTracks, 0);
      expect(report.recursive, isTrue);
    });

    test('a zero-count completed scan is distinct from a failure', () {
      const empty = LocalScanReport(
        folderSelected: true,
        isContentUri: true,
        filesVisited: 0,
        audioCandidates: 0,
        skippedUnsupported: 0,
        readFailures: 0,
      );

      // An empty folder completed without error — not the same as a failure.
      expect(empty.hadError, isFalse);
    });
  });
}
