import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_server_capabilities.dart';

void main() {
  group('JellyfinServerVersion.tryParse', () {
    test('parses major.minor.patch', () {
      final JellyfinServerVersion? v =
          JellyfinServerVersion.tryParse('10.9.11');
      expect(v, isNotNull);
      expect(v!.major, 10);
      expect(v.minor, 9);
      expect(v.patch, 11);
      expect(v.toString(), '10.9.11');
    });

    test('defaults a missing patch to 0', () {
      final JellyfinServerVersion? v = JellyfinServerVersion.tryParse('10.8');
      expect(v, const JellyfinServerVersion(10, 8, 0));
    });

    test('ignores a build/suffix part', () {
      expect(
        JellyfinServerVersion.tryParse('10.10.3-rc1'),
        const JellyfinServerVersion(10, 10, 3),
      );
    });

    test('parses Jellyfin 12 release and pre-release strings', () {
      expect(JellyfinServerVersion.tryParse('12.0'),
          const JellyfinServerVersion(12, 0, 0));
      expect(JellyfinServerVersion.tryParse('12.0.0'),
          const JellyfinServerVersion(12, 0, 0));
      expect(JellyfinServerVersion.tryParse('12.0-rc'),
          const JellyfinServerVersion(12, 0, 0));
      expect(JellyfinServerVersion.tryParse('12.0.0-rc1'),
          const JellyfinServerVersion(12, 0, 0));
      expect(JellyfinServerVersion.tryParse('12.1.0'),
          const JellyfinServerVersion(12, 1, 0));
    });

    test('ignores a 4th version segment and a rich build suffix', () {
      expect(JellyfinServerVersion.tryParse('12.0.0.1'),
          const JellyfinServerVersion(12, 0, 0));
      expect(JellyfinServerVersion.tryParse('12.0.0-rc1+build.123'),
          const JellyfinServerVersion(12, 0, 0));
    });

    test('a bare major with no minor is not parsed (stays unknown)', () {
      // Standard Jellyfin always reports major.minor.patch; a lone "12" has no
      // recognizable minor, so it is treated as unparseable rather than guessed.
      expect(JellyfinServerVersion.tryParse('12'), isNull);
    });

    test('returns null for an unparseable string', () {
      expect(JellyfinServerVersion.tryParse('unknown'), isNull);
      expect(JellyfinServerVersion.tryParse(''), isNull);
    });
  });

  group('JellyfinServerVersion comparison', () {
    test('orders by major, then minor, then patch', () {
      expect(
        const JellyfinServerVersion(10, 9, 0) >=
            const JellyfinServerVersion(10, 8, 0),
        isTrue,
      );
      expect(
        const JellyfinServerVersion(10, 8, 0) <
            const JellyfinServerVersion(10, 9, 0),
        isTrue,
      );
      expect(
        const JellyfinServerVersion(11, 0, 0) >=
            const JellyfinServerVersion(10, 99, 99),
        isTrue,
      );
    });

    test('equal versions compare equal', () {
      expect(
        const JellyfinServerVersion(10, 9, 1) >=
            const JellyfinServerVersion(10, 9, 1),
        isTrue,
      );
      expect(
        const JellyfinServerVersion(10, 9, 1),
        const JellyfinServerVersion(10, 9, 1),
      );
    });
  });

  group('jellyfinServerSupportFor', () {
    test('a current version is supported', () {
      expect(
          jellyfinServerSupportFor('10.9.11'), JellyfinServerSupport.supported);
      expect(
          jellyfinServerSupportFor('10.10.0'), JellyfinServerSupport.supported);
    });

    test('the tested 10.10/10.11 line is supported', () {
      expect(
          jellyfinServerSupportFor('10.10.0'), JellyfinServerSupport.supported);
      expect(jellyfinServerSupportFor('10.11.11'),
          JellyfinServerSupport.supported);
    });

    test('a newer major (Jellyfin 12+) is forward-tolerant, not blocked', () {
      for (final String v in <String>[
        '12.0',
        '12.0.0',
        '12.0-rc',
        '12.0.0-rc1',
        '12.1.0',
      ]) {
        expect(
          jellyfinServerSupportFor(v),
          JellyfinServerSupport.newerUntested,
          reason: '$v should classify as newerUntested',
        );
      }
    });

    test('the forward boundary keys off the tested major', () {
      // At or below the tested major stays supported; above it flips to
      // newerUntested — guarding the kMaximumTestedJellyfinMajor boundary.
      expect(
        jellyfinServerSupportFor('$kMaximumTestedJellyfinMajor.99.99'),
        JellyfinServerSupport.supported,
      );
      expect(
        jellyfinServerSupportFor('${kMaximumTestedJellyfinMajor + 1}.0.0'),
        JellyfinServerSupport.newerUntested,
      );
    });

    test('a version at the tested minimum is supported', () {
      expect(
        jellyfinServerSupportFor(kMinimumTestedJellyfinVersion.toString()),
        JellyfinServerSupport.supported,
      );
    });

    test('an older version is untested', () {
      expect(
          jellyfinServerSupportFor('10.7.0'), JellyfinServerSupport.untested);
    });

    test('an absent or unparseable version is unknown', () {
      expect(jellyfinServerSupportFor(null), JellyfinServerSupport.unknown);
      expect(jellyfinServerSupportFor(''), JellyfinServerSupport.unknown);
      expect(jellyfinServerSupportFor('???'), JellyfinServerSupport.unknown);
    });

    test('each support level has a non-empty label', () {
      for (final JellyfinServerSupport s in JellyfinServerSupport.values) {
        expect(s.label, isNotEmpty);
      }
    });
  });
}
