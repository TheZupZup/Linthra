import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/folder_picker_service.dart';
import 'package:linthra/core/services/platform_folder_picker_service.dart';

/// Records which picker was asked and returns a canned answer, so the routing
/// can be asserted without a real OS dialog or platform channel.
class _RecordingPicker implements FolderPickerService {
  _RecordingPicker(this.answer);

  final String? answer;
  int calls = 0;

  @override
  Future<String?> pickFolder() async {
    calls++;
    return answer;
  }
}

void main() {
  group('PlatformFolderPickerService', () {
    test('off Android, delegates to the fallback (file_picker) chooser',
        () async {
      // The unit-test host is never Android, so the SAF picker must not run and
      // the filesystem fallback handles the pick.
      final android = _RecordingPicker('content://should-not-be-used');
      final fallback = _RecordingPicker('/home/me/Music');
      final service = PlatformFolderPickerService(
        androidPicker: android,
        fallbackPicker: fallback,
      );

      final result = await service.pickFolder();

      expect(Platform.isAndroid, isFalse, reason: 'precondition for this host');
      expect(result, '/home/me/Music');
      expect(fallback.calls, 1);
      expect(android.calls, 0);
    });
  });
}
