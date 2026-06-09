import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';

/// End-to-end checks that a *locally mapped* track (built by the real
/// [LocalTrackMapper], not a hand-made [Track]) flows through the same grouping
/// and unification the server sources use — so local music indexes like a real
/// source rather than a flat file list.

/// A Jellyfin-shaped catalog track: an opaque `jellyfin:<id>` uri and full tags.
Track _jelly(
  String id, {
  required String title,
  required String artist,
  required String album,
  required Duration duration,
  int? trackNumber,
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
      trackNumber: trackNumber,
    );

void main() {
  group('local tracks group like a real source', () {
    test('a foldered library groups into its albums and artists', () {
      final List<Track> tracks = <Track>[
        for (final String path in <String>[
          '/music/Bon Iver/For Emma/01 - Flume.mp3',
          '/music/Bon Iver/For Emma/02 - Lump Sum.mp3',
          '/music/Adele/25/01 - Hello.mp3',
        ])
          LocalTrackMapper.fromPath(path, scanRoot: '/music'),
      ];

      final albums = groupAlbums(tracks);
      final artists = groupArtists(tracks);

      expect(albums.map((a) => a.title).toList(), <String>['25', 'For Emma']);
      final forEmma = albums.firstWhere((a) => a.title == 'For Emma');
      expect(forEmma.artistName, 'Bon Iver');
      expect(forEmma.trackCount, 2);
      expect(
          artists.map((a) => a.name).toList(), <String>['Adele', 'Bon Iver']);
    });

    test('untagged files still fold into Unknown Album / Unknown Artist', () {
      final List<Track> tracks = <Track>[
        LocalTrackMapper.fromPath('/music/song one.mp3'),
        LocalTrackMapper.fromPath('/music/song two.mp3'),
      ];

      final albums = groupAlbums(tracks);
      final artists = groupArtists(tracks);

      expect(albums.single.title, kUnknownAlbum);
      expect(artists.single.name, kUnknownArtist);
    });
  });

  group('conservative-but-useful cross-provider dedup', () {
    test('an untagged local file never merges with a server copy', () {
      // No duration and no tags → ineligible to match, so it always stands as
      // its own row (the safety invariant for local-only libraries).
      final Track local = LocalTrackMapper.fromPath('/music/Holocene.mp3');
      final Track jelly = _jelly(
        'j1',
        title: 'Holocene',
        artist: 'Bon Iver',
        album: 'Bon Iver',
        duration: const Duration(seconds: 337),
      );

      final List<LogicalTrack> unified =
          unifyTracks(<Track>[local, jelly], SourcePriority.fallback);

      expect(unified, hasLength(2));
      expect(unified.every((t) => t.candidates.length == 1), isTrue);
    });

    test('a fully tagged local file merges with the matching server copy', () {
      // Tags (incl. a real duration) make the local copy eligible; it matches
      // the Jellyfin copy, so the two collapse into one row with both copies.
      final Track local = LocalTrackMapper.fromPath(
        '/music/Bon Iver/Bon Iver/03 - Holocene.mp3',
        scanRoot: '/music',
        metadata: const LocalAudioMetadata(
          title: 'Holocene',
          artist: 'Bon Iver',
          albumArtist: 'Bon Iver',
          album: 'Bon Iver',
          trackNumber: 3,
          duration: Duration(seconds: 337),
        ),
      );
      final Track jelly = _jelly(
        'j1',
        title: 'Holocene',
        artist: 'Bon Iver',
        album: 'Bon Iver',
        duration: const Duration(seconds: 338), // within the 2s tolerance
        trackNumber: 3,
      );

      final List<LogicalTrack> unified =
          unifyTracks(<Track>[local, jelly], SourcePriority.fallback);

      expect(unified, hasLength(1));
      final LogicalTrack row = unified.single;
      expect(row.hasMultipleSources, isTrue);
      expect(row.sourceIds.toSet(), <String>{'local', 'jellyfin'});
    });
  });
}
