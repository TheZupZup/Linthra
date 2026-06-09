import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
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

    test('maps the song coverArt to a credential-free artwork reference', () {
      const song = SubsonicSongDto(
        id: 'song-42',
        title: 'Nightcall',
        coverArt: 'al-7',
      );

      final track = SubsonicTrackMapper.toTrack(song);

      // The persisted artwork is the opaque, credential-free reference — never
      // an auth-bearing getCoverArt URL.
      expect(track.artworkUri, SubsonicArtwork.reference('al-7'));
      expect(track.artworkUri.toString(), 'subsonic-cover:al-7');
      expect(SubsonicArtwork.coverArtId(track.artworkUri!), 'al-7');
    });

    test('the uri and artwork reference never embed a credential', () {
      const song = SubsonicSongDto(id: 's1', title: 'x', coverArt: 'al-1');
      final track = SubsonicTrackMapper.toTrack(song);

      // The uri is the opaque id only — no query, no token/salt.
      expect(track.uri, 'subsonic:s1');
      expect(track.uri, isNot(contains('?')));
      expect(track.uri, isNot(contains('token')));
      expect(track.uri, isNot(contains('=')));
      // The artwork reference is credential-free and points at no server: the
      // salt+token are woven in only at render time, never persisted here.
      final String artwork = track.artworkUri.toString();
      expect(artwork, 'subsonic-cover:al-1');
      expect(artwork, isNot(contains('?')));
      expect(artwork, isNot(contains('t=')));
      expect(artwork, isNot(contains('s=')));
      expect(artwork, isNot(contains('http')));
    });

    test('leaves artworkUri null when the server reports no coverArt', () {
      const song = SubsonicSongDto(id: 's1', title: 'x');
      final track = SubsonicTrackMapper.toTrack(song);
      // No cover art → null → the UI shows its placeholder (not a broken image).
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
    test('maps an album, with coverArt as a credential-free reference', () {
      const dto = SubsonicAlbumDto(
        id: 'al-1',
        name: 'Drive',
        artist: 'Kavinsky',
        songCount: 12,
        year: 2011,
        coverArt: 'al-1',
      );
      final album = SubsonicTrackMapper.toAlbum(dto);
      expect(album.id, 'al-1');
      expect(album.title, 'Drive');
      expect(album.artistName, 'Kavinsky');
      expect(album.trackCount, 12);
      expect(album.year, 2011);
      expect(album.artworkUri, SubsonicArtwork.reference('al-1'));
    });

    test('maps an artist, with coverArt as a credential-free reference', () {
      const dto = SubsonicArtistDto(
        id: 'ar-1',
        name: 'Kavinsky',
        albumCount: 2,
        coverArt: 'ar-1',
      );
      final artist = SubsonicTrackMapper.toArtist(dto);
      expect(artist.id, 'ar-1');
      expect(artist.name, 'Kavinsky');
      expect(artist.albumCount, 2);
      expect(artist.artworkUri, SubsonicArtwork.reference('ar-1'));
    });

    test('album/artist artworkUri is null when there is no coverArt', () {
      const albumDto = SubsonicAlbumDto(id: 'al-1', name: 'Drive');
      const artistDto = SubsonicArtistDto(id: 'ar-1', name: 'Kavinsky');
      expect(SubsonicTrackMapper.toAlbum(albumDto).artworkUri, isNull);
      expect(SubsonicTrackMapper.toArtist(artistDto).artworkUri, isNull);
    });
  });
}
