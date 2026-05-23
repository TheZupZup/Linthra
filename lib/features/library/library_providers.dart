import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sources/local/audio_file_scanner.dart';

/// The file-system seam the library scan uses to discover audio files.
///
/// Defaults to the real `dart:io` scanner. Tests override it with a fake so a
/// scan can run end-to-end without touching a real disk. This is the only new
/// provider the scan flow needs — the repository and library state already have
/// their own providers (`musicLibraryRepositoryProvider`,
/// `libraryControllerProvider`).
final audioFileScannerProvider = Provider<AudioFileScanner>((ref) {
  return const IoAudioFileScanner();
});
