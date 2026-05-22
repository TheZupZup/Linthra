import 'dart:io';

/// Discovers files under a folder on the device.
///
/// This is the single seam through which the local source touches the file
/// system. Isolating it keeps the source's discovery/mapping logic pure enough
/// to unit-test against a fake. Deciding which files are audio is the caller's
/// job, not the scanner's.
abstract interface class AudioFileScanner {
  /// Returns the absolute paths of every regular file under [folderPath],
  /// searched recursively. Returns an empty list when the folder is missing.
  Future<List<String>> listFiles(String folderPath);
}

/// An [AudioFileScanner] backed by `dart:io`.
class IoAudioFileScanner implements AudioFileScanner {
  const IoAudioFileScanner();

  @override
  Future<List<String>> listFiles(String folderPath) async {
    final Directory directory = Directory(folderPath);
    if (!await directory.exists()) {
      return const <String>[];
    }

    final List<String> paths = <String>[];
    final Stream<FileSystemEntity> entities = directory.list(
      recursive: true,
      followLinks: false,
    );
    await for (final FileSystemEntity entity in entities) {
      if (entity is File) {
        paths.add(entity.absolute.path);
      }
    }
    return paths;
  }
}
