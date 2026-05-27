import 'package:flutter_test/flutter_test.dart';

import '../../tool/version_from_tag.dart';

/// Specifies tool/version_from_tag.dart — the single source of truth that turns
/// a `v*` release tag into the `versionName`/`versionCode` baked into a build.
/// See docs/release-process.md §1.
void main() {
  group('versionFromTag — supported tags', () {
    test('v0.1.0-alpha.16 → 0.1.0-alpha.16 / 100016', () {
      final TagVersion v = versionFromTag('v0.1.0-alpha.16');
      expect(v.name, '0.1.0-alpha.16');
      expect(v.code, 100016);
    });

    test('v0.1.0-beta.1 → 0.1.0-beta.1 / 100301', () {
      final TagVersion v = versionFromTag('v0.1.0-beta.1');
      expect(v.name, '0.1.0-beta.1');
      expect(v.code, 100301);
    });

    test('v0.1.0-rc.1 → 0.1.0-rc.1 / 100601', () {
      final TagVersion v = versionFromTag('v0.1.0-rc.1');
      expect(v.name, '0.1.0-rc.1');
      expect(v.code, 100601);
    });

    test('v0.1.0 (stable) → 0.1.0 / 100999', () {
      final TagVersion v = versionFromTag('v0.1.0');
      expect(v.name, '0.1.0');
      expect(v.code, 100999);
    });

    test('v1.2.3 (stable) → 1.2.3 / 10203999', () {
      final TagVersion v = versionFromTag('v1.2.3');
      expect(v.name, '1.2.3');
      expect(v.code, 10203999);
    });

    test('strips the leading v but keeps the pre-release suffix', () {
      expect(versionFromTag('v0.1.0-alpha.16').name, '0.1.0-alpha.16');
      expect(versionFromTag('v2.0.0').name, '2.0.0');
    });

    test('accepts a tag with no leading v', () {
      final TagVersion v = versionFromTag('0.1.0-alpha.16');
      expect(v.name, '0.1.0-alpha.16');
      expect(v.code, 100016);
    });

    test('tolerates surrounding whitespace', () {
      expect(versionFromTag('  v0.1.0  ').name, '0.1.0');
    });
  });

  group('versionFromTag — versionCode is strictly monotonic', () {
    test('orders the tiers below the stable release of the same x.y.z', () {
      final int alpha = versionFromTag('v0.1.0-alpha.16').code;
      final int beta = versionFromTag('v0.1.0-beta.1').code;
      final int rc = versionFromTag('v0.1.0-rc.1').code;
      final int stable = versionFromTag('v0.1.0').code;
      expect(alpha, lessThan(beta));
      expect(beta, lessThan(rc));
      expect(rc, lessThan(stable));
    });

    test('never goes backwards along a realistic release path', () {
      const List<String> path = <String>[
        'v0.1.0-alpha.15',
        'v0.1.0-alpha.16',
        'v0.1.0-alpha.99',
        'v0.1.0-beta.1',
        'v0.1.0-beta.2',
        'v0.1.0-rc.1',
        'v0.1.0',
        'v0.1.1-alpha.1',
        'v0.1.1',
        'v0.2.0-alpha.1',
        'v0.2.0',
        'v1.0.0-alpha.1',
        'v1.0.0',
        'v1.2.3',
      ];
      final List<int> codes =
          path.map((String t) => versionFromTag(t).code).toList();
      for (int i = 1; i < codes.length; i++) {
        expect(
          codes[i],
          greaterThan(codes[i - 1]),
          reason: '${path[i]} (${codes[i]}) must exceed '
              '${path[i - 1]} (${codes[i - 1]})',
        );
      }
    });

    test('a higher pre-release number yields a higher code', () {
      expect(
        versionFromTag('v0.1.0-alpha.17').code,
        greaterThan(versionFromTag('v0.1.0-alpha.16').code),
      );
    });

    test('stays within the valid Android versionCode ceiling', () {
      expect(versionFromTag('v1.2.3').code, lessThanOrEqualTo(2100000000));
    });
  });

  group('versionFromTag — malformed tags fail clearly', () {
    test('rejects a two-part version', () {
      expect(() => versionFromTag('v1.2'), throwsFormatException);
    });

    test('rejects a four-part version', () {
      expect(() => versionFromTag('v1.2.3.4'), throwsFormatException);
    });

    test('rejects a non-numeric version', () {
      expect(() => versionFromTag('vfoo'), throwsFormatException);
      expect(() => versionFromTag(''), throwsFormatException);
    });

    test('rejects a pre-release tier with no number', () {
      expect(() => versionFromTag('v1.2.3-alpha'), throwsFormatException);
    });

    test('rejects a non-numeric pre-release number', () {
      expect(() => versionFromTag('v1.2.3-alpha.x'), throwsFormatException);
    });

    test('rejects an unknown pre-release tier', () {
      expect(() => versionFromTag('v1.2.3-preview.1'), throwsFormatException);
      expect(() => versionFromTag('v1.2.3-dev.1'), throwsFormatException);
    });

    test('rejects SemVer build metadata', () {
      expect(
        () => versionFromTag('v1.2.3-alpha.1+build'),
        throwsFormatException,
      );
    });

    test('rejects fields that overflow the encoding', () {
      expect(() => versionFromTag('v0.100.0'), throwsFormatException);
      expect(() => versionFromTag('v0.1.100'), throwsFormatException);
      expect(() => versionFromTag('v0.1.0-alpha.300'), throwsFormatException);
    });

    test('rejects a major version too large to encode safely', () {
      expect(() => versionFromTag('v210.0.0'), throwsFormatException);
    });
  });
}
