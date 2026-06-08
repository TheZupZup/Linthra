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
      expect(doc.mimeType, isNull);
    });

    test('carries the provider MIME type when known', () {
      const doc = SafAudioDocument(
        uri: 'content://x/2',
        name: 'Two.flac',
        mimeType: 'audio/flac',
      );

      expect(doc.mimeType, 'audio/flac');
    });
  });

  group('SafScanResult', () {
    test('defaults to an empty, failure-free result', () {
      const result = SafScanResult();

      expect(result.documents, isEmpty);
      expect(result.filesVisited, 0);
      expect(result.readFailures, 0);
    });

    test('carries the documents and the diagnostic counts', () {
      const result = SafScanResult(
        documents: <SafAudioDocument>[
          SafAudioDocument(uri: 'content://x/1', name: 'One.mp3'),
        ],
        filesVisited: 3,
        readFailures: 1,
      );

      expect(result.documents, hasLength(1));
      expect(result.filesVisited, 3);
      expect(result.readFailures, 1);
    });
  });
}
