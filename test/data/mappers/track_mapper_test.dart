import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/mappers/track_mapper.dart';

/// The persisted `artworkUri` is what lets the UI reuse an extracted local cover
/// on the next launch *without* re-extracting it — and what keeps a Jellyfin
/// cover URL stable in the catalog. These round-trips lock that in.
void main() {
  group('track artworkUri persistence', () {
    test('a local embedded-cover file:// URI survives the round-trip', () {
      final Uri art = Uri.parse(
        'file:///data/user/0/app/cache/linthra_local_artwork/abc.img',
      );
      final Track track = Track(
        id: 'content://doc/1',
        title: 'Song',
        uri: 'content://doc/1',
        artworkUri: art,
      );

      // Flattened to a primitive string for storage...
      final companion = trackToCompanion(track, 'local');
      expect(companion.artworkUri.value, art.toString());

      // ...and rebuilt as the same Uri on read, so launch reuses the cover.
      final TrackRow row = TrackRow(
        id: track.id,
        sourceId: 'local',
        title: track.title,
        uri: track.uri,
        durationMs: 0,
        artworkUri: companion.artworkUri.value,
      );
      expect(trackFromRow(row).artworkUri, art);
    });

    test('a Jellyfin http(s) cover URL round-trips unchanged', () {
      final Uri art =
          Uri.parse('https://music.example.com/Items/1/Images/Primary');
      final companion = trackToCompanion(
        Track(id: 'jellyfin:1', title: 'X', uri: 'jellyfin:1', artworkUri: art),
        'jellyfin',
      );
      expect(companion.artworkUri.value, art.toString());

      final TrackRow row = TrackRow(
        id: 'jellyfin:1',
        sourceId: 'jellyfin',
        title: 'X',
        uri: 'jellyfin:1',
        durationMs: 0,
        artworkUri: companion.artworkUri.value,
      );
      expect(trackFromRow(row).artworkUri, art);
    });

    test('a track with no cover stores and reads back a null artworkUri', () {
      final companion = trackToCompanion(
        const Track(id: 'subsonic:1', title: 'X', uri: 'subsonic:1'),
        'subsonic',
      );
      expect(companion.artworkUri.value, isNull);

      const TrackRow row = TrackRow(
        id: 'subsonic:1',
        sourceId: 'subsonic',
        title: 'X',
        uri: 'subsonic:1',
        durationMs: 0,
      );
      expect(trackFromRow(row).artworkUri, isNull);
    });
  });
}
