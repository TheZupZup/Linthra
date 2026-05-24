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
