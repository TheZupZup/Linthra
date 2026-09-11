import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_artwork_cache.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';

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
