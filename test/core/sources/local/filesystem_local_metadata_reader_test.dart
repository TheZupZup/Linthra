import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';
import 'package:linthra/core/sources/local/mp4_box_guard.dart';

import 'audio_tag_fixtures.dart';

void main() {
  late FilesystemLocalMetadataReader reader;
  late Directory root;
  late Directory artworkDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linthra_tag_reader_');
    artworkDir = await Directory.systemTemp.createTemp('linthra_tag_artwork_');
    reader = FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(directory: () async => artworkDir),
    );
  });

  tearDown(() async {
    await reader.close();
    if (root.existsSync()) await root.delete(recursive: true);
    if (artworkDir.existsSync()) await artworkDir.delete(recursive: true);
  });

  /// Writes [bytes] as [name] under the temp root and returns its path.
  String write(String name, Uint8List bytes) {
    final File file = File('${root.path}/$name');
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  }

  /// A real, decodable solid-colour PNG of [width]x[height] — enough for the
  /// cache's decode/bound step to see an actual image rather than opaque
  /// bytes, without committing a binary fixture to the repo.
  Future<Uint8List> solidPng(int width, int height) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF336699),
    );
    final ui.Image image = await recorder.endRecording().toImage(width, height);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// The pixel dimensions of a PNG produced by [solidPng] (or any other real
  /// image), read back through the same decode seam the cache uses — so a test
  /// asserting a resize actually asserts the file on disk got smaller.
  Future<ui.Size> decodedSize(File file) async {
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
      buffer,
    );
    final ui.Size size =
        ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    descriptor.dispose();
    buffer.dispose();
    return size;
  }

  group('tagged files', () {
    test('an ID3v2 MP3 gives its title, both artists, album and track', () {
      final String path = write(
        'song.mp3',
        AudioTagFixtures.mp3(
          title: 'Blue Monday',
          artist: 'New Order',
          albumArtist: 'New Order',
          album: 'Power, Corruption & Lies',
          track: '3/8',
        ),
      );

      return reader.readFromPath(path).then((LocalAudioMetadata? metadata) {
        expect(metadata, isNotNull);
        expect(metadata!.title, 'Blue Monday');
        expect(metadata.artist, 'New Order');
        expect(metadata.albumArtist, 'New Order');
        expect(metadata.album, 'Power, Corruption & Lies');
        expect(metadata.trackNumber, 3);
      });
    });

    test('an MP3 keeps the track artist and the album artist apart', () async {
      // The compilation case, and the reason the reader parses ID3 rather than
      // taking the package's merged `artist`: TPE1 is who played this track,
      // TPE2 is who the album belongs to, and collapsing them splits an album.
      final String path = write(
        'compilation.mp3',
        AudioTagFixtures.mp3(
          title: 'Guest Spot',
          artist: 'Featured Guest',
          albumArtist: 'Various Artists',
          album: 'A Compilation',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.artist, 'Featured Guest');
      expect(metadata.albumArtist, 'Various Artists');
    });

    test('a FLAC gives its Vorbis comments and a real duration', () async {
      final String path = write(
        'song.flac',
        AudioTagFixtures.flac(
          title: 'Teardrop',
          artist: 'Massive Attack',
          album: 'Mezzanine',
          track: '2',
          sampleRate: 44100,
          totalSamples: 44100 * 5,
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Teardrop');
      expect(metadata.artist, 'Massive Attack');
      expect(metadata.album, 'Mezzanine');
      expect(metadata.trackNumber, 2);
      // Duration comes from STREAMINFO, not from the filename — the one thing a
      // filename can never supply.
      expect(metadata.duration, const Duration(seconds: 5));
    });

    test('a WAV gives its RIFF INFO tags', () async {
      final String path = write(
        'song.wav',
        AudioTagFixtures.wav(
          title: 'Sample',
          artist: 'Field Recordist',
          album: 'Recordings',
          track: '7',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Sample');
      expect(metadata.artist, 'Field Recordist');
      expect(metadata.album, 'Recordings');
      expect(metadata.trackNumber, 7);
    });

    test('an M4A gives its iTunes atoms and a real duration', () async {
      final String path = write(
        'song.m4a',
        AudioTagFixtures.m4a(
          title: 'Take Five',
          artist: 'The Dave Brubeck Quartet',
          album: 'Time Out',
          track: 3,
          duration: const Duration(seconds: 5),
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Take Five');
      expect(metadata.artist, 'The Dave Brubeck Quartet');
      expect(metadata.album, 'Time Out');
      expect(metadata.trackNumber, 3);
      expect(metadata.duration, const Duration(seconds: 5));
    });

    test('an M4A whose meta box has no version/flags word still reads',
        () async {
      // The QuickTime layout, children straight after the header. The parser
      // probes for it; the box check in front of the parser has to follow the
      // same probe or it would refuse these files.
      final String path = write(
        'quicktime.m4a',
        AudioTagFixtures.m4a(title: 'Blue in Green', metaVersionFlags: false),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Blue in Green');
    });

    test('non-ASCII tags survive the round trip', () async {
      final String path = write(
        'accents.flac',
        AudioTagFixtures.flac(
          title: 'Où est la mer',
          artist: 'Éliane Radigue',
          album: 'Trilogie de la Mort',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Où est la mer');
      expect(metadata.artist, 'Éliane Radigue');
    });
  });

  group('files that carry nothing usable', () {
    test('an untagged file reads as no metadata rather than failing', () async {
      final String path = write('bare.flac', AudioTagFixtures.flac());

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      // A FLAC with no comments still has a duration, so this is not null — but
      // nothing that would override the filename.
      expect(metadata?.title, isNull);
      expect(metadata?.artist, isNull);
      expect(metadata?.album, isNull);
    });

    test('blank tags fall back instead of showing an empty title', () async {
      final String path = write(
        'blank.mp3',
        AudioTagFixtures.mp3(title: '   ', artist: '', album: 'Real Album'),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, isNull);
      expect(metadata.artist, isNull);
      expect(metadata.album, 'Real Album');
    });

    test('a truncated file reads as null, not an exception', () async {
      final Uint8List full = AudioTagFixtures.flac(title: 'Cut Short');
      final String path = write(
        'truncated.flac',
        Uint8List.sublistView(full, 0, full.length ~/ 2),
      );

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('a file that is not audio at all reads as null', () async {
      final String path = write(
        'notes.mp3',
        Uint8List.fromList('this is plain text, not an MP3'.codeUnits),
      );

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('an empty file reads as null', () async {
      final String path = write('empty.flac', Uint8List(0));

      await expectLater(reader.readFromPath(path), completion(isNull));
    });

    test('a missing file reads as null', () async {
      await expectLater(
        reader.readFromPath('${root.path}/never-existed.mp3'),
        completion(isNull),
      );
    });

    test('a directory named like a track reads as null', () async {
      final Directory directory = Directory('${root.path}/album.mp3');
      directory.createSync();

      await expectLater(
          reader.readFromPath(directory.path), completion(isNull));
    });
  });

  // #743: a scan reads a file that could not be read this time again on the
  // next scan, but settles one that was read and holds no tags. Both used to
  // come back as the same null.
  group('a failed read is told apart from a file with no tags (#743)', () {
    test('an untagged file was read: nothing in it, but not a failure',
        () async {
      final String path = write('bare.flac', AudioTagFixtures.flac());

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.failed, isFalse);
      expect(read.metadata?.title, isNull);
    });

    test('blank tags were read too', () async {
      final String path =
          write('blank.mp3', AudioTagFixtures.mp3(title: ' ', artist: ''));

      expect((await reader.readWithOutcome(path)).failed, isFalse);
    });

    test('a tagged file was read, and readFromPath gives the same tags',
        () async {
      final String path =
          write('tagged.flac', AudioTagFixtures.flac(title: 'Tagged'));

      final LocalMetadataRead read = await reader.readWithOutcome(path);

      expect(read.failed, isFalse);
      expect(read.metadata!.title, 'Tagged');
      expect((await reader.readFromPath(path))!.title, 'Tagged');
    });

    test('a file gone by the time it is read is a failed read', () async {
      final LocalMetadataRead read =
          await reader.readWithOutcome('${root.path}/gone.mp3');

      expect(read.failed, isTrue);
      expect(read.metadata, isNull);
    });

    test('a parse stopped at its time limit is a failed read', () async {
      final String path = write('unfinished.m4a', _unfinishedEncode());

      final Object? reply = await _onOwnIsolate(
        _readOutcomeUnguardedEntry,
        (path, artworkDir.path),
      );

      expect(reply, isTrue);
    });
  });

  group('MP4 box sizes the tag parser would loop on', () {
    // The package's MP4 parser moves from box to box by each box's declared
    // size and never checks that the size moves it forward. A size of 0 (legal,
    // "runs to the end of the file", and what an interrupted ffmpeg encode
    // leaves in `mdat`) sends it back to the same header forever, synchronously
    // and without throwing, which froze a desktop scan at 100% CPU. Other bad
    // sizes leave it reading headers out of the middle of other data, where a
    // zero size is one unlucky byte run away.
    //
    // So these read on their own isolate (see [_readOnOwnIsolate]): a loop on
    // the test's isolate would never let a timeout fire and would hang the
    // whole run. Each file here must come back promptly, and as "no tags"
    // (null): the track still shows, from its filename.
    Future<LocalAudioMetadata?> readIsolated(Uint8List bytes) =>
        _readOnOwnIsolate(write('broken.m4a', bytes), artworkDir.path);

    test('a file that turns into a loop after it was checked is stopped',
        () async {
      // Still being written: a good M4A when the scan stats it, then, in the
      // await before the parse, it gains the size-0 box an unfinished encode
      // has. The guard runs right before the parse, where a loop can still be
      // stopped, so it sees the file as it is by then.
      final String path = write(
        'growing.m4a',
        AudioTagFixtures.m4a(
          title: 'Not yet',
          artist: 'Still Encoding',
          album: 'Half Done',
          track: 1,
          duration: const Duration(seconds: 5),
        ),
      );
      final Uint8List looping = Uint8List.fromList(<int>[
        ...AudioTagFixtures.mp4Ftyp(),
        ...AudioTagFixtures.mp4Box('free'),
        ...AudioTagFixtures.mp4BoxHeader(0, 'mdat'),
        ...Uint8List(4096),
      ]);

      final Object? reply = await _onOwnIsolate(
        _readWhileRewritingEntry,
        (path, artworkDir.path, looping),
      );

      expect(reply, isNull, reason: 'no tags, and the scan goes on');
    });

    test('a file that only becomes an MP4 after it was stat-ed is stopped too',
        () async {
      // Empty when the scan reaches it (not an MP4 at all yet), then the
      // writer puts down an `ftyp` and an unfinished `mdat`. Whatever it was
      // a moment ago, the parser is picked by what it is now.
      final String path = write('arriving.m4a', Uint8List(0));
      final Uint8List looping = Uint8List.fromList(<int>[
        ...AudioTagFixtures.mp4Ftyp(),
        ...AudioTagFixtures.mp4Box('free'),
        ...AudioTagFixtures.mp4BoxHeader(0, 'mdat'),
        ...Uint8List(4096),
      ]);

      final Object? reply = await _onOwnIsolate(
        _readWhileRewritingEntry,
        (path, artworkDir.path, looping),
      );

      expect(reply, isNull);
    });

    test('a parse that loops anyway is stopped, not waited on forever',
        () async {
      // The guard is the fast refusal; the limit is the guarantee. With the
      // guard out of the way, a looping file reaches the parser, and the
      // read still comes back, as no tags.
      final String path = write(
        'unfinished.m4a',
        Uint8List.fromList(<int>[
          ...AudioTagFixtures.mp4Ftyp(),
          ...AudioTagFixtures.mp4Box('free'),
          ...AudioTagFixtures.mp4BoxHeader(0, 'mdat'),
          ...Uint8List(4096),
        ]),
      );

      final Object? reply = await _onOwnIsolate(
        _readUnguardedEntry,
        (path, artworkDir.path),
      );

      expect(reply, isNull);
    });

    test('an unfinished encode (mdat still sized 0) is refused, not looped on',
        () async {
      // What ffmpeg leaves when it is stopped mid-write: `mdat` keeps the 0 it
      // writes as a placeholder, and `moov` (written at the end) never comes.
      final Uint8List bytes = Uint8List.fromList(<int>[
        ...AudioTagFixtures.mp4Ftyp(),
        ...AudioTagFixtures.mp4Box('free'),
        ...AudioTagFixtures.mp4BoxHeader(0, 'mdat'),
        ...Uint8List(4096),
      ]);

      expect(await readIsolated(bytes), isNull);
    });

    test('a last box sized 0 after good tags is refused, not looped on',
        () async {
      // Legal ISO BMFF, and the tags come first, but the parser reads on to
      // the end of the file and loops there all the same.
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Never Finishes',
        trailing: <int>[
          ...AudioTagFixtures.mp4BoxHeader(0, 'free'),
          ...Uint8List(64),
        ],
      );

      expect(await readIsolated(bytes), isNull);
    });

    for (final String container in <String>['moov', 'udta', 'meta', 'ilst']) {
      test('a box sized 0 inside $container is refused, not looped on',
          () async {
        final Uint8List bytes = AudioTagFixtures.m4a(
          title: 'Nested',
          appendTo: <String, List<int>>{
            container: AudioTagFixtures.mp4BoxHeader(0, 'free'),
          },
        );

        expect(await readIsolated(bytes), isNull);
      });
    }

    test('a 64-bit box size (size field 1) is refused', () async {
      // Size 1 means "the real size is the 64-bit number after the type", how
      // an `mdat` over 4 GiB is written. The parser has no such case: it takes
      // the 1 at face value, steps back seven bytes, and reads box headers out
      // of the middle of this one. Where those land depends on the media bytes.
      // Here the first misread (bytes 1..4 of the header, `00 00 01 6D`, taken
      // as a size) lands on four zero bytes, as a run of silence can, and the
      // parser re-reads that header forever.
      const int landsAt = 1 + 0x16D;
      final Uint8List media = Uint8List(512);
      media.setRange(landsAt - 16, landsAt - 16 + 8, <int>[
        ...<int>[0, 0, 0, 0],
        ...'free'.codeUnits,
      ]);
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Over Four Gigabytes',
        trailing: <int>[
          ...AudioTagFixtures.mp4BoxHeader(1, 'mdat'),
          ...<int>[0, 0, 0, 0], // 64-bit size, high word
          ...<int>[0, 0, 0x02, 0x10], // low word: 16 + 512
          ...media,
        ],
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('a size-1 box with no 64-bit size after it is refused', () async {
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Cut Off',
        trailing: AudioTagFixtures.mp4BoxHeader(1, 'mdat'),
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('a box sized smaller than its own header is refused', () async {
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Three Bytes',
        appendTo: <String, List<int>>{
          'ilst': AudioTagFixtures.mp4BoxHeader(3, 'aART'),
        },
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('a box running past the end of the file is refused', () async {
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Truncated',
        trailing: <int>[
          ...AudioTagFixtures.mp4BoxHeader(1 << 20, 'free'),
          ...Uint8List(32),
        ],
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('a box running past the end of its parent is refused', () async {
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Overrun',
        appendTo: <String, List<int>>{
          'udta': AudioTagFixtures.mp4BoxHeader(64, 'free'),
        },
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('a QuickTime udta ending in a 32-bit zero terminator is refused',
        () async {
      // QuickTime allows `udta` to end with four zero bytes. The parser reads
      // them plus the next box's size field as one more header, a box of size
      // 0, and loops on it.
      final Uint8List bytes = AudioTagFixtures.m4a(
        title: 'Terminated',
        appendTo: <String, List<int>>{
          'udta': <int>[0, 0, 0, 0],
        },
      );

      expect(await readIsolated(bytes), isNull);
    });

    test('an MP4 with an ID3v1 tag on the end still reads, as the MP3 parser',
        () async {
      // The package picks its parser by content, and an ID3v1 trailer wins
      // over `ftyp`. That file never reaches the MP4 parser, so the box check
      // must not stand in its way (its trailer is not a box and would fail).
      final Uint8List bytes = Uint8List.fromList(<int>[
        ...AudioTagFixtures.m4a(title: 'From MP4 atoms'),
        ...AudioTagFixtures.id3v1(title: 'From ID3v1'),
      ]);

      final LocalAudioMetadata? metadata = await readIsolated(bytes);

      expect(metadata?.title, 'From ID3v1');
    });
  });

  group('what the library actually shows', () {
    test('a tagged file beats the filename fallback', () async {
      final String path = write(
        '01 - untitled.flac',
        AudioTagFixtures.flac(
          title: 'The Real Title',
          artist: 'The Real Artist',
          album: 'The Real Album',
          track: '4',
        ),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'The Real Title');
      expect(track.artistName, 'The Real Artist');
      expect(track.albumName, 'The Real Album');
      expect(track.trackNumber, 4);
      expect(track.duration, greaterThan(Duration.zero));
    });

    test('an untagged file still appears, from its filename', () async {
      final String path = write(
        '03 - Filename Title.flac',
        AudioTagFixtures.flac(),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'Filename Title');
      expect(track.trackNumber, 3);
    });

    test('an unreadable file is still a track, never a dropped one', () async {
      final String path = write(
        '05 - Broken.mp3',
        Uint8List.fromList('not really an MP3'.codeUnits),
      );

      final Track track = LocalTrackMapper.fromPath(
        path,
        metadata: await reader.readFromPath(path),
        scanRoot: root.path,
      );

      expect(track.title, 'Broken');
      expect(track.trackNumber, 5);
    });
  });

  group('Vorbis merges ARTIST and ALBUMARTIST', () {
    // The package appends both tags to one list, so the field names are gone by
    // the time this reader sees them. Taking the first entry makes the answer
    // depend on the order the tagger wrote them in, which Vorbis does not
    // constrain. These fix the behaviour to the values, not the order.

    test('a normal album answers exactly, both tags naming the same artist',
        () async {
      for (final bool albumArtistFirst in <bool>[false, true]) {
        final String path = write(
          'a\$albumArtistFirst.flac',
          AudioTagFixtures.flac(
            title: 'Comfortably Numb',
            artist: 'Pink Floyd',
            albumArtist: 'Pink Floyd',
            album: 'The Wall',
            albumArtistFirst: albumArtistFirst,
          ),
        );

        final LocalAudioMetadata? metadata = await reader.readFromPath(path);

        expect(metadata?.artist, 'Pink Floyd');
      }
    });

    test('one tag alone is unambiguous whichever it is', () async {
      final String path = write(
        'artist-only.flac',
        AudioTagFixtures.flac(title: 'Song', artist: 'Solo Act'),
      );

      expect((await reader.readFromPath(path))?.artist, 'Solo Act');
    });

    test('repeated ARTIST fields are a collaboration, not an ambiguity',
        () async {
      // The spec's way to credit two performers. The merged list looks exactly
      // like ARTIST + ALBUMARTIST, which is why the field names have to be read
      // rather than inferred.
      final String path = write(
        'collab.flac',
        AudioTagFixtures.flac(
          title: 'Under Pressure',
          artist: 'Queen',
          artists: <String>['David Bowie'],
          album: 'Hot Space',
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata?.artist, 'Queen, David Bowie');
      expect(metadata?.albumArtist, isNull);
    });

    test('a jointly credited album keeps every album artist', () async {
      // Repeating the field is how Vorbis writes a joint credit, for an album
      // as much as for a track. Keeping only the first would group the album
      // under half its name.
      final String path = write(
        'joint.flac',
        AudioTagFixtures.flacWithRawComments(<String>[
          'TITLE=Track',
          'ARTIST=Performer',
          'ALBUMARTIST=Sleaford Mods',
          'ALBUMARTIST=Amy Taylor',
        ]),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata?.albumArtist, 'Sleaford Mods, Amy Taylor');
      expect(metadata?.artist, 'Performer');
    });

    test('a compilation keeps the performer and the album artist apart',
        () async {
      // Reading the field names means this no longer has to choose: the
      // performer stays the performer and the album artist groups the album.
      for (final bool albumArtistFirst in <bool>[false, true]) {
        final String path = write(
          'comp\$albumArtistFirst.flac',
          AudioTagFixtures.flac(
            title: 'Song',
            artist: 'Featured Guest',
            albumArtist: 'Various Artists',
            album: 'Comp',
            albumArtistFirst: albumArtistFirst,
          ),
        );

        final LocalAudioMetadata? metadata = await reader.readFromPath(path);

        expect(metadata?.artist, 'Featured Guest');
        expect(metadata?.albumArtist, 'Various Artists');
      }
    });
  });

  group('staying off the UI thread', () {
    // The tag parse itself is synchronous. If readFromPath did all its work
    // before returning, its Future would already be complete, and awaiting a
    // complete Future only schedules a microtask. The microtask queue drains
    // fully before the event loop gets another turn, so a scan of a whole
    // library would run as one unbroken chain: no frame rendered and no input
    // handled from the first file to the last. Nothing about that shows up in
    // a normal test, which is why these two assert it directly.

    test('one read reaches the event loop, not just the microtask queue',
        () async {
      final String path =
          write('One.flac', AudioTagFixtures.flac(title: 'One'));
      var reachedEventLoop = false;
      // Timer fires from the event loop; a microtask-only chain never lets it.
      Timer.run(() => reachedEventLoop = true);

      await reader.readFromPath(path);

      expect(
        reachedEventLoop,
        isTrue,
        reason: 'readFromPath returned without ever yielding to the event '
            'loop, so a scan would freeze the UI for its whole duration',
      );
    });

    test('a run of reads keeps letting the event loop in', () async {
      final List<String> paths = <String>[
        for (int i = 0; i < 20; i++)
          write('Track $i.flac', AudioTagFixtures.flac(title: 'T$i')),
      ];
      var ticks = 0;
      final Timer timer =
          Timer.periodic(const Duration(microseconds: 100), (_) => ticks++);
      addTearDown(timer.cancel);

      for (final String path in paths) {
        await reader.readFromPath(path);
      }

      // Not one tick per file exactly (timers are not that precise), but a
      // starved event loop scores zero, which is the failure being caught.
      expect(
        ticks,
        greaterThan(0),
        reason: 'the event loop never ran during a 20-file pass',
      );
    });

    test('a missing file still yields before giving up', () async {
      // The early return is the one path that skips the parse; it must not
      // become the fast synchronous path that starves everything after it.
      var reachedEventLoop = false;
      Timer.run(() => reachedEventLoop = true);

      expect(await reader.readFromPath('${root.path}/nope.flac'), isNull);
      expect(reachedEventLoop, isTrue);
    });
  });

  group('one parser isolate for a whole scan', () {
    // Parses run on an isolate of their own, so a parser loop can be
    // stopped. Starting one per file would make a first scan of a big
    // library pay isolate startup and teardown thousands of times, so one is
    // kept from file to file and replaced only when it has to be.

    test('file after file is parsed on the same isolate', () async {
      final List<String> paths = <String>[
        write('a.mp3', AudioTagFixtures.mp3(title: 'MP3')),
        write('b.flac', AudioTagFixtures.flac(title: 'FLAC')),
        write(
          'c.m4a',
          AudioTagFixtures.m4a(
            title: 'M4A',
            artist: 'Artist',
            album: 'Album',
            track: 1,
            duration: const Duration(seconds: 5),
          ),
        ),
        write('d.wav', AudioTagFixtures.wav(title: 'WAV')),
      ];

      final List<String?> titles = <String?>[
        for (final String path in paths)
          (await reader.readFromPath(path))?.title,
      ];

      expect(titles, <String>['MP3', 'FLAC', 'M4A', 'WAV']);
      expect(reader.parsersStarted, 1);
    });

    test('reads asked for at once take turns on it, all answered', () async {
      final List<String> paths = <String>[
        for (int i = 0; i < 8; i++)
          write('Track $i.flac', AudioTagFixtures.flac(title: 'T$i')),
      ];

      final List<LocalAudioMetadata?> results = await Future.wait(
        <Future<LocalAudioMetadata?>>[
          for (final String path in paths) reader.readFromPath(path),
        ],
      );

      expect(
        <String?>[for (final LocalAudioMetadata? r in results) r?.title],
        <String>[for (int i = 0; i < 8; i++) 'T$i'],
      );
      expect(reader.parsersStarted, 1);
    });

    test('a covered file still gets its cover from the shared isolate',
        () async {
      // The cover is the one thing of any size that crosses back.
      final List<String> paths = <String>[
        for (int i = 0; i < 3; i++)
          write(
            'cover$i.mp3',
            AudioTagFixtures.mp3(
              title: 'Song $i',
              coverImage: await solidPng(40 + i, 20),
            ),
          ),
      ];

      for (int i = 0; i < paths.length; i++) {
        final LocalAudioMetadata? metadata =
            await reader.readFromPath(paths[i]);
        final ui.Size size =
            await decodedSize(File(metadata!.artworkUri!.toFilePath()));
        expect(size, ui.Size(40.0 + i, 20));
      }
      expect(reader.parsersStarted, 1);
    });

    test('after a parse is stopped, the next file gets a new isolate',
        () async {
      final String looping = write('unfinished.m4a', _unfinishedEncode());
      final String good =
          write('after.flac', AudioTagFixtures.flac(title: 'After'));

      final Object? reply = await _onOwnIsolate(
        _readUnguardedInOrderEntry,
        (<String>[looping, good], artworkDir.path),
      );

      final (List<Object?> titles, int started) =
          reply! as (List<Object?>, int);
      expect(titles, <String?>[null, 'After']);
      expect(started, 2, reason: 'the stopped isolate was replaced');
    });

    test('a file asked for while another loops still gets its tags', () async {
      // Each parse's limit counts its own time on the isolate, not time
      // queued behind a parse that is about to be stopped.
      final String looping = write('unfinished.m4a', _unfinishedEncode());
      final String good =
          write('after.flac', AudioTagFixtures.flac(title: 'After'));

      final Object? reply = await _onOwnIsolate(
        _readUnguardedAtOnceEntry,
        (<String>[looping, good], artworkDir.path),
      );

      final (List<Object?> titles, int _) = reply! as (List<Object?>, int);
      expect(titles, <String?>[null, 'After']);
    });

    test('an isolate that dies under a parse is replaced at once', () async {
      // Answered when the isolate goes, not when the limit runs out.
      const Duration limit = Duration(seconds: 20);
      final FilesystemLocalMetadataReader dying = FilesystemLocalMetadataReader(
        artworkCache: LocalArtworkCache(directory: () async => artworkDir),
        parseLimit: limit,
        guard: _exitOnDiesFiles,
      );
      addTearDown(dying.close);
      final String dies =
          write('dies.mp3', AudioTagFixtures.mp3(title: 'Gone'));
      final String good =
          write('next.mp3', AudioTagFixtures.mp3(title: 'Next'));

      final Stopwatch stopwatch = Stopwatch()..start();
      expect(await dying.readFromPath(dies), isNull);
      expect(stopwatch.elapsed, lessThan(limit ~/ 2));
      expect((await dying.readFromPath(good))?.title, 'Next');
      expect(dying.parsersStarted, 2);
    });

    test('close stops it, and a read after that starts another', () async {
      final String path =
          write('One.flac', AudioTagFixtures.flac(title: 'One'));

      expect((await reader.readFromPath(path))?.title, 'One');
      await reader.close();
      expect((await reader.readFromPath(path))?.title, 'One');

      expect(reader.parsersStarted, 2);
    });
  });

  group('embedded artwork (#408)', () {
    test('an MP3 cover is extracted and cached as a file: URI', () async {
      final Uint8List cover = await solidPng(64, 64);
      final String path = write(
        'cover.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: cover),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.artworkUri, isNotNull);
      expect(metadata.artworkUri!.isScheme('file'), isTrue);
      final File cached = File(metadata.artworkUri!.toFilePath());
      expect(cached.existsSync(), isTrue);
      expect(cached.lengthSync(), greaterThan(0));
      // Lives under Linthra's own cache dir, not wherever the source file is.
      expect(cached.path.startsWith(artworkDir.path), isTrue);
    });

    test('a FLAC PICTURE block is extracted the same way', () async {
      final Uint8List cover = await solidPng(32, 32);
      final String path = write(
        'cover.flac',
        AudioTagFixtures.flac(title: 'Song', coverImage: cover),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.artworkUri, isNotNull);
      expect(File(metadata.artworkUri!.toFilePath()).existsSync(), isTrue);
    });

    test('a file with no embedded picture has no artwork', () async {
      final String path = write(
        'plain.mp3',
        AudioTagFixtures.mp3(title: 'Song'),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.artworkUri, isNull);
    });

    test('a picture alone (no text tags) is still reported', () async {
      final Uint8List cover = await solidPng(16, 16);
      final String path = write(
        'artonly.mp3',
        AudioTagFixtures.mp3(coverImage: cover),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata, isNotNull);
      expect(metadata!.title, isNull);
      expect(metadata.artworkUri, isNotNull);
    });

    test('corrupt embedded picture bytes yield no artwork, tags unaffected',
        () async {
      final String path = write(
        'corrupt.mp3',
        AudioTagFixtures.mp3(
          title: 'Still Readable',
          coverImage: Uint8List.fromList('not an image'.codeUnits),
        ),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      expect(metadata!.title, 'Still Readable');
      expect(metadata.artworkUri, isNull);
    });

    test('a restart-equivalent re-read reuses the cached cover', () async {
      final Uint8List cover = await solidPng(64, 64);
      final String path = write(
        'cached.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: cover),
      );

      final Uri first = (await reader.readFromPath(path))!.artworkUri!;
      final File cachedFile = File(first.toFilePath());
      final DateTime writtenAt = cachedFile.lastModifiedSync();

      // A fresh reader instance stands in for a new app launch: nothing is
      // kept in memory between them, only the cache on disk.
      final FilesystemLocalMetadataReader restarted =
          FilesystemLocalMetadataReader(
        artworkCache: LocalArtworkCache(directory: () async => artworkDir),
      );
      addTearDown(restarted.close);
      final Uri second = (await restarted.readFromPath(path))!.artworkUri!;

      expect(second, first);
      // Untouched, not rewritten: the cache hit skipped extraction entirely.
      expect(cachedFile.lastModifiedSync(), writtenAt);
    });

    test('a cover larger than the bound is downsampled, not stored as-is',
        () async {
      final Uint8List cover = await solidPng(2000, 1000);
      final String path = write(
        'huge.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: cover),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      final File cached = File(metadata!.artworkUri!.toFilePath());
      final ui.Size size = await decodedSize(cached);
      expect(size.width, lessThanOrEqualTo(1024));
      expect(size.height, lessThanOrEqualTo(1024));
      // Aspect ratio survives the resize.
      expect(size.width / size.height, closeTo(2.0, 0.05));
    });

    test('a cover already within the bound is stored unresized', () async {
      final Uint8List cover = await solidPng(200, 100);
      final String path = write(
        'small.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: cover),
      );

      final LocalAudioMetadata? metadata = await reader.readFromPath(path);

      final File cached = File(metadata!.artworkUri!.toFilePath());
      final ui.Size size = await decodedSize(cached);
      expect(size.width, 200);
      expect(size.height, 100);
    });

    test('a missing/deleted cache entry regenerates instead of staying null',
        () async {
      final Uint8List cover = await solidPng(48, 48);
      final String path = write(
        'regenerate.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: cover),
      );

      final Uri first = (await reader.readFromPath(path))!.artworkUri!;
      File(first.toFilePath()).deleteSync();

      final Uri? second = (await reader.readFromPath(path))?.artworkUri;

      expect(second, isNotNull);
      expect(File(second!.toFilePath()).existsSync(), isTrue);
    });

    test('re-tagging a file with new art replaces the cover it shows',
        () async {
      // The stale-cache case that matters in practice: the user fixes an
      // album's artwork in a tagger. The scan sees a changed stamp and
      // re-reads the file, and the cover must follow the tags rather than
      // being served from the entry cached before the edit.
      final String path = write(
        'retagged.mp3',
        AudioTagFixtures.mp3(title: 'Song', coverImage: await solidPng(32, 32)),
      );
      final Uri before = (await reader.readFromPath(path))!.artworkUri!;
      expect(
          await decodedSize(File(before.toFilePath())), const ui.Size(32, 32));

      // A real re-tag rewrites the bytes and moves the mtime; writing a
      // different cover does both.
      File(path).writeAsBytesSync(
        AudioTagFixtures.mp3(title: 'Song', coverImage: await solidPng(96, 96)),
        flush: true,
      );
      File(path).setLastModifiedSync(
        DateTime.now().add(const Duration(seconds: 5)),
      );

      final Uri after = (await reader.readFromPath(path))!.artworkUri!;

      expect(after, isNot(before));
      expect(
          await decodedSize(File(after.toFilePath())), const ui.Size(96, 96));
    });

    test('retainArtwork drops covers the library no longer references',
        () async {
      final String kept = write(
        'kept.mp3',
        AudioTagFixtures.mp3(title: 'Kept', coverImage: await solidPng(24, 24)),
      );
      final String removed = write(
        'removed.mp3',
        AudioTagFixtures.mp3(title: 'Gone', coverImage: await solidPng(24, 24)),
      );
      final Uri keptCover = (await reader.readFromPath(kept))!.artworkUri!;
      final Uri removedCover =
          (await reader.readFromPath(removed))!.artworkUri!;

      await reader.retainArtwork(<Uri>{keptCover});

      expect(File(keptCover.toFilePath()).existsSync(), isTrue);
      expect(File(removedCover.toFilePath()).existsSync(), isFalse);
    });

    test('retainArtwork never touches the source audio files', () async {
      final Uint8List songBytes = AudioTagFixtures.mp3(
        title: 'Song',
        coverImage: await solidPng(24, 24),
      );
      final String path = write('source.mp3', songBytes);
      await reader.readFromPath(path);

      // The most aggressive sweep there is: nothing at all is live.
      await reader.retainArtwork(const <Uri>{});

      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), songBytes);
      expect(root.listSync(), hasLength(1));
      // …and the track is still perfectly readable afterwards, cover included.
      final LocalAudioMetadata? again = await reader.readFromPath(path);
      expect(again!.title, 'Song');
      expect(File(again.artworkUri!.toFilePath()).existsSync(), isTrue);
    });
  });
}

/// How long a read may take before a test calls it a hang. Generous: reading
/// one of these few-hundred-byte files takes milliseconds.
const Duration _hangTimeout = Duration(seconds: 10);

/// Runs [FilesystemLocalMetadataReader.readFromPath] for [path] on a fresh
/// isolate and fails the test if it has not answered within [_hangTimeout].
///
/// A parser stuck in a synchronous loop never gives its isolate back to the
/// event loop, so no timeout on that isolate can fire. Here the loop is on
/// someone else's isolate, the test's own timer still runs, and the stuck
/// isolate is killed rather than left spinning a core for the rest of the run.
Future<LocalAudioMetadata?> _readOnOwnIsolate(
  String path,
  String artworkPath,
) async {
  final ReceivePort port = ReceivePort();
  final Isolate isolate = await Isolate.spawn(
    _readFromPathEntry,
    (port.sendPort, path, artworkPath),
    onError: port.sendPort,
  );
  try {
    final Object? reply = await port.first.timeout(
      _hangTimeout,
      onTimeout: () => fail(
        'readFromPath did not return within $_hangTimeout: the tag parser '
        'is stuck in a loop',
      ),
    );
    // An uncaught error arrives as [error, stack] rather than a result.
    if (reply is List) fail('readFromPath threw: ${reply.first}');
    return reply as LocalAudioMetadata?;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    port.close();
  }
}

/// Runs [entry] with [message] on an isolate of its own and returns what it
/// sends back, failing the test instead of hanging if nothing comes within
/// [_hangTimeout].
Future<Object?> _onOwnIsolate<T>(
  void Function((SendPort, T)) entry,
  T message,
) async {
  final ReceivePort port = ReceivePort();
  final Isolate isolate = await Isolate.spawn(
    entry,
    (port.sendPort, message),
    onError: port.sendPort,
  );
  try {
    final Object? reply = await port.first.timeout(
      _hangTimeout,
      onTimeout: () => fail(
        'readFromPath did not return within $_hangTimeout: the tag parser '
        'is stuck in a loop',
      ),
    );
    if (reply is List) fail('readFromPath threw: ${reply.first}');
    return reply;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    port.close();
  }
}

/// A reader whose artwork lookup (the await between the guard and the parse)
/// rewrites the file to looping bytes first, as a file still being written
/// would change in that gap. Its parse limit is short, so a stopped parse
/// shows up quickly.
Future<void> _readWhileRewritingEntry(
  (SendPort, (String, String, Uint8List)) message,
) async {
  final (SendPort reply, (String path, String artworkPath, Uint8List looping)) =
      message;
  final FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader(
    artworkCache: _RewritingArtworkCache(
      directory: () async => Directory(artworkPath),
      rewrite: () => File(path).writeAsBytesSync(looping, flush: true),
    ),
    parseLimit: const Duration(milliseconds: 300),
  );
  final LocalAudioMetadata? metadata = await reader.readFromPath(path);
  await reader.close();
  reply.send(metadata);
}

/// A reader with no MP4 guard and a short parse limit, so a looping file
/// reaches the parser and only the limit can end it.
Future<void> _readUnguardedEntry((SendPort, (String, String)) message) async {
  final (SendPort reply, (String path, String artworkPath)) = message;
  final FilesystemLocalMetadataReader reader = _unguardedReader(artworkPath);
  final LocalAudioMetadata? metadata = await reader.readFromPath(path);
  await reader.close();
  reply.send(metadata);
}

/// Reads `(path, artworkPath)` with the guard out of the way, and sends back
/// whether the read failed.
Future<void> _readOutcomeUnguardedEntry(
  (SendPort, (String, String)) message,
) async {
  final (SendPort reply, (String path, String artworkPath)) = message;
  final FilesystemLocalMetadataReader reader = _unguardedReader(artworkPath);
  final LocalMetadataRead read = await reader.readWithOutcome(path);
  await reader.close();
  reply.send(read.failed);
}

/// A guard that refuses nothing. Top-level, so it can cross to the parse's
/// isolate.
bool _letEverythingThrough(File file) => true;

/// The real guard, except that it takes the parser isolate down with it on a
/// file named `dies.mp3`, the way a crash in the parser would.
bool _exitOnDiesFiles(File file) {
  if (file.path.endsWith('dies.mp3')) Isolate.exit();
  return Mp4BoxGuard.isSafeToParse(file);
}

/// An unfinished encode: `ftyp`, `free`, and an `mdat` still sized 0, which
/// the package's MP4 parser loops on.
Uint8List _unfinishedEncode() => Uint8List.fromList(<int>[
      ...AudioTagFixtures.mp4Ftyp(),
      ...AudioTagFixtures.mp4Box('free'),
      ...AudioTagFixtures.mp4BoxHeader(0, 'mdat'),
      ...Uint8List(4096),
    ]);

/// A reader with no MP4 guard and a short parse limit, for files that reach
/// the parser and loop.
FilesystemLocalMetadataReader _unguardedReader(String artworkPath) =>
    FilesystemLocalMetadataReader(
      artworkCache: LocalArtworkCache(
        directory: () async => Directory(artworkPath),
      ),
      parseLimit: const Duration(milliseconds: 300),
      guard: _letEverythingThrough,
    );

/// Reads each path in turn on an unguarded reader and sends back their titles
/// and how many parser isolates it took.
Future<void> _readUnguardedInOrderEntry(
  (SendPort, (List<String>, String)) message,
) async {
  final (SendPort reply, (List<String> paths, String artworkPath)) = message;
  final FilesystemLocalMetadataReader reader = _unguardedReader(artworkPath);
  final List<String?> titles = <String?>[
    for (final String path in paths) (await reader.readFromPath(path))?.title,
  ];
  await reader.close();
  reply.send((titles, reader.parsersStarted));
}

/// Asks an unguarded reader for every path at once and sends back their
/// titles and how many parser isolates it took.
Future<void> _readUnguardedAtOnceEntry(
  (SendPort, (List<String>, String)) message,
) async {
  final (SendPort reply, (List<String> paths, String artworkPath)) = message;
  final FilesystemLocalMetadataReader reader = _unguardedReader(artworkPath);
  final List<LocalAudioMetadata?> results = await Future.wait(
    <Future<LocalAudioMetadata?>>[
      for (final String path in paths) reader.readFromPath(path),
    ],
  );
  await reader.close();
  reply.send((
    <String?>[for (final LocalAudioMetadata? r in results) r?.title],
    reader.parsersStarted,
  ));
}

/// An artwork cache that rewrites the file being read when it is asked for a
/// cached cover, and then misses.
class _RewritingArtworkCache extends LocalArtworkCache {
  _RewritingArtworkCache({super.directory, required this.rewrite});

  final void Function() rewrite;

  @override
  Future<File?> cachedFile(String path, LocalFileStamp stamp) async {
    rewrite();
    return null;
  }
}

/// [_readOnOwnIsolate]'s entry point: a reader of its own (nothing crosses the
/// isolate boundary but strings), pointed at the test's artwork directory.
Future<void> _readFromPathEntry((SendPort, String, String) message) async {
  final (SendPort reply, String path, String artworkPath) = message;
  final FilesystemLocalMetadataReader reader = FilesystemLocalMetadataReader(
    artworkCache: LocalArtworkCache(
      directory: () async => Directory(artworkPath),
    ),
  );
  final LocalAudioMetadata? metadata = await reader.readFromPath(path);
  await reader.close();
  reply.send(metadata);
}
