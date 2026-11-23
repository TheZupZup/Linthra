import '../platform/host_platform.dart';
import 'file_picker_folder_picker_service.dart';
import 'folder_picker_service.dart';
import 'linux_folder_picker_service.dart';
import 'method_channel_saf_folder_picker.dart';

/// The default [FolderPickerService]: routes folder selection to the chooser
/// that returns a usable handle on each platform.
///
/// On Android it uses [MethodChannelSafFolderPicker], which returns the picked
/// `content://` tree URI with a persisted read grant — the scoped-storage-
/// correct selection. On Linux it uses [LinuxFolderPickerService], the runner's
/// GTK chooser, which GTK routes through xdg-desktop-portal inside the Flatpak
/// and draws in-process on a native build. Everywhere else (the other
/// desktops, where the chooser returns a real filesystem path) it uses the
/// `file_picker`-backed [FilePickerFolderPickerService]. This is the one place
/// that knows about the platform split, mirroring [PlatformAudioFileScanner] on
/// the scan side.
class PlatformFolderPickerService implements FolderPickerService {
  const PlatformFolderPickerService({
    HostPlatform? host,
    FolderPickerService androidPicker = const MethodChannelSafFolderPicker(),
    FolderPickerService linuxPicker = const LinuxFolderPickerService(),
    FolderPickerService fallbackPicker = const FilePickerFolderPickerService(),
  })  : _host = host,
        _androidPicker = androidPicker,
        _linuxPicker = linuxPicker,
        _fallbackPicker = fallbackPicker;

  /// The platform to route for. Null means "ask the real host", which is what
  /// the app always does; tests pass a value so both branches are reachable
  /// from one machine.
  final HostPlatform? _host;
  final FolderPickerService _androidPicker;
  final FolderPickerService _linuxPicker;
  final FolderPickerService _fallbackPicker;

  @override
  Future<String?> pickFolder() {
    final HostPlatform host = _host ?? HostPlatform.current;
    if (host.isAndroid) {
      return _androidPicker.pickFolder();
    }
    if (host == HostPlatform.linux) {
      return _linuxPicker.pickFolder();
    }
    return _fallbackPicker.pickFolder();
  }
}
