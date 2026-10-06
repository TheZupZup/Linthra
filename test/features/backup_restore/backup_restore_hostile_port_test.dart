// A backup whose server address has a port too long for an int.
//
// `previewRestore` promises a readable plan or a typed failure, never a
// throw. `Uri.tryParse` accepts such an address, and its `port` getter then
// throws a FormatException (the #769 shape), which escaped
// `normalizeBackupBaseUrl` and sank the whole preview: the other servers and
// the preferences in the file could not be restored either.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/backup_restore/backup_import_plan.dart';
import 'package:linthra/features/backup_restore/backup_restore_service.dart';

void main() {
  const String tooLong = 'https://nd.example.com:99999999999999999999';

  test('normalizing the address does not throw', () {
    expect(() => normalizeBackupBaseUrl(tooLong), returnsNormally);
    expect(normalizeBackupBaseUrl(tooLong), isNot(isEmpty));
  });

  test('the rest of the backup still previews', () {
    final String backup = jsonEncode(<String, Object>{
      'linthraBackup': <String, Object>{
        'formatVersion': 1,
        'servers': <Object>[
          <String, Object>{
            'type': 'jellyfin',
            'baseUrl': 'https://music.example.com',
          },
          <String, Object>{'type': 'subsonic', 'baseUrl': tooLong},
        ],
        'preferences': <String, Object>{
          'playback': <String, Object>{'normalizeVolume': true},
        },
      },
    });

    final BackupRestorePreview preview =
        const BackupRestoreService().previewRestore(backup);

    expect(preview, isA<BackupRestorePreviewReady>());
    final BackupImportPlan plan = (preview as BackupRestorePreviewReady).plan;
    expect(
      plan.serversToAdd.map((PlannedServerAddition s) => s.normalizedBaseUrl),
      contains('https://music.example.com'),
    );
    expect(plan.preferences.applied.playback?.normalizeVolume, isTrue);
  });
}
