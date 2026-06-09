import 'package:file_picker/file_picker.dart';

import 'folder_picker_service.dart';

/// A [FolderPickerService] backed by the `file_picker` plugin — the desktop
/// (GTK/Win32) folder chooser.
///
/// It is **not** used on Android: there, `getDirectoryPath` resolves the picked
/// folder to a raw `/storage/...` filesystem path (via `getFullPathFromTreeUri`)
/// and takes no persistable URI grant, so under scoped storage the scan can't
/// read it — the cause of the "no music found" reports. `PlatformFolderPickerService`
/// routes Android to the native SAF chooser (`MethodChannelSafFolderPicker`),
/// which returns a `content://` tree URI with a persisted read grant, and uses
/// this class only as the desktop fallback (where a filesystem path is correct).
class FilePickerFolderPickerService implements FolderPickerService {
  const FilePickerFolderPickerService();

  @override
  Future<String?> pickFolder() {
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select your music folder',
    );
  }
}
