import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';

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
    this.fault,
  });

  List<String> files;

  /// Mutable so one test can scan, change what is on "disk", and scan again,
  /// which is the whole shape of an add / delete / move test.
  Map<String, List<String>> filesByFolder;
  Set<String> unavailable;

  /// Why an [unavailable] folder failed. Set it to reach the recovery state a
  /// real scan would produce for that kind of failure; left null the failure
  /// carries no diagnosis, the way an older scanner's would not.
  LocalRootFault? fault;
  Object? error;
  String? requestedFolder;

  /// Every folder this scanner was asked to walk, in order.
  final List<String> requestedFolders = <String>[];

  @override
  Future<List<String>> listFiles(String folderPath) async {
    requestedFolder = folderPath;
    requestedFolders.add(folderPath);
    if (error != null) throw error!;
    if (unavailable.contains(folderPath)) {
      final LocalRootFault? fault = this.fault;
      if (fault != null) throw rootFaultException(folderPath, fault);
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
