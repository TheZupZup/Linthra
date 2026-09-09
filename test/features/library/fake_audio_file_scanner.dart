import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';

/// Returns a fixed list of file paths, or throws [error] when one is set, so a
/// scan can be driven without a real file system.
///
/// [filesByFolder] answers per folder instead, which is what a multi-folder
/// library needs; [unavailable] names the folders that fail the way an
/// unplugged drive does.
class FakeAudioFileScanner implements AudioFileScanner {
  FakeAudioFileScanner({
    this.files = const <String>[],
    this.filesByFolder = const <String, List<String>>{},
    this.unavailable = const <String>{},
    this.error,
  });

  final List<String> files;
  final Map<String, List<String>> filesByFolder;
  final Set<String> unavailable;
  final Object? error;
  String? requestedFolder;

  /// Every folder this scanner was asked to walk, in order.
  final List<String> requestedFolders = <String>[];

  @override
  Future<List<String>> listFiles(String folderPath) async {
    requestedFolder = folderPath;
    requestedFolders.add(folderPath);
    if (error != null) throw error!;
    if (unavailable.contains(folderPath)) {
      throw FolderScanException(
        "Linthra couldn't find the selected folder.",
        folder: folderPath,
      );
    }
    if (filesByFolder.isNotEmpty) {
      return filesByFolder[folderPath] ?? const <String>[];
    }
    return files;
  }
}
