import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

void main() {
  group('UnsupportedSafDocumentLister', () {
    test('always reports SAF traversal unavailable', () async {
      const lister = UnsupportedSafDocumentLister();

      await expectLater(
        lister.listAudioDocuments('content://x/tree/y'),
        throwsA(isA<SafUnsupportedException>()),
      );
    });
  });

  group('SafAudioDocument', () {
    test('carries the content uri and display name', () {
      const doc = SafAudioDocument(uri: 'content://x/1', name: 'One.mp3');

      expect(doc.uri, 'content://x/1');
      expect(doc.name, 'One.mp3');
    });
  });
}
