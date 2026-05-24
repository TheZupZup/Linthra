import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cache_size.dart';

void main() {
  group('CacheSize', () {
    test('offers the expected presets and a sane default', () {
      expect(CacheSize.presets, <int>[
        1 * CacheSize.bytesPerGb,
        2 * CacheSize.bytesPerGb,
        4 * CacheSize.bytesPerGb,
        8 * CacheSize.bytesPerGb,
        16 * CacheSize.bytesPerGb,
      ]);
      expect(CacheSize.defaultLimit, 4 * CacheSize.bytesPerGb);
      expect(CacheSize.isPreset(CacheSize.defaultLimit), isTrue);
      expect(CacheSize.isPreset(CacheSize.defaultLimit + 1), isFalse);
    });

    test('gigabytes converts to bytes', () {
      expect(CacheSize.gigabytes(2), 2 * CacheSize.bytesPerGb);
      expect(CacheSize.gigabytes(1.5), (1.5 * CacheSize.bytesPerGb).round());
    });

    test('clamp keeps values within the supported range', () {
      expect(CacheSize.clamp(0), CacheSize.minLimit);
      expect(CacheSize.clamp(CacheSize.maxLimit + 1), CacheSize.maxLimit);
      expect(CacheSize.clamp(CacheSize.defaultLimit), CacheSize.defaultLimit);
    });

    group('formatBytes', () {
      test('formats bytes, KB, MB and GB', () {
        expect(CacheSize.formatBytes(0), '0 B');
        expect(CacheSize.formatBytes(512), '512 B');
        expect(CacheSize.formatBytes(CacheSize.bytesPerKb), '1 KB');
        expect(CacheSize.formatBytes(CacheSize.bytesPerMb), '1 MB');
        expect(CacheSize.formatBytes(512 * CacheSize.bytesPerMb), '512 MB');
        expect(CacheSize.formatBytes(4 * CacheSize.bytesPerGb), '4 GB');
      });

      test('shows one decimal for fractional sizes', () {
        expect(
          CacheSize.formatBytes((1.5 * CacheSize.bytesPerGb).round()),
          '1.5 GB',
        );
      });
    });
  });
}
