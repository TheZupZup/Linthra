import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/folder_picker_service.dart';
import '../../core/services/platform_folder_picker_service.dart';
import '../../core/sources/local/audio_file_scanner.dart';
import '../../core/sources/local/method_channel_saf_document_lister.dart';
import '../../core/sources/local/method_channel_saf_permission_probe.dart';
import '../../core/sources/local/saf_document_lister.dart';
import '../../core/sources/local/saf_permission_probe.dart';

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
/// folder. Defaults to [PlatformFolderPickerService], which on Android returns
/// the picked `content://` tree URI (with a persisted read grant) and elsewhere
/// falls back to the `file_picker` filesystem chooser. Tests override it with a
/// fake so the pick-and-scan flow runs without a real OS dialog.
final folderPickerServiceProvider = Provider<FolderPickerService>((ref) {
  return const PlatformFolderPickerService();
});

/// The SAF traversal seam used to scan an Android `content://` folder through
/// the content resolver. Native content-resolver traversal is Android-only, so
/// elsewhere (desktop, tests) the unsupported binding makes a content-URI scan
/// fall back to filesystem path resolution. Tests override it with a fake.
final safDocumentListerProvider = Provider<SafDocumentLister>((ref) {
  return Platform.isAndroid
      ? const MethodChannelSafDocumentLister()
      : const UnsupportedSafDocumentLister();
});

/// The seam diagnostics use to check whether a persisted SAF read grant is still
/// held for the selected `content://` folder — the removable-SD-card signal that
/// tells "no music found" apart from a lost folder permission. Android-only;
/// elsewhere (desktop, tests) the unsupported binding reports `null` so the
/// persisted-permission line is simply omitted. Tests override it with a fake.
final safPermissionProbeProvider = Provider<SafPermissionProbe>((ref) {
  return Platform.isAndroid
      ? const MethodChannelSafPermissionProbe()
      : const UnsupportedSafPermissionProbe();
});
