import 'package:file_picker/file_picker.dart';

import 'folder_picker_service.dart';

/// A [FolderPickerService] backed by the `file_picker` plugin.
///
/// `getDirectoryPath` shows the OS folder chooser on Android (Storage Access
/// Framework) and on desktop (GTK/Win32). On Android the returned value can be
/// a `content://` tree URI rather than a filesystem path — see the README's
/// "Android folder selection" notes for the implications for scanning.
class FilePickerFolderPickerService implements FolderPickerService {
  const FilePickerFolderPickerService();

  @override
  Future<String?> pickFolder() {
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select your music folder',
    );
  }
}
