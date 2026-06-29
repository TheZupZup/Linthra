import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/safe_event_log.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_sync_diagnostics.dart';

void main() {
  group('JellyfinSyncDiagnostics.skipped', () {
    setUp(SafeEventLog.instance.clear);
    tearDown(SafeEventLog.instance.clear);

    test('records a secret-free breadcrumb when items were skipped', () {
      JellyfinSyncDiagnostics.skipped(
        kind: JellyfinItemKind.audio,
        skipped: 2,
        kept: 40,
      );

      expect(SafeEventLog.instance.lines, hasLength(1));
      final String line = SafeEventLog.instance.lines.single;
      expect(line, contains('jellyfin-sync'));
      expect(line, contains('skip:audio'));
      expect(line, contains('dropped=2'));
      expect(line, contains('kept=40'));
    });

    test('is silent when nothing was skipped', () {
      JellyfinSyncDiagnostics.skipped(
        kind: JellyfinItemKind.album,
        skipped: 0,
        kept: 12,
      );

      expect(SafeEventLog.instance.isEmpty, isTrue);
    });

    test('carries only the kind name and counts — never free text', () {
      // The API has no parameter for a title, URL, or token; this guards that
      // the recorded detail is structural only.
      JellyfinSyncDiagnostics.skipped(
        kind: JellyfinItemKind.artist,
        skipped: 1,
        kept: 0,
      );

      final String line = SafeEventLog.instance.lines.single;
      expect(line, 'jellyfin-sync: skip:artist dropped=1 kept=0');
    });
  });
}
