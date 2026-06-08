import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/folder_location.dart';

void main() {
  group('FolderLocation', () {
    test('classifies a POSIX filesystem path', () {
      final location = FolderLocation.parse('/home/me/Music');
      expect(location.kind, FolderLocationKind.filesystemPath);
      expect(location.isFilesystemPath, isTrue);
      expect(location.isContentUri, isFalse);
      expect(location.raw, '/home/me/Music');
    });

    test('classifies a Windows filesystem path', () {
      final location = FolderLocation.parse(r'C:\Users\me\Music');
      expect(location.kind, FolderLocationKind.filesystemPath);
    });

    test('classifies an Android SAF content tree URI', () {
      final location = FolderLocation.parse(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      );
      expect(location.kind, FolderLocationKind.contentUri);
      expect(location.isContentUri, isTrue);
      expect(location.isFilesystemPath, isFalse);
    });

    test('treats the content scheme case-insensitively', () {
      final location = FolderLocation.parse('CONTENT://authority/tree/x');
      expect(location.kind, FolderLocationKind.contentUri);
    });

    test('treats a file:// URI as a filesystem path, not a content URI', () {
      final location = FolderLocation.parse('file:///home/me/Music');
      expect(location.kind, FolderLocationKind.filesystemPath);
    });

    group('displayLabel', () {
      test('reduces a SAF tree URI to its decoded document id', () {
        final location = FolderLocation.parse(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMusic%2Fmusi5',
        );
        expect(location.displayLabel, 'primary:Music/musi5');
      });

      test('reduces an SD-card SAF tree URI to its volume:path id', () {
        final location = FolderLocation.parse(
          'content://com.android.externalstorage.documents/tree/'
          '1A2B-3C4D%3AMusic',
        );
        expect(location.displayLabel, '1A2B-3C4D:Music');
      });

      test('returns a filesystem path unchanged', () {
        final location =
            FolderLocation.parse('/storage/emulated/0/Music/musi5');
        expect(location.displayLabel, '/storage/emulated/0/Music/musi5');
      });

      test('falls back to the raw value for an unexpected content URI', () {
        final location =
            FolderLocation.parse('content://authority/document/only');
        expect(location.displayLabel, 'content://authority/document/only');
      });
    });
  });
}
