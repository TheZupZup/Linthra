import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/plex_lyrics_provider.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

import '../sources/plex/fake_plex_client.dart';

const _session = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'plex-token',
  machineIdentifier: 'machine-1',
);

void main() {
  group('PlexLyricsProvider', () {
    late FakePlexClient client;

    setUp(() => client = FakePlexClient());

    PlexLyricsProvider build({PlexSession? session}) =>
        PlexLyricsProvider(client: client, session: () => session);

    test('declares the plex source id the resolver routes by', () {
      expect(build(session: _session).sourceId, 'plex');
    });

    test('fetches lyrics for a Plex track by its ratingKey', () async {
      client.lyrics = const Lyrics(
        lines: <LyricLine>[LyricLine(text: 'la la')],
      );
      final provider = build(session: _session);

      final lyrics = await provider.lyricsFor(
        const Track(id: '42', title: 'Song', uri: 'plex:42'),
      );

      expect(client.requestedLyricsRatingKeys, <String>['42']);
      expect(client.lastBaseUrl, 'https://plex.example.com:32400');
      expect(client.lastToken, 'plex-token');
      expect(lyrics?.lines.single.text, 'la la');
    });

    test('returns "no lyrics" (null) when the server has none', () async {
      client.lyrics = null; // The default; a track with no lyric stream.
      final provider = build(session: _session);

      final lyrics = await provider.lyricsFor(
        const Track(id: '42', title: 'Song', uri: 'plex:42'),
      );

      expect(lyrics, isNull);
      expect(client.requestedLyricsRatingKeys, <String>['42']);
    });

    test('a fetch failure propagates so the UI can show "couldn\'t load"',
        () async {
      client.lyricsError = PlexException.notReachable();
      final provider = build(session: _session);

      await expectLater(
        provider.lyricsFor(
          const Track(id: '42', title: 'Song', uri: 'plex:42'),
        ),
        throwsA(isA<PlexException>()),
      );
    });

    test('returns null for a non-Plex track without hitting the server',
        () async {
      final provider = build(session: _session);

      final lyrics = await provider.lyricsFor(
        const Track(id: '1', title: 'Local', uri: 'file:///1.mp3'),
      );

      expect(lyrics, isNull);
      expect(client.requestedLyricsRatingKeys, isEmpty);
    });

    test('returns null when signed out (no session), no server call', () async {
      final provider = build(session: null);

      final lyrics = await provider.lyricsFor(
        const Track(id: '42', title: 'Song', uri: 'plex:42'),
      );

      expect(lyrics, isNull);
      expect(client.requestedLyricsRatingKeys, isEmpty);
    });

    test('returns null for a plex: uri carrying no ratingKey, no server call',
        () async {
      final provider = build(session: _session);

      final lyrics = await provider.lyricsFor(
        const Track(id: '', title: 'Broken', uri: 'plex:'),
      );

      expect(lyrics, isNull);
      expect(client.requestedLyricsRatingKeys, isEmpty);
    });
  });
}
