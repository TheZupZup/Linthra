import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_track_mapper.dart';

const String _baseUrl = 'https://music.example.com';

void main() {
  group('JellyfinTrackMapper.toTrack', () {
    test('maps the core fields and a token-free uri', () {
      const item = JellyfinItemDto(
        id: 'track-1',
        name: 'Song Title',
        album: 'The Album',
        albumArtist: 'The Artist',
        // 4 minutes in Jellyfin ticks (10,000,000 ticks per second).
        runTimeTicks: 2400000000,
        indexNumber: 3,
        hasPrimaryImage: true,
      );

      final track = JellyfinTrackMapper.toTrack(item, baseUrl: _baseUrl);

      expect(track.id, 'track-1');
      expect(track.title, 'Song Title');
      expect(track.uri, 'jellyfin:track-1');
      expect(track.artistName, 'The Artist');
      expect(track.albumName, 'The Album');
      expect(track.duration, const Duration(minutes: 4));
      expect(track.trackNumber, 3);
      expect(
        track.artworkUri,
        Uri.parse('$_baseUrl/Items/track-1/Images/Primary'),
      );
    });

    test('keeps the token out of the uri', () {
      const item = JellyfinItemDto(id: 'abc', name: 'X');
      final track = JellyfinTrackMapper.toTrack(item, baseUrl: _baseUrl);
      expect(track.uri, isNot(contains('http')));
      expect(track.uri, isNot(contains('ApiKey')));
    });

    test('falls back to the first listed artist when no album artist', () {
      const item = JellyfinItemDto(
        id: 't',
        name: 'n',
        artists: <String>['First Artist', 'Second Artist'],
      );
      final track = JellyfinTrackMapper.toTrack(item, baseUrl: _baseUrl);
      expect(track.artistName, 'First Artist');
    });

    test('leaves artist null when none is provided', () {
      const item = JellyfinItemDto(id: 't', name: 'n');
      final track = JellyfinTrackMapper.toTrack(item, baseUrl: _baseUrl);
      expect(track.artistName, isNull);
    });

    test('maps absent or zero ticks to zero duration', () {
      const noTicks = JellyfinItemDto(id: 't', name: 'n');
      const zeroTicks = JellyfinItemDto(id: 't2', name: 'n', runTimeTicks: 0);
      expect(
        JellyfinTrackMapper.toTrack(noTicks, baseUrl: _baseUrl).duration,
        Duration.zero,
      );
      expect(
        JellyfinTrackMapper.toTrack(zeroTicks, baseUrl: _baseUrl).duration,
        Duration.zero,
      );
    });

    test('omits artwork when there is no primary image', () {
      const item = JellyfinItemDto(id: 't', name: 'n');
      final track = JellyfinTrackMapper.toTrack(item, baseUrl: _baseUrl);
      expect(track.artworkUri, isNull);
    });
  });

  group('JellyfinTrackMapper.toAlbum', () {
    test('maps album fields including track count and year', () {
      const item = JellyfinItemDto(
        id: 'album-1',
        name: 'Greatest Hits',
        albumArtist: 'The Artist',
        productionYear: 1999,
        childCount: 12,
        hasPrimaryImage: true,
      );

      final album = JellyfinTrackMapper.toAlbum(item, baseUrl: _baseUrl);

      expect(album.id, 'album-1');
      expect(album.title, 'Greatest Hits');
      expect(album.artistName, 'The Artist');
      expect(album.year, 1999);
      expect(album.trackCount, 12);
      expect(
        album.artworkUri,
        Uri.parse('$_baseUrl/Items/album-1/Images/Primary'),
      );
    });

    test('defaults track count to zero when absent', () {
      const item = JellyfinItemDto(id: 'a', name: 'n');
      expect(
          JellyfinTrackMapper.toAlbum(item, baseUrl: _baseUrl).trackCount, 0);
    });
  });

  group('JellyfinTrackMapper.toArtist', () {
    test('maps artist id, name, and artwork', () {
      const item = JellyfinItemDto(
          id: 'artist-1', name: 'The Artist', hasPrimaryImage: true);

      final artist = JellyfinTrackMapper.toArtist(item, baseUrl: _baseUrl);

      expect(artist.id, 'artist-1');
      expect(artist.name, 'The Artist');
      expect(
        artist.artworkUri,
        Uri.parse('$_baseUrl/Items/artist-1/Images/Primary'),
      );
    });
  });
}
