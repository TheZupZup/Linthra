import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/method_channel_saf_folder_picker.dart';

void main() {
  group('MethodChannelSafFolderPicker', () {
    test('returns null (no selection) off Android without touching the channel',
        () async {
      // Off Android the picker short-circuits, so the host test never reaches a
      // platform channel — the caller treats null as "no folder chosen".
      const picker = MethodChannelSafFolderPicker();

      expect(Platform.isAndroid, isFalse, reason: 'precondition for this host');
      expect(await picker.pickFolder(), isNull);
    });
  });
}
