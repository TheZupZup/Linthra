import 'package:flutter/services.dart';

import '../platform/host_platform.dart';
import 'folder_picker_service.dart';
import 'linux_music_directory.dart';

/// A [FolderPickerService] that opens the desktop folder chooser through
/// Linthra's own Linux runner channel (`linux/runner/folder_picker_channel.cc`)
/// and returns the chosen folder's filesystem path.
///
/// This exists for the Flatpak. The `file_picker` plugin's Linux
/// implementation shells out to `zenity`/`qarma`/`kdialog`; none of those
/// binaries exist inside the sandbox, so a Flatpak pick failed before any
/// dialog appeared. The runner instead uses GTK's `GtkFileChooserNative`, which
/// GTK routes to the **xdg-desktop-portal** FileChooser when the app is
/// sandboxed and draws in-process otherwise — so one path serves both builds:
///
///  - Native Linux: the ordinary GTK folder dialog, returning a real path.
///  - Flatpak: the portal runs the chooser on the host, and the folder the user
///    picked comes back as a document-portal path (under `/run/user/…/doc/…`)
///    that the sandbox may read. The user's explicit choice *is* the grant, so
///    no `--filesystem=` permission is needed, and the grant persists across
///    restarts for as long as the document store keeps it.
///
/// Off Linux, or on a build whose runner did not register the channel, it
/// throws [FolderPickerUnavailableException] so [LinuxFolderPickerService] can
/// fall back to the plugin chooser instead of reporting a cancel.
class MethodChannelLinuxFolderPicker implements FolderPickerService {
  const MethodChannelLinuxFolderPicker({
    HostPlatform? host,
    MethodChannel channel = _defaultChannel,
    LinuxMusicDirectory suggestedDirectory = const LinuxMusicDirectory(),
  })  : _host = host,
        _channel = channel,
        _suggestedDirectory = suggestedDirectory;

  /// Mirrors `kChannelName` in `linux/runner/folder_picker_channel.cc`;
  /// `scripts/check_linux_runner.py` holds the two to the same string.
  static const String channelName =
      'io.github.thezupzup.linthra/linux_folder_picker';

  /// Mirrors `kPickFolderMethod` in the runner.
  static const String pickFolderMethod = 'pickFolder';

  /// The runner's "GTK could not give me a chooser" code — the one platform
  /// error that means "fall back", rather than "no folder was chosen".
  static const String chooserUnavailableCode = 'chooser_unavailable';

  /// The chooser's title. Lives here, with the rest of the app's copy, rather
  /// than in the runner.
  static const String dialogTitle = 'Select your music folder';

  static const MethodChannel _defaultChannel = MethodChannel(channelName);

  final HostPlatform? _host;
  final MethodChannel _channel;

  /// The folder to open the chooser at — only ever a suggestion; see
  /// [LinuxMusicDirectory].
  final LinuxMusicDirectory _suggestedDirectory;

  @override
  Future<String?> pickFolder() async {
    final HostPlatform host = _host ?? HostPlatform.current;
    if (host != HostPlatform.linux) {
      throw const FolderPickerUnavailableException(
        'the GTK/portal chooser is only registered by the Linux runner',
      );
    }
    try {
      // Null means the user cancelled; the runner reports every other outcome
      // as a platform error.
      return await _channel.invokeMethod<String>(
        pickFolderMethod,
        <String, Object?>{
          'title': dialogTitle,
          'initialDirectory': await _suggestedDirectory.resolve(host: host),
        },
      );
    } on MissingPluginException {
      // A build whose runner predates the channel (or a test host). Let the
      // caller fall back rather than leaving the user with no chooser.
      throw const FolderPickerUnavailableException(
        'the Linux runner did not register the folder picker channel',
      );
    } on PlatformException catch (error) {
      if (error.code == chooserUnavailableCode) {
        throw FolderPickerUnavailableException(
          'the Linux runner could not open a chooser: ${error.code}',
        );
      }
      // A pick already in flight, or a selection with no local path (a network
      // location the scanner could not walk anyway). Treat as no selection
      // rather than surfacing a raw platform error.
      return null;
    }
  }
}
