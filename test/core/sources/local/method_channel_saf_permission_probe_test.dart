import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/method_channel_saf_permission_probe.dart';
import 'package:linthra/core/sources/local/saf_permission_probe.dart';

void main() {
  group('MethodChannelSafPermissionProbe', () {
    test('reports "unknown" (null) off Android', () async {
      // The unit-test host is never Android, so the probe can't determine the
      // grant state and must report null rather than guess — the report then
      // simply omits the persisted-permission line.
      const probe = MethodChannelSafPermissionProbe();

      expect(await probe.hasPersistedPermission('content://x/tree/y'), isNull);
    });
  });

  group('UnsupportedSafPermissionProbe', () {
    test('always reports "unknown" (null)', () async {
      const probe = UnsupportedSafPermissionProbe();

      expect(await probe.hasPersistedPermission('content://x/tree/y'), isNull);
    });
  });
}
