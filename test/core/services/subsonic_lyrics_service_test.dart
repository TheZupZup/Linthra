import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/subsonic_lyrics_service.dart';

import '../sources/subsonic/fake_subsonic_client.dart';

const _session = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt1',
  token: 'tok1',
);

void main() {
  group('SubsonicLyricsService', () {
    late FakeSubsonicClient client;

    setUp(() => client = FakeSubsonicClient());

    SubsonicLyricsService build({SubsonicSession? session}) =>
        SubsonicLyricsService(client: client, session: () => session);

    test('fetches a Subsonic track by song id, forwarding artist and title',
        () async {
      client.lyrics = const Lyrics(lines: <LyricLine>[LyricLine(text: 'la la')]);
      final service = build(session: _session);

      final lyrics = await service.lyricsFor(
        const Track(
          id: 's-7',
          title: 'Nightcall',
          uri: 'subsonic:s-7',
          artistName: 'Kavinsky',
        ),
      );

      expect(client.lastLyricsSongId, 's-7');
      expect(client.lastLyricsArtist, 'Kavinsky');
      expect(client.lastLyricsTitle, 'Nightcall');
      expect(lyrics?.lines.single.text, 'la la');
    });

    test('returns null for a non-Subsonic track without hitting the server',
        () async {
      final service = build(session: _session);

      final jellyfin = await service.lyricsFor(
        const Track(id: 'j-1', title: 'Song', uri: 'jellyfin:j-1'),
      );
      final local = await service.lyricsFor(
        const Track(id: '1', title: 'Local', uri: 'file:///1.mp3'),
      );

      expect(jellyfin, isNull);
      expect(local, isNull);
      expect(client.lastLyricsSongId, isNull);
    });

    test('returns null when signed out', () async {
      final service = build(session: null);

      final lyrics = await service.lyricsFor(
        const Track(id: 's-7', title: 'Song', uri: 'subsonic:s-7'),
      );

      expect(lyrics, isNull);
      expect(client.lastLyricsSongId, isNull);
    });
  });
}
