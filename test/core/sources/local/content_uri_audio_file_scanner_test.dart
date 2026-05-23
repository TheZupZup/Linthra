import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/sources/local/audio_file_scanner.dart';
import 'package:sonara/core/sources/local/folder_scan_exception.dart';

/// Records the folder it was asked to scan and returns a fixed list, so we can
/// assert the content scanner resolved the URI to a path before delegating.
class _RecordingScanner implements AudioFileScanner {
  _RecordingScanner(this._files);

  final List<String> _files;
  String? requestedFolder;

  @override
  Future<List<String>> listFiles(String folder) async {
    requestedFolder = folder;
    return _files;
  }
}

void main() {
  group('ContentUriAudioFileScanner', () {
    test('resolves a SAF tree URI to a path and delegates the walk', () async {
      final filesystem = _RecordingScanner(<String>[
        '/storage/emulated/0/Music/One.mp3',
      ]);
      final scanner = ContentUriAudioFileScanner(filesystemScanner: filesystem);

      final files = await scanner.listFiles(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      );

      expect(filesystem.requestedFolder, '/storage/emulated/0/Music');
      expect(files, <String>['/storage/emulated/0/Music/One.mp3']);
    });

    test('throws a useful error for an unresolvable provider', () async {
      final filesystem = _RecordingScanner(const <String>[]);
      final scanner = ContentUriAudioFileScanner(filesystemScanner: filesystem);

      expect(
        () => scanner.listFiles(
          'content://com.android.providers.downloads.documents/tree/raw%3A',
        ),
        throwsA(isA<FolderScanException>()),
      );
      // The walk is never attempted when the URI can't be resolved.
      expect(filesystem.requestedFolder, isNull);
    });
  });
}
