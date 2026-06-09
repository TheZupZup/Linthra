import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

void main() {
  group('LocalTrackMapper.fromPath — filename/folder fallback', () {
    test('uses the file name without extension as the title', () {
      final track = LocalTrackMapper.fromPath('/music/Holocene.mp3');
      expect(track.title, 'Holocene');
      expect(track.trackNumber, isNull);
    });

    test('keeps the full path as both id and uri', () {
      const path = '/music/Bon Iver/Holocene.flac';
      final track = LocalTrackMapper.fromPath(path);
      expect(track.id, path);
      expect(track.uri, path);
    });

    test('splits a leading track number from the title', () {
      final track = LocalTrackMapper.fromPath('/music/01 - Intro (Live).m4a');
      expect(track.trackNumber, 1);
      expect(track.title, 'Intro (Live)');
    });

    test('handles "01. Title", "01 Title", and "01_Title" separators', () {
      expect(LocalTrackMapper.fromPath('/m/03. Song.mp3').trackNumber, 3);
      expect(LocalTrackMapper.fromPath('/m/03. Song.mp3').title, 'Song');
      expect(LocalTrackMapper.fromPath('/m/4 Song.mp3').trackNumber, 4);
      expect(LocalTrackMapper.fromPath('/m/4 Song.mp3').title, 'Song');
      expect(LocalTrackMapper.fromPath('/m/05_Song.mp3').trackNumber, 5);
      expect(LocalTrackMapper.fromPath('/m/05_Song.mp3').title, 'Song');
    });

    test('does not treat a number with no separator as a track number', () {
      final track = LocalTrackMapper.fromPath('/music/1984.flac');
      expect(track.trackNumber, isNull);
      expect(track.title, '1984');
    });

    test('only strips the final extension when the name has dots', () {
      final track = LocalTrackMapper.fromPath('/music/a.b.c.opus');
      expect(track.title, 'a.b.c');
      expect(track.trackNumber, isNull);
    });

    test('derives album and artist from the Artist/Album folders below a root',
        () {
      final track = LocalTrackMapper.fromPath(
        '/music/Bon Iver/For Emma/01 - Flume.mp3',
        scanRoot: '/music',
      );
      expect(track.artistName, 'Bon Iver');
      expect(track.albumName, 'For Emma');
      expect(track.title, 'Flume');
      expect(track.trackNumber, 1);
    });

    test('uses the single folder below the root as the album, artist unknown',
        () {
      final track = LocalTrackMapper.fromPath(
        '/music/25/01 Hello.mp3',
        scanRoot: '/music',
      );
      expect(track.albumName, '25');
      expect(track.artistName, isNull);
    });

    test('never treats the scan root itself as an album', () {
      // A file directly inside the chosen root has no folder context, so album
      // and artist stay null rather than borrowing the root folder's name.
      final track = LocalTrackMapper.fromPath(
        '/music/song.wav',
        scanRoot: '/music',
      );
      expect(track.albumName, isNull);
      expect(track.artistName, isNull);
    });

    test('derives no folder metadata without a scan root', () {
      final track = LocalTrackMapper.fromPath('/music/Artist/Album/song.wav');
      expect(track.albumName, isNull);
      expect(track.artistName, isNull);
      expect(track.duration, Duration.zero);
    });

    test('produces tracks that are equal by path identity', () {
      final a = LocalTrackMapper.fromPath('/music/song.mp3');
      final b = LocalTrackMapper.fromPath('/music/song.mp3');
      expect(a, b);
    });
  });

  group('LocalTrackMapper.fromPath — tags override the fallback', () {
    test('tag fields win over filename/folder, each independently', () {
      final track = LocalTrackMapper.fromPath(
        '/music/Folder Artist/Folder Album/01 - Folder Title.mp3',
        scanRoot: '/music',
        metadata: const LocalAudioMetadata(
          title: 'Tagged Title',
          artist: 'Tagged Artist',
          album: 'Tagged Album',
          trackNumber: 7,
          duration: Duration(seconds: 200),
        ),
      );
      expect(track.title, 'Tagged Title');
      expect(track.artistName, 'Tagged Artist');
      expect(track.albumName, 'Tagged Album');
      expect(track.trackNumber, 7);
      expect(track.duration, const Duration(seconds: 200));
    });

    test('a missing or blank tag falls back to the name/folder per field', () {
      final track = LocalTrackMapper.fromPath(
        '/music/Folder Artist/Folder Album/02 - Folder Title.mp3',
        scanRoot: '/music',
        // Only the album is tagged (and a blank title is ignored).
        metadata: const LocalAudioMetadata(title: '  ', album: 'Tagged Album'),
      );
      expect(track.title, 'Folder Title');
      expect(track.albumName, 'Tagged Album');
      expect(track.artistName, 'Folder Artist');
      expect(track.trackNumber, 2);
      expect(track.duration, Duration.zero);
    });

    test('prefers the album artist over the track artist for grouping', () {
      final withBoth = LocalTrackMapper.fromPath(
        '/music/song.mp3',
        metadata: const LocalAudioMetadata(
          artist: 'Track Artist',
          albumArtist: 'Album Artist',
        ),
      );
      expect(withBoth.artistName, 'Album Artist');

      final artistOnly = LocalTrackMapper.fromPath(
        '/music/song.mp3',
        metadata: const LocalAudioMetadata(artist: 'Track Artist'),
      );
      expect(artistOnly.artistName, 'Track Artist');
    });
  });

  group('LocalTrackMapper.fromSafDocument', () {
    test('uses the display name without extension as the title', () {
      const doc = SafAudioDocument(uri: 'content://x/1', name: 'Holocene.mp3');
      final track = LocalTrackMapper.fromSafDocument(doc);
      expect(track.title, 'Holocene');
      expect(track.artistName, isNull);
      expect(track.albumName, isNull);
      expect(track.trackNumber, isNull);
    });

    test('splits a leading track number from the display name', () {
      const doc = SafAudioDocument(uri: 'content://x/1', name: '03. Song.flac');
      final track = LocalTrackMapper.fromSafDocument(doc);
      expect(track.trackNumber, 3);
      expect(track.title, 'Song');
    });

    test('keeps the content URI as both id and uri', () {
      const doc = SafAudioDocument(uri: 'content://x/1', name: 'Song.flac');
      final track = LocalTrackMapper.fromSafDocument(doc);
      expect(track.id, 'content://x/1');
      expect(track.uri, 'content://x/1');
    });

    test('uses native tags when present, name as the per-field fallback', () {
      const doc = SafAudioDocument(
        uri: 'content://x/1',
        name: '05 - Name Fallback.mp3',
        metadata: LocalAudioMetadata(
          title: 'Tagged',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 3),
        ),
      );
      final track = LocalTrackMapper.fromSafDocument(doc);
      expect(track.title, 'Tagged');
      expect(track.artistName, 'Artist');
      expect(track.albumName, 'Album');
      expect(track.duration, const Duration(minutes: 3));
      // No track number in the tags, so it comes from the display name.
      expect(track.trackNumber, 5);
    });
  });
}
