import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/directory_readability.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';

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

/// A [DirectoryReadability] with a fixed answer, so the scoped-storage probe
/// can be exercised without a real device.
class _FakeReadability implements DirectoryReadability {
  _FakeReadability(this._readable);

  final bool _readable;
  String? probedPath;

  @override
  Future<bool> canList(String path) async {
    probedPath = path;
    return _readable;
  }
}

void main() {
  group('ContentUriAudioFileScanner', () {
    test('resolves a SAF tree URI to a path and delegates the walk', () async {
      final filesystem = _RecordingScanner(<String>[
        '/storage/emulated/0/Music/One.mp3',
      ]);
      final readability = _FakeReadability(true);
      final scanner = ContentUriAudioFileScanner(
        filesystemScanner: filesystem,
        readability: readability,
      );

      final files = await scanner.listFiles(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      );

      expect(readability.probedPath, '/storage/emulated/0/Music');
      expect(filesystem.requestedFolder, '/storage/emulated/0/Music');
      expect(files, <String>['/storage/emulated/0/Music/One.mp3']);
    });

    test('throws a useful error for an unresolvable provider', () async {
      final filesystem = _RecordingScanner(const <String>[]);
      final scanner = ContentUriAudioFileScanner(
        filesystemScanner: filesystem,
        readability: _FakeReadability(true),
      );

      expect(
        () => scanner.listFiles(
          'content://com.android.providers.downloads.documents/tree/raw%3A',
        ),
        throwsA(isA<FolderScanException>()),
      );
      // The walk is never attempted when the URI can't be resolved.
      expect(filesystem.requestedFolder, isNull);
    });

    test('throws a useful error when the resolved path is not readable',
        () async {
      // The external-storage URI resolves to a real path, but scoped storage
      // blocks reading it. The scanner must surface a clear error instead of
      // delegating a walk that would silently return nothing.
      final filesystem = _RecordingScanner(const <String>[]);
      final readability = _FakeReadability(false);
      final scanner = ContentUriAudioFileScanner(
        filesystemScanner: filesystem,
        readability: readability,
      );

      await expectLater(
        () => scanner.listFiles(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic',
        ),
        throwsA(
          isA<FolderScanException>().having(
            (e) => e.message,
            'message',
            contains('not letting it read'),
          ),
        ),
      );
      expect(readability.probedPath, '/storage/emulated/0/Music');
      // The walk is skipped when the resolved path can't be read.
      expect(filesystem.requestedFolder, isNull);
    });
  });
}
