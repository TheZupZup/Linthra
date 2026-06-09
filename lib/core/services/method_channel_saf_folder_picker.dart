import 'dart:io';

import 'package:flutter/services.dart';

import 'folder_picker_service.dart';

/// A [FolderPickerService] that opens Android's Storage Access Framework folder
/// chooser through the native SAF method channel and returns the picked
/// `content://` tree URI — with its read grant persisted by the native side.
///
/// This exists because the `file_picker` plugin's `getDirectoryPath` resolves an
/// Android folder pick to a raw `/storage/...` filesystem path (and takes no
/// persistable URI permission). Under scoped storage (Android 11+) the app
/// cannot read that path with `dart:io`, so the scan turned up nothing even
/// though the folder was full of music. Returning the tree URI instead routes
/// the scan through the content resolver (`SafDocumentScanner`), the only path
/// scoped storage actually allows.
///
/// Off Android — or when the native handler isn't registered — it returns `null`
/// (treated as "no selection") so callers can fall back to another picker.
class MethodChannelSafFolderPicker implements FolderPickerService {
  const MethodChannelSafFolderPicker();

  // Mirrors MainActivity.kt's SAF_CHANNEL and the lister/probe channel name.
  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/saf');

  @override
  Future<String?> pickFolder() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      // Returns the picked tree URI, or null when the user cancelled.
      return await _channel.invokeMethod<String>('pickFolderTree');
    } on MissingPluginException {
      // The native handler isn't registered (shouldn't happen on a real build);
      // let the caller fall back rather than throwing into the UI.
      return null;
    } on PlatformException {
      // No chooser available, or a pick already in flight. Treat as no
      // selection rather than surfacing a raw platform error.
      return null;
    }
  }
}
