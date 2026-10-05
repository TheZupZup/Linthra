import 'dart:io';

import 'package:flutter/services.dart';

import 'method_channel_linux_folder_picker.dart';
import 'text_file_saver.dart';

/// A [TextFileSaver] that asks where to save through the desktop's save
/// dialog, on Linthra's own Linux runner channel (the one the folder chooser
/// uses, `linux/runner/folder_picker_channel.cc`), then writes the file there.
///
/// Saving used to write into `getApplicationDocumentsDirectory()`, which on
/// Linux is `xdg-user-dir DOCUMENTS` (#748). Without `xdg-user-dir` that threw;
/// inside the Flatpak, which has no access to Documents, it was the sandbox's
/// own temporary home, so "Saved" was shown for a file gone when the app
/// closed. The runner's `GtkFileChooserNative` in save mode draws the GTK save
/// dialog on a native build, and inside the sandbox goes through the
/// xdg-desktop-portal FileChooser: the host asks where to save, and the path
/// it hands back is one the sandbox may write to, with no filesystem
/// permission at all.
class MethodChannelLinuxFileSaver implements TextFileSaver {
  const MethodChannelLinuxFileSaver({MethodChannel channel = _defaultChannel})
      : _channel = channel;

  /// Mirrors `kSaveFileMethod` in the runner;
  /// `scripts/check_linux_runner.py` holds the two to the same string.
  static const String saveFileMethod = 'saveFile';

  /// The runner's code for "a chooser is already open". That one is on
  /// screen, so this request just didn't happen.
  static const String chooserInProgressCode = 'pick_in_progress';

  static const MethodChannel _defaultChannel =
      MethodChannel(MethodChannelLinuxFolderPicker.channelName);

  final MethodChannel _channel;

  @override
  Future<TextFileSaveResult> save({
    required String suggestedName,
    required String contents,
    required String dialogTitle,
  }) async {
    final String? path;
    try {
      // Null means the user cancelled; the runner reports every other outcome
      // as a platform error.
      path = await _channel.invokeMethod<String>(
        saveFileMethod,
        <String, Object?>{'title': dialogTitle, 'suggestedName': suggestedName},
      );
    } on MissingPluginException {
      // A runner without the channel (or a test host). Writing somewhere
      // instead is what went wrong before, so this is a failure.
      return const TextFileSaveFailed();
    } on PlatformException catch (error) {
      if (error.code == chooserInProgressCode) {
        return const TextFileSaveCancelled();
      }
      // No chooser, or a place with no local path (a network location).
      return const TextFileSaveFailed();
    }
    if (path == null) return const TextFileSaveCancelled();
    try {
      await File(path).writeAsString(contents, flush: true);
      return TextFileSaved(path);
    } catch (_) {
      return const TextFileSaveFailed();
    }
  }
}
