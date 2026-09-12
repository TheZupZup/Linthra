import 'dart:io';

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

    test('attaches the disc number to the parsed document', () {
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/1',
              'name': 'One.mp3',
              'album': 'Sign O\' the Times',
              'track': '1/8',
              'disc': '2/2',
            },
          ],
        },
      );

      expect(result.documents.single.metadata!.discNumber, 2);
    });

    test('a multi-disc album\'s documents carry enough to order by disc', () {
      // The disc number only has to survive the native reply for a multi-disc
      // album to be orderable; grouping itself is not this layer's job (#85).
      final result = MethodChannelSafDocumentLister.parseScanResult(
        <Object?, Object?>{
          'documents': <Object?>[
            <Object?, Object?>{
              'uri': 'content://doc/d2t1',
              'name': 'Disc2-01.mp3',
              'title': 'Disc two, first',
              'disc': '2/2',
              'track': '1/2',
            },
            <Object?, Object?>{
              'uri': 'content://doc/d1t2',
              'name': 'Disc1-02.mp3',
              'title': 'Disc one, second',
              'disc': '1/2',
              'track': '2/2',
            },
            <Object?, Object?>{
              'uri': 'content://doc/d1t1',
              'name': 'Disc1-01.mp3',
              'title': 'Disc one, first',
              'disc': '01/02',
              'track': '1/2',
            },
          ],
        },
      );

      final ordered = result.documents.toList()
        ..sort((a, b) {
          final int disc = a.metadata!.discNumber!.compareTo(
            b.metadata!.discNumber!,
          );
          return disc != 0
              ? disc
              : a.metadata!.trackNumber!.compareTo(b.metadata!.trackNumber!);
        });

      expect(
        ordered.map((d) => d.metadata!.title).toList(),
        <String>['Disc one, first', 'Disc one, second', 'Disc two, first'],
      );
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

    test('parses a plain, "disc/total" or zero-padded disc number', () {
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'disc': '1'},
        )!
            .discNumber,
        1,
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'disc': '1/2'},
        )!
            .discNumber,
        1,
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'disc': '02'},
        )!
            .discNumber,
        2,
      );
      // Surrounding whitespace from a sloppy tagger is still a real value.
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'disc': ' 3/4 '},
        )!
            .discNumber,
        3,
      );
      // Tolerated even though the native side sends strings, like `track`.
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'disc': 2},
        )!
            .discNumber,
        2,
      );
    });

    test('a file with no disc tag has no disc number', () {
      // The common case: a single-disc album, which tags usually leave out.
      final metadata = MethodChannelSafDocumentLister.parseMetadata(
        <Object?, Object?>{'title': 'Only a title', 'track': '4'},
      );

      expect(metadata!.title, 'Only a title');
      expect(metadata.trackNumber, 4);
      expect(metadata.discNumber, isNull);
    });

    test('drops a malformed disc number to null without throwing', () {
      for (final Object? value in <Object?>[
        '', // present but blank
        '   ',
        'Disc', // no number at all
        'Disc 2', // a number, but not where a disc tag puts it
        '/2', // only the total survived
        '-1', // a leading sign is not a disc number
        'one',
        '99999999999999999999999999', // wider than an int
        42.5, // not a string or an int
        <String>['1'],
      ]) {
        final metadata = MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{'album': 'Real', 'disc': value},
        );

        expect(metadata!.album, 'Real', reason: 'disc: $value');
        expect(metadata.discNumber, isNull, reason: 'disc: $value');
      }
    });

    test('drops a zero or negative disc number to null', () {
      // A disc number is 1-based, so "0" is no more usable than a missing tag.
      for (final Object? value in <Object?>['0', '0/2', '00', 0, -1]) {
        expect(
          MethodChannelSafDocumentLister.parseMetadata(
            <Object?, Object?>{'disc': value},
          ),
          isNull,
          reason: 'disc: $value',
        );
      }
    });

    test('a disc tag alone still yields metadata', () {
      // Same reason art-only files do: dropping to null would lose the value.
      final metadata = MethodChannelSafDocumentLister.parseMetadata(
        <Object?, Object?>{'disc': '2/2'},
      );

      expect(metadata, isNotNull);
      expect(metadata!.discNumber, 2);
      expect(metadata.title, isNull);
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

  group('SAF disc tag wiring', () {
    test('the native walk sends the disc tag under the key this parser reads',
        () {
      // The one seam the pure parsing tests above cannot see: the Kotlin walk
      // puts the disc tag in its reply under a string key, and parseMetadata
      // reads it back by that same string. A typo on either side would drop
      // every disc number with all the other tests still green.
      final File scanner = File(
        'android/app/src/main/kotlin/io/github/thezupzup/linthra/'
        'SafDocumentScanner.kt',
      );
      expect(
        scanner.existsSync(),
        isTrue,
        reason: 'SafDocumentScanner.kt must remain available for this guard',
      );
      final String source = scanner.readAsStringSync();

      final RegExpMatch? read = RegExp(
        r'"(\w+)" to retriever\.extractMetadata\(\s*'
        r'MediaMetadataRetriever\.METADATA_KEY_DISC_NUMBER',
      ).firstMatch(source);
      expect(
        read,
        isNotNull,
        reason: 'the SAF walk must read the disc tag from the retriever',
      );

      final String key = read!.group(1)!;
      expect(
        source,
        contains('"$key" to metadata["$key"]'),
        reason: "the disc tag must be forwarded in the walk's reply",
      );
      expect(
        MethodChannelSafDocumentLister.parseMetadata(
          <Object?, Object?>{key: '2/2'},
        )!
            .discNumber,
        2,
      );
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
