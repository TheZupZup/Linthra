import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';

/// Records that it was called and with which folder, so we can assert the
/// router picked this backend.
class _RecordingScanner implements AudioFileScanner {
  _RecordingScanner(this.label, [this._files = const <String>[]]);

  final String label;
  final List<String> _files;
  String? requestedFolder;

  @override
  Future<List<String>> listFiles(String folder) async {
    requestedFolder = folder;
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
  });
}
