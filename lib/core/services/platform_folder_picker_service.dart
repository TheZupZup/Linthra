import 'dart:io';

import 'file_picker_folder_picker_service.dart';
import 'folder_picker_service.dart';
import 'method_channel_saf_folder_picker.dart';

/// The default [FolderPickerService]: routes folder selection to the chooser
/// that returns a usable handle on each platform.
///
/// On Android it uses [MethodChannelSafFolderPicker], which returns the picked
/// `content://` tree URI with a persisted read grant — the scoped-storage-
/// correct selection. Everywhere else (desktop, where the chooser returns a real
/// filesystem path) it uses the `file_picker`-backed
/// [FilePickerFolderPickerService]. This is the one place that knows about the
/// platform split, mirroring [PlatformAudioFileScanner] on the scan side.
class PlatformFolderPickerService implements FolderPickerService {
  const PlatformFolderPickerService({
    FolderPickerService androidPicker = const MethodChannelSafFolderPicker(),
    FolderPickerService fallbackPicker = const FilePickerFolderPickerService(),
  })  : _androidPicker = androidPicker,
        _fallbackPicker = fallbackPicker;

  final FolderPickerService _androidPicker;
  final FolderPickerService _fallbackPicker;

  @override
  Future<String?> pickFolder() {
    if (Platform.isAndroid) {
      return _androidPicker.pickFolder();
    }
    return _fallbackPicker.pickFolder();
  }
}
