import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';

/// Records that it was called and with which folder, so we can assert the
/// router picked this backend. Reports [unreadable] as the subfolders its walk
/// could not list.
class _RecordingScanner implements AudioFileScanner {
  _RecordingScanner(
    this.label, [
    this._files = const <String>[],
    this.unreadable = const <String>[],
  ]);

  final String label;
  final List<String> _files;
  final List<String> unreadable;
  String? requestedFolder;

  @override
  Future<List<String>> listFiles(
    String folder, {
    void Function(String directory)? onUnreadableDirectory,
  }) async {
    requestedFolder = folder;
    for (final String directory in unreadable) {
      onUnreadableDirectory?.call(directory);
    }
    return _files;
  }
}

void main() {
  group('PlatformAudioFileScanner', () {
    test('routes a filesystem path to the filesystem scanner', () async {
      final filesystem = _RecordingScanner('fs', <String>['/music/One.mp3']);
      final contentUri = _RecordingScanner('content');
      final scanner = PlatformAudioFileScanner(
        filesystemScanner: filesystem,
        contentUriScanner: contentUri,
      );

      final files = await scanner.listFiles('/home/me/Music');

      expect(filesystem.requestedFolder, '/home/me/Music');
      expect(contentUri.requestedFolder, isNull);
      expect(files, <String>['/music/One.mp3']);
    });

    test('routes a content URI to the Android-capable scanner', () async {
      final filesystem = _RecordingScanner('fs');
      final contentUri = _RecordingScanner('content', <String>['/x/Two.flac']);
      final scanner = PlatformAudioFileScanner(
        filesystemScanner: filesystem,
        contentUriScanner: contentUri,
      );

      const uri = 'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic';
      final files = await scanner.listFiles(uri);

      expect(contentUri.requestedFolder, uri);
      expect(filesystem.requestedFolder, isNull);
      expect(files, <String>['/x/Two.flac']);
    });

    test('passes on the subfolders either scanner could not list', () async {
      // The desktop scan reaches the real walk only through this router, so
      // a subfolder the walk skipped has to come back out of it as well, or
      // the files under it would look deleted.
      final filesystem = _RecordingScanner(
        'fs',
        <String>['/home/me/Music/A/One.mp3'],
        <String>['/home/me/Music/B'],
      );
      final contentUri = _RecordingScanner(
        'content',
        <String>['/x/A/Two.flac'],
        <String>['/x/B'],
      );
      final scanner = PlatformAudioFileScanner(
        filesystemScanner: filesystem,
        contentUriScanner: contentUri,
      );
      final List<String> unreadable = <String>[];

      await scanner.listFiles(
        '/home/me/Music',
        onUnreadableDirectory: unreadable.add,
      );
      await scanner.listFiles(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
        onUnreadableDirectory: unreadable.add,
      );

      expect(unreadable, <String>['/home/me/Music/B', '/x/B']);
    });
  });
}
