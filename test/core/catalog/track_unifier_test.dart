import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';

Track _jelly(
  String id, {
  required String title,
  String artist = 'Adele',
  String album = '25',
  Duration duration = const Duration(minutes: 3),
}) =>
    Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
    );

Track _sub(
  String id, {
  required String title,
  String artist = 'Adele',
  String album = '25',
  Duration duration = const Duration(minutes: 3),
}) =>
    Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: artist,
      albumName: album,
      duration: duration,
    );

/// An untagged local file: a path for id+uri, the file name as title, and no
/// artist/album/duration — the shape the local scanner produces for bare files.
Track _local(String name) =>
    Track(id: '/m/$name', title: name, uri: '/m/$name');

const _subsonicPreferred = SourcePriority(<String>['subsonic', 'jellyfin']);
const _jellyfinPreferred = SourcePriority(<String>['jellyfin', 'subsonic']);

void main() {
  group('unifyTracks — collapsing cross-provider duplicates', () {
    test('the same song on Jellyfin + Navidrome becomes one row', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_jelly('j', title: 'Hello'), _sub('s', title: 'Hello')],
        _subsonicPreferred,
      );

      expect(logical, hasLength(1));
      expect(logical.single.hasMultipleSources, isTrue);
      expect(logical.single.allTrackIds, containsAll(<String>['j', 's']));
    });

    test('prefers the active/default provider for the playable copy', () {
      final List<Track> tracks = <Track>[
        _jelly('j', title: 'Hello'),
        _sub('s', title: 'Hello'),
      ];

      // Navidrome active -> the Subsonic copy is primary (and would be queued).
      expect(
        unifyTracks(tracks, _subsonicPreferred).single.primary.sourceId,
        'subsonic',
      );
      // Jellyfin active -> the Jellyfin copy is primary instead.
      expect(
        unifyTracks(tracks, _jellyfinPreferred).single.primary.sourceId,
        'jellyfin',
      );
    });

    test('candidates are ordered best-first so fallback is deterministic', () {
      final LogicalTrack row = unifyTracks(
        <Track>[_jelly('j', title: 'Hello'), _sub('s', title: 'Hello')],
        _subsonicPreferred,
      ).single;

      expect(row.sourceIds, <String>['subsonic', 'jellyfin']);
    });
  });

  group('unifyTracks — single-source songs are untouched', () {
    test('a Jellyfin-only track still appears and plays from Jellyfin', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_jelly('j', title: 'Solo')],
        _subsonicPreferred,
      );
      expect(logical, hasLength(1));
      expect(logical.single.primary.sourceId, 'jellyfin');
    });

    test('a Navidrome-only track still appears and plays from Navidrome', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_sub('s', title: 'Solo')],
        _jellyfinPreferred,
      );
      expect(logical, hasLength(1));
      expect(logical.single.primary.sourceId, 'subsonic');
    });

    test(
        'the active provider missing a track falls back to the one that has it',
        () {
      // Navidrome is preferred, but this song only exists on Jellyfin.
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_jelly('j', title: 'Only On Jellyfin')],
        _subsonicPreferred,
      );
      expect(logical.single.primary.sourceId, 'jellyfin');
    });
  });

  group('unifyTracks — local files behave exactly as before', () {
    test('local-only tracks each stay their own row', () {
      final List<Track> local = <Track>[_local('a.mp3'), _local('b.mp3')];
      final List<LogicalTrack> logical = unifyTracks(local, _subsonicPreferred);

      expect(logical, hasLength(2));
      expect(
        logical.map((LogicalTrack l) => l.primaryTrack).toList(),
        local,
      );
      expect(logical.every((LogicalTrack l) => !l.hasMultipleSources), isTrue);
    });
  });

  group('unifyTracks — conservative, never over-merging', () {
    test('different songs that share a title are not merged', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j', title: 'Intro', album: 'Album A'),
          _sub('s', title: 'Intro', album: 'Album B'),
        ],
        _subsonicPreferred,
      );
      expect(logical, hasLength(2));
    });

    test('same title + artist but a different duration stays separate', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j', title: 'Hello', duration: const Duration(minutes: 3)),
          _sub('s', title: 'Hello', duration: const Duration(minutes: 6)),
        ],
        _subsonicPreferred,
      );
      expect(logical, hasLength(2));
    });

    test('a single provider is returned one-row-per-track, never merged', () {
      // Two distinct Jellyfin tracks that happen to share a key are NOT merged,
      // because a single source is assumed already de-duplicated. This is the
      // guarantee that an existing single-provider library is unchanged.
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j1', title: 'Hello'),
          _jelly('j2', title: 'Hello'),
        ],
        _subsonicPreferred,
      );
      expect(logical, hasLength(2));
    });

    test('untagged duplicates across providers are not merged', () {
      // Without trustworthy tags there is no confident match, so two same-named
      // local-ish files stay separate even though the names match.
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_local('song.mp3'), _local('song.mp3')],
        _subsonicPreferred,
      );
      expect(logical, hasLength(2));
    });
  });

  group('unifyTracks — tolerant of real Jellyfin/Navidrome metadata drift', () {
    test('a featured artist tagged on only one provider still merges', () {
      // Jellyfin: "CAREFUL" by "NF"; Navidrome: "CAREFUL feat. Cordae" by
      // "NF, Cordae" — the same song, the exact key used to split them.
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j', title: 'CAREFUL', artist: 'NF', album: 'The Search'),
          _sub('s',
              title: 'CAREFUL feat. Cordae',
              artist: 'NF, Cordae',
              album: 'The Search'),
        ],
        _subsonicPreferred,
      );

      expect(logical, hasLength(1));
      expect(logical.single.allTrackIds, containsAll(<String>['j', 's']));
    });

    test('an album edition suffix does not split a match', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j', title: 'Hello', album: '25'),
          _sub('s', title: 'Hello', album: '25 (Deluxe)'),
        ],
        _subsonicPreferred,
      );
      expect(logical, hasLength(1));
      expect(logical.single.hasMultipleSources, isTrue);
    });

    test('a near-but-not-equal duration (1s) still merges', () {
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[
          _jelly('j', title: 'Hello', duration: const Duration(seconds: 181)),
          _sub('s', title: 'Hello', duration: const Duration(seconds: 182)),
        ],
        _subsonicPreferred,
      );
      expect(logical, hasLength(1));
    });
  });

  group('unifyTracks — default-provider-first display & fallback', () {
    test('a song on both providers shows and plays the default provider copy',
        () {
      final List<Track> tracks = <Track>[
        _jelly('j', title: 'Hello'),
        _sub('s', title: 'Hello'),
      ];
      // Jellyfin is the default/preferred provider here.
      final LogicalTrack row = unifyTracks(tracks, _jellyfinPreferred).single;
      expect(row.primary.sourceId, 'jellyfin');
      expect(row.displayTrack.uri, 'jellyfin:j');
      // The secondary copy is retained internally as a fallback candidate.
      expect(row.sourceIds, <String>['jellyfin', 'subsonic']);
    });

    test('a secondary-only song is included and plays from the secondary', () {
      // Jellyfin is default, but this song exists only on Navidrome.
      final List<LogicalTrack> logical = unifyTracks(
        <Track>[_sub('s', title: 'Navi Only')],
        _jellyfinPreferred,
      );
      expect(logical, hasLength(1));
      expect(logical.single.primary.sourceId, 'subsonic');
      expect(logical.single.displayTrack.uri, 'subsonic:s');
    });
  });

  group('unifyTracks — output ordering', () {
    test('a merged row appears at its first occurrence; order is preserved',
        () {
      final Track jellyHello = _jelly('j', title: 'Hello');
      final Track localOnly = _local('b.mp3');
      final Track subHello = _sub('s', title: 'Hello');

      final List<LogicalTrack> logical = unifyTracks(
        <Track>[jellyHello, localOnly, subHello],
        _subsonicPreferred,
      );

      // Two rows: the merged "Hello" (first seen at index 0) then the local file.
      expect(logical, hasLength(2));
      expect(logical.first.hasMultipleSources, isTrue);
      expect(logical.first.allTrackIds, containsAll(<String>['j', 's']));
      expect(logical.last.primaryTrack.id, localOnly.id);
    });
  });
}
