import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/method_channel_saf_document_lister.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

void main() {
  group('MethodChannelSafDocumentLister.parseScanResult', () {
    test('a null reply is an empty, failure-free result', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(null);

      expect(result.documents, isEmpty);
      expect(result.filesVisited, 0);
      expect(result.readFailures, 0);
    });

    test('parses documents, mime types, and the diagnostic counts', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/1',
              'name': 'One.mp3',
              'mime': 'audio/mpeg',
            },
            <Object?, Object?>{
              'uri': 'content://doc/2',
              'name': 'Two.flac',
              'mime': 'audio/flac',
            },
          ],
          'filesVisited': 5,
          'readFailures': 1,
        },
      );

      expect(result.documents, hasLength(2));
      expect(result.documents.first.uri, 'content://doc/1');
      expect(result.documents.first.name, 'One.mp3');
      expect(result.documents.first.mimeType, 'audio/mpeg');
      expect(result.filesVisited, 5);
      expect(result.readFailures, 1);
    });

    test('falls back to the document count when no visited total is reported',
        () {
      // An older native build that returned only documents must still scan.
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{'uri': 'content://doc/1', 'name': 'One.mp3'},
          ],
        },
      );

      expect(result.documents, hasLength(1));
      expect(result.filesVisited, 1);
      expect(result.readFailures, 0);
      expect(result.documents.single.mimeType, isNull);
    });

    test('skips malformed entries without throwing', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{'uri': 'content://doc/1', 'name': 'Good.mp3'},
            <Object?, Object?>{'uri': '', 'name': 'EmptyUri.mp3'},
            <Object?, Object?>{'uri': 'content://doc/3'}, // missing name
            'not-a-map',
          ],
          'filesVisited': 4,
        },
      );

      expect(result.documents, hasLength(1));
      expect(result.documents.single.name, 'Good.mp3');
      expect(result.filesVisited, 4);
    });

    test('a non-string mime is treated as unknown', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/1',
              'name': 'One.mp3',
              'mime': 42,
            },
          ],
        },
      );

      expect(result.documents.single.mimeType, isNull);
    });
  });

  group('MethodChannelSafDocumentLister.listAudioDocuments', () {
    test('reports SAF traversal unavailable off Android', () async {
      // The unit-test host is never Android, so the channel is never reached and
      // the caller falls back to the filesystem path scanner.
      const lister = MethodChannelSafDocumentLister();

      await expectLater(
        lister.listAudioDocuments('content://x/tree/y'),
        throwsA(isA<SafUnsupportedException>()),
      );
    });
  });
}
