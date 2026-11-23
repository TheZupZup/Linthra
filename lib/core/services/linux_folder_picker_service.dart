import 'file_picker_folder_picker_service.dart';
import 'folder_picker_service.dart';
import 'method_channel_linux_folder_picker.dart';

/// The [FolderPickerService] Linux uses: the runner's GTK/portal chooser, with
/// the `file_picker` chooser as a fallback.
///
/// The order is deliberate. [MethodChannelLinuxFolderPicker] is the chooser
/// that works in *both* Linux builds — a plain GTK dialog natively, and the
/// xdg-desktop-portal chooser inside the Flatpak, where `file_picker`'s
/// `zenity`/`kdialog` binaries do not exist. The plugin chooser is kept
/// only for a build that has no such channel registered (a `flutter test` host,
/// or an older runner), so nothing regresses if the native half is missing.
///
/// A cancel is never a fallback: only [FolderPickerUnavailableException] — "no
/// chooser here" — moves on to the plugin, so cancelling never pops a second
/// dialog.
class LinuxFolderPickerService implements FolderPickerService {
  const LinuxFolderPickerService({
    FolderPickerService nativePicker = const MethodChannelLinuxFolderPicker(),
    FolderPickerService fallbackPicker = const FilePickerFolderPickerService(),
  })  : _nativePicker = nativePicker,
        _fallbackPicker = fallbackPicker;

  final FolderPickerService _nativePicker;
  final FolderPickerService _fallbackPicker;

  @override
  Future<String?> pickFolder() async {
    try {
      return await _nativePicker.pickFolder();
    } on FolderPickerUnavailableException {
      // Fall through to the plugin chooser below.
    }
    try {
      return await _fallbackPicker.pickFolder();
    } catch (_) {
      // `file_picker` throws a plain Exception on Linux when it can find no
      // `zenity`/`qarma`/`kdialog` to shell out to. There is no chooser left to
      // try, so this is "no folder chosen" rather than something to throw into
      // the UI — the same outcome the user sees if they cancel.
      return null;
    }
  }
}
