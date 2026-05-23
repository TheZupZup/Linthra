import 'package:halcyon/core/sources/local/audio_file_scanner.dart';

/// Returns a fixed list of file paths, or throws [error] when one is set, so a
/// scan can be driven without a real file system.
class FakeAudioFileScanner implements AudioFileScanner {
  FakeAudioFileScanner({this.files = const <String>[], this.error});

  final List<String> files;
  final Object? error;
  String? requestedFolder;

  @override
  Future<List<String>> listFiles(String folderPath) async {
    requestedFolder = folderPath;
    if (error != null) throw error!;
    return files;
  }
}
