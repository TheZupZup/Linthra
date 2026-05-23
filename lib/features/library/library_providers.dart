import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/file_picker_folder_picker_service.dart';
import '../../core/services/folder_picker_service.dart';
import '../../core/sources/local/audio_file_scanner.dart';

/// The storage seam the library scan uses to discover audio files.
///
/// Defaults to [PlatformAudioFileScanner], which routes a selected folder to
/// the right backend: a `dart:io` walk for desktop/Linux filesystem paths, and
/// the SAF-aware [ContentUriAudioFileScanner] for Android `content://` tree
/// URIs. Tests override it with a fake so a scan can run end-to-end without
/// touching a real disk. This is the only new provider the scan flow needs —
/// the repository and library state already have their own providers
/// (`musicLibraryRepositoryProvider`, `libraryControllerProvider`).
final audioFileScannerProvider = Provider<AudioFileScanner>((ref) {
  return const PlatformAudioFileScanner();
});

/// The folder-chooser seam the Library uses to let the user pick a music
/// folder. Defaults to the `file_picker`-backed implementation; tests override
/// it with a fake so the pick-and-scan flow runs without a real OS dialog.
final folderPickerServiceProvider = Provider<FolderPickerService>((ref) {
  return const FilePickerFolderPickerService();
});
