import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/subsonic/subsonic_api.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/core/sources/subsonic/subsonic_track_mapper.dart';

void main() {
  group('SubsonicTrackMapper.toTrack', () {
    test('maps a song to a token-free subsonic: uri', () {
      final song = SubsonicSongDto(
        id: 'song-42',
        title: 'Nightcall',
        album: 'Drive',
        artist: 'Kavinsky',
        track: 3,
        dateCreated: DateTime.utc(2026, 10, 27, 14),
        durationSeconds: 256,
      );

      final track = SubsonicTrackMapper.toTrack(song);

      expect(track.id, 'song-42');
      expect(track.uri, 'subsonic:song-42');
      expect(track.title, 'Nightcall');
      expect(track.artistName, 'Kavinsky');
      expect(track.albumName, 'Drive');
      expect(track.trackNumber, 3);
      expect(track.serverAddedAt, DateTime.utc(2026, 10, 27, 14));
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

    // Issue #281: the album id is what keeps a collaboration track grouped
    // with its album, since Subsonic's classic response has no reliable
    // per-song album-artist field.
    test('maps the album id, namespaced like the track uri', () {
      const song = SubsonicSongDto(id: 's', title: 't', albumId: 'al-27');
      expect(SubsonicTrackMapper.toTrack(song).albumId, 'subsonic:al-27');
    });

    test('leaves the album id null when the server reports none', () {
      const song = SubsonicSongDto(id: 's', title: 't');
      expect(SubsonicTrackMapper.toTrack(song).albumId, isNull);
    });

    test('leaves the album id null for a blank server value', () {
      const song = SubsonicSongDto(id: 's', title: 't', albumId: '  ');
      expect(SubsonicTrackMapper.toTrack(song).albumId, isNull);
    });

    test('never guesses an album artist', () {
      // The classic Subsonic response carries no album-artist field distinct
      // from the song's own artist, so this stays null rather than reusing
      // `artist` — grouping falls back to the name-based tiers instead.
      const song = SubsonicSongDto(
        id: 's',
        title: 't',
        artist: 'Main Artist feat. Guest',
        album: 'The Album',
      );
      expect(SubsonicTrackMapper.toTrack(song).albumArtistName, isNull);
    });

    test('the album id never embeds a credential', () {
      const song = SubsonicSongDto(id: 's', title: 't', albumId: 'al-27');
      final track = SubsonicTrackMapper.toTrack(song);
      expect(track.albumId, isNot(contains('?')));
      expect(track.albumId, isNot(contains('t=')));
      expect(track.albumId, isNot(contains('http')));
    });
  });

  group('SubsonicSongDto.fromJson', () {
    test('parses the albumId the server reports', () {
      final dto = SubsonicSongDto.fromJson(<String, dynamic>{
        'id': 'tr-397',
        'title': 'As I Please',
        'album': '.limbo messiah',
        'albumId': 'al-27',
        'artist': 'Beatsteaks',
      })!;
      expect(dto.albumId, 'al-27');
    });

    test('leaves albumId null when the server omits it', () {
      final dto = SubsonicSongDto.fromJson(<String, dynamic>{
        'id': 'tr-397',
        'title': 'As I Please',
      })!;
      expect(dto.albumId, isNull);
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
