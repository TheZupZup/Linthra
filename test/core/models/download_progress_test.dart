import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/download_progress.dart';

void main() {
  group('DownloadProgress', () {
    test('computes fraction and percent when the total is known', () {
      const progress = DownloadProgress(
        trackId: 't1',
        receivedBytes: 3,
        totalBytes: 4,
      );

      expect(progress.fraction, 0.75);
      expect(progress.percent, 75);
    });

    test('is indeterminate when the total is unknown', () {
      const progress = DownloadProgress(trackId: 't1', receivedBytes: 10);

      expect(progress.fraction, isNull);
      expect(progress.percent, isNull);
    });

    test('clamps a fraction that would exceed 1.0', () {
      const progress = DownloadProgress(
        trackId: 't1',
        receivedBytes: 9,
        totalBytes: 4,
      );

      expect(progress.fraction, 1.0);
      expect(progress.percent, 100);
    });

    test('treats a non-positive total as indeterminate', () {
      const progress = DownloadProgress(
        trackId: 't1',
        receivedBytes: 1,
        totalBytes: 0,
      );

      expect(progress.fraction, isNull);
    });

    test('has value equality by id and byte counts', () {
      const a = DownloadProgress(trackId: 't', receivedBytes: 1, totalBytes: 2);
      const b = DownloadProgress(trackId: 't', receivedBytes: 1, totalBytes: 2);
      const c = DownloadProgress(trackId: 't', receivedBytes: 2, totalBytes: 2);

      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
