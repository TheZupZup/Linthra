import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/models/track.dart';

final Uri _jellyArt =
    Uri.parse('https://music.example.com/Items/j/Images/Primary');
final Uri _localArt = Uri.parse('file:///covers/local.jpg');

TrackSourceCandidate _candidate(
  String sourceId, {
  required String id,
  Uri? artwork,
}) =>
    TrackSourceCandidate(
      track: Track(
        id: id,
        title: 'Hello',
        uri: '$sourceId:$id',
        artistName: 'Adele',
        albumName: '25',
        duration: const Duration(minutes: 3),
        artworkUri: artwork,
      ),
      sourceId: sourceId,
    );

void main() {
  group('LogicalTrack.displayArtworkUri — deterministic best-available cover',
      () {
    test('uses the preferred copy\'s own artwork when it has some', () {
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        _candidate('jellyfin', id: 'j', artwork: _jellyArt),
        _candidate('subsonic', id: 's'),
      ]);
      expect(row.displayArtworkUri, _jellyArt);
    });

    test('falls back to a secondary copy when the preferred copy has none', () {
      // The reported regression: Subsonic is preferred (its mapper stores no
      // artwork), so before the fix the merged row showed a blank cover even
      // though the Jellyfin copy has one.
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        _candidate('subsonic', id: 's'),
        _candidate('jellyfin', id: 'j', artwork: _jellyArt),
      ]);
      expect(row.displayArtworkUri, _jellyArt);
    });

    test('the fallback is deterministic: first candidate (in order) with art',
        () {
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        _candidate('subsonic', id: 's'),
        _candidate('local', id: 'l', artwork: _localArt),
        _candidate('jellyfin', id: 'j', artwork: _jellyArt),
      ]);
      // Local is ahead of Jellyfin in the candidate order, so its cover wins.
      expect(row.displayArtworkUri, _localArt);
    });

    test('is null only when no candidate carries artwork', () {
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        _candidate('subsonic', id: 's'),
        _candidate('jellyfin', id: 'j'),
      ]);
      expect(row.displayArtworkUri, isNull);
    });
  });

  group('LogicalTrack.displayTrack — primary identity, best cover', () {
    test('keeps the primary id and uri but fills in the fallback cover', () {
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        _candidate('subsonic', id: 's'),
        _candidate('jellyfin', id: 'j', artwork: _jellyArt),
      ]);
      final Track display = row.displayTrack;
      // Identity stays the preferred copy's, so playback/source/removal are
      // unchanged...
      expect(display.id, 's');
      expect(display.uri, 'subsonic:s');
      // ...only the artwork is filled from the fallback.
      expect(display.artworkUri, _jellyArt);
    });

    test('returns the primary unchanged when its cover is already best', () {
      final TrackSourceCandidate primary =
          _candidate('jellyfin', id: 'j', artwork: _jellyArt);
      final LogicalTrack row = LogicalTrack(<TrackSourceCandidate>[
        primary,
        _candidate('subsonic', id: 's'),
      ]);
      expect(identical(row.displayTrack, primary.track), isTrue);
    });
  });
}
