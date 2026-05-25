import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_mapper.dart';

void main() {
  group('SubsonicTrackMapper.toTrack', () {
    test('maps a song to a token-free subsonic: uri', () {
      const song = SubsonicSongDto(
        id: 'song-42',
        title: 'Nightcall',
        album: 'Drive',
        artist: 'Kavinsky',
        track: 3,
        durationSeconds: 256,
      );

      final track = SubsonicTrackMapper.toTrack(song);

      expect(track.id, 'song-42');
      expect(track.uri, 'subsonic:song-42');
      expect(track.title, 'Nightcall');
      expect(track.artistName, 'Kavinsky');
      expect(track.albumName, 'Drive');
      expect(track.trackNumber, 3);
      expect(track.duration, const Duration(seconds: 256));
    });

    test('never embeds a credential or artwork URL (auth-bearing)', () {
      const song = SubsonicSongDto(id: 's1', title: 'x');
      final track = SubsonicTrackMapper.toTrack(song);

      // The uri is the opaque id only — no query, no token/salt.
      expect(track.uri, 'subsonic:s1');
      expect(track.uri, isNot(contains('?')));
      expect(track.uri, isNot(contains('token')));
      expect(track.uri, isNot(contains('=')));
      // Cover art needs auth params, so artwork is intentionally not persisted.
      expect(track.artworkUri, isNull);
    });

    test('maps zero/absent duration to zero', () {
      expect(
        SubsonicTrackMapper.toTrack(
          const SubsonicSongDto(id: 's', title: 't'),
        ).duration,
        Duration.zero,
      );
    });
  });

  group('SubsonicTrackMapper album/artist', () {
    test('maps an album', () {
      const dto = SubsonicAlbumDto(
        id: 'al-1',
        name: 'Drive',
        artist: 'Kavinsky',
        songCount: 12,
        year: 2011,
      );
      final album = SubsonicTrackMapper.toAlbum(dto);
      expect(album.id, 'al-1');
      expect(album.title, 'Drive');
      expect(album.artistName, 'Kavinsky');
      expect(album.trackCount, 12);
      expect(album.year, 2011);
      expect(album.artworkUri, isNull);
    });

    test('maps an artist', () {
      const dto =
          SubsonicArtistDto(id: 'ar-1', name: 'Kavinsky', albumCount: 2);
      final artist = SubsonicTrackMapper.toArtist(dto);
      expect(artist.id, 'ar-1');
      expect(artist.name, 'Kavinsky');
      expect(artist.albumCount, 2);
      expect(artist.artworkUri, isNull);
    });
  });
}
