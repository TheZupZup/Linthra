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

    test('parses the folders-visited count when reported', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{'uri': 'content://doc/1', 'name': 'One.mp3'},
          ],
          'filesVisited': 1,
          'foldersVisited': 3,
          'readFailures': 0,
        },
      );

      expect(result.foldersVisited, 3);
    });

    test('defaults folders-visited to 0 for an older native build', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{'uri': 'content://doc/1', 'name': 'One.mp3'},
          ],
        },
      );

      expect(result.foldersVisited, 0);
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

    test('attaches the native tags to the parsed document', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/1',
              'name': 'One.mp3',
              'mime': 'audio/mpeg',
              'title': 'Holocene',
              'artist': 'Bon Iver',
              'albumArtist': 'Bon Iver',
              'album': 'Bon Iver',
              'track': '3/10',
              'durationMs': '337000',
            },
          ],
        },
      );

      final metadata = result.documents.single.metadata!;
      expect(metadata.title, 'Holocene');
      expect(metadata.artist, 'Bon Iver');
      expect(metadata.albumArtist, 'Bon Iver');
      expect(metadata.album, 'Bon Iver');
      expect(metadata.trackNumber, 3);
      expect(metadata.duration, const Duration(milliseconds: 337000));
    });

    test('a document with no tag fields has null metadata', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{'uri': 'content://doc/1', 'name': 'One.mp3'},
          ],
        },
      );

      expect(result.documents.single.metadata, isNull);
    });

    test('attaches the native cover-art URI to the parsed document', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/1',
              'name': 'One.mp3',
              'artworkUri': 'file:///cache/linthra_local_artwork/abc.img',
            },
          ],
        },
      );

      expect(
        result.documents.single.metadata!.artworkUri,
        Uri.parse('file:///cache/linthra_local_artwork/abc.img'),
      );
    });
  });

  group('MethodChannelSafDocumentLister.parseMetadata', () {
    test('null for an entry with no tag fields', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'uri': 'content://doc/1', 'name': 'One.mp3'},
        ),
        isNull,
      );
    });

    test('drops blank text fields to null', () {
      final metadata = MethodChannelSafDocumentLister.parseMetadata(
        <Object?, Object?>{'title': '  ', 'artist': '', 'album': 'Real'},
      );
      expect(metadata, isNotNull);
      expect(metadata!.title, isNull);
      expect(metadata.artist, isNull);
      expect(metadata.album, 'Real');
    });

    test('parses a plain or "n/m" track number, ignoring non-positive', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'track': '5'},
        )!
            .trackNumber,
        5,
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'track': '3/12'},
        )!
            .trackNumber,
        3,
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'track': '0'},
        ),
        isNull,
      );
    });

    test('parses durationMs sent as an int or a numeric string', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'durationMs': 200000},
        )!
            .duration,
        const Duration(milliseconds: 200000),
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'durationMs': '200000'},
        )!
            .duration,
        const Duration(milliseconds: 200000),
      );
      // Zero/garbage duration is unknown, not a real value.
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'durationMs': '0'},
        ),
        isNull,
      );
    });

    test('parses a file:// cover-art URI', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'artworkUri': 'file:///cache/art/abc.img'},
        )!
            .artworkUri,
        Uri.parse('file:///cache/art/abc.img'),
      );
    });

    test('embedded art alone (no text tags) still yields metadata', () {
      // An art-only file must not drop to null metadata, or the cover is lost.
      final metadata = MethodChannelSafDocumentLister.parseMetadata(
        <Object?, Object?>{'artworkUri': 'file:///cache/art/abc.img'},
      );
      expect(metadata, isNotNull);
      expect(metadata!.title, isNull);
      expect(metadata.artworkUri, Uri.parse('file:///cache/art/abc.img'));
    });

    test('drops a blank or non-string cover-art value to null', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'artworkUri': '  '},
        ),
        isNull,
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'artworkUri': 42},
        ),
        isNull,
      );
      // A real tag alongside a blank artwork keeps the tag, drops the artwork.
      final metadata = MethodChannelSafDocumentLister.parseMetadata(
        <Object?, Object?>{'album': 'Real', 'artworkUri': ''},
      );
      expect(metadata!.album, 'Real');
      expect(metadata.artworkUri, isNull);
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
