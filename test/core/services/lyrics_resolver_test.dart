import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/jellyfin_session.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/jellyfin_lyrics_provider.dart';
import 'package:linthra/core/services/local_lyrics_provider.dart';
import 'package:linthra/core/services/lyrics_provider.dart';
import 'package:linthra/core/services/lyrics_resolver.dart';
import 'package:linthra/core/services/no_lyrics_provider.dart';
import 'package:linthra/core/services/subsonic_lyrics_provider.dart';
import 'package:linthra/core/sources/local/local_lyrics_reader.dart';
import 'package:linthra/core/sources/music_provider.dart';

import '../sources/jellyfin/fake_jellyfin_client.dart';
import '../sources/subsonic/fake_subsonic_client.dart';

/// A [LyricsProvider] that returns canned lyrics (or throws), and records
/// whether it was asked — so routing, order, and short-circuit behaviour can
/// be asserted.
class _StubLyricsProvider implements LyricsProvider {
  _StubLyricsProvider(this.sourceId, {this.lyrics, this.error});

  @override
  final String sourceId;
  final Lyrics? lyrics;
  final Object? error;
  bool called = false;

  @override
  Future<Lyrics?> lyricsFor(Track track) async {
    called = true;
    if (error != null) throw error!;
    return lyrics;
  }
}

/// A [LocalLyricsReader] serving one canned `.lrc`, recording what it was
/// asked for.
class _FakeLocalLyricsReader implements LocalLyricsReader {
  _FakeLocalLyricsReader({this.lrc});

  final String? lrc;
  final List<String> requestedExtensions = <String>[];

  @override
  Future<String?> readSidecar(String trackUri, String extension) async {
    requestedExtensions.add(extension);
    return extension == 'lrc' ? lrc : null;
  }
}

const _jellyfinTrack = Track(id: 'j-1', title: 'Song', uri: 'jellyfin:j-1');
const _subsonicTrack = Track(id: 's-1', title: 'Song', uri: 'subsonic:s-1');
const _plexTrack = Track(id: 'p-1', title: 'Song', uri: 'plex:101');
const _localTrack =
    Track(id: 'l-1', title: 'Song', uri: 'file:///music/Song.mp3');

const _plain = Lyrics(lines: <LyricLine>[LyricLine(text: 'la la')]);
const _synced = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'first', start: Duration.zero),
  LyricLine(text: 'second', start: Duration(seconds: 5)),
]);

void main() {
  group('LyricsResolver routing', () {
    test('routes each track to the provider registered for its source',
        () async {
      final jellyfin = _StubLyricsProvider('jellyfin', lyrics: _plain);
      final subsonic = _StubLyricsProvider('subsonic', lyrics: _synced);
      final local = _StubLyricsProvider('local', lyrics: _plain);
      final resolver =
          LyricsResolver(<LyricsProvider>[jellyfin, subsonic, local]);

      expect(await resolver.lyricsFor(_subsonicTrack), _synced);
      expect(subsonic.called, isTrue);
      // The other sources' providers were never consulted for it.
      expect(jellyfin.called, isFalse);
      expect(local.called, isFalse);
    });

    test('a local path and a content:// document both route to local',
        () async {
      final local = _StubLyricsProvider('local', lyrics: _plain);
      final jellyfin = _StubLyricsProvider('jellyfin', lyrics: _synced);
      final resolver = LyricsResolver(<LyricsProvider>[jellyfin, local]);

      expect(await resolver.lyricsFor(_localTrack), _plain);
      expect(
        await resolver.lyricsFor(
          const Track(id: 'c', title: 'S', uri: 'content://docs/tree/x'),
        ),
        _plain,
      );
      expect(jellyfin.called, isFalse);
    });

    test(
        'missing lyrics are not an error: a source with no registered '
        'provider resolves to null', () async {
      final resolver = LyricsResolver(<LyricsProvider>[
        _StubLyricsProvider('jellyfin', lyrics: _plain),
      ]);

      expect(await resolver.lyricsFor(_subsonicTrack), isNull);
    });

    test(
        'the empty resolver (the default binding) resolves every track to '
        'null', () async {
      expect(await LyricsResolver.none.lyricsFor(_jellyfinTrack), isNull);
      expect(await LyricsResolver.none.lyricsFor(_localTrack), isNull);
      expect(await LyricsResolver.none.lyricsFor(_plexTrack), isNull);
    });

    test('a provider that declines (null) resolves to null', () async {
      final jellyfin = _StubLyricsProvider('jellyfin');
      final resolver = LyricsResolver(<LyricsProvider>[jellyfin]);

      expect(await resolver.lyricsFor(_jellyfinTrack), isNull);
      expect(jellyfin.called, isTrue);
    });

    test('plain and synced lyrics pass through unchanged', () async {
      final resolver = LyricsResolver(<LyricsProvider>[
        _StubLyricsProvider('jellyfin', lyrics: _plain),
        _StubLyricsProvider('subsonic', lyrics: _synced),
      ]);

      final plain = await resolver.lyricsFor(_jellyfinTrack);
      expect(plain, _plain);
      expect(plain!.isSynced, isFalse);

      final synced = await resolver.lyricsFor(_subsonicTrack);
      expect(synced, _synced);
      expect(synced!.isSynced, isTrue);
    });

    test(
        'propagates a provider failure so the UI can tell "couldn\'t load" '
        'apart from "no lyrics"', () async {
      final resolver = LyricsResolver(<LyricsProvider>[
        _StubLyricsProvider('jellyfin', error: StateError('offline')),
      ]);

      expect(
        () => resolver.lyricsFor(_jellyfinTrack),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('LyricsResolver same-source fallback', () {
    test(
        'asks providers for the owning source in registration order and the '
        'first with lyrics wins', () async {
      // Two providers for the same source — e.g. a sidecar reader ahead of a
      // future embedded-tag reader.
      final first = _StubLyricsProvider('local'); // declines
      final second = _StubLyricsProvider('local', lyrics: _plain);
      final resolver = LyricsResolver(<LyricsProvider>[first, second]);

      expect(await resolver.lyricsFor(_localTrack), _plain);
      expect(first.called, isTrue);
      expect(second.called, isTrue);
    });

    test('short-circuits: a later provider is not asked once one answers',
        () async {
      final first = _StubLyricsProvider('local', lyrics: _synced);
      final second = _StubLyricsProvider('local', lyrics: _plain);
      final resolver = LyricsResolver(<LyricsProvider>[first, second]);

      expect(await resolver.lyricsFor(_localTrack), _synced);
      expect(second.called, isFalse);
    });

    test('resolves to null when every provider for the source declines',
        () async {
      final resolver = LyricsResolver(<LyricsProvider>[
        _StubLyricsProvider('local'),
        _StubLyricsProvider('local'),
      ]);

      expect(await resolver.lyricsFor(_localTrack), isNull);
    });
  });

  group('LyricsResolver and the Plex placeholder', () {
    test(
        'a plex: track resolves to "no lyrics" via NoLyricsProvider without '
        'consulting any other source\'s provider', () async {
      // Regression guard for the drift this resolver exists to prevent: the
      // old per-backend scheme blacklists predated `plex:`, so a Plex track
      // fell through to the local sidecar reader.
      final local = _StubLyricsProvider('local', lyrics: _plain);
      final resolver = LyricsResolver(<LyricsProvider>[
        _StubLyricsProvider('jellyfin', lyrics: _plain),
        local,
        NoLyricsProvider(MusicProviders.plex.sourceId),
      ]);

      expect(await resolver.lyricsFor(_plexTrack), isNull);
      expect(local.called, isFalse);
    });

    test('a plex: track resolves to null even with no placeholder registered',
        () async {
      final local = _StubLyricsProvider('local', lyrics: _plain);
      final resolver = LyricsResolver(<LyricsProvider>[local]);

      expect(await resolver.lyricsFor(_plexTrack), isNull);
      expect(local.called, isFalse);
    });

    test('NoLyricsProvider always resolves to null', () async {
      const provider = NoLyricsProvider('plex');
      expect(provider.sourceId, 'plex');
      expect(await provider.lyricsFor(_plexTrack), isNull);
    });
  });

  // The production wiring shape: the real providers + fakes, proving each
  // source still resolves through its own backend (the behaviour the old
  // CompositeLyricsService tests guarded).
  group('LyricsResolver with the shipped providers', () {
    const jellyfinSession = JellyfinSession(
      baseUrl: 'https://music.example.com',
      userId: 'user-1',
      accessToken: 'tok',
      deviceId: 'device-1',
    );
    const subsonicSession = SubsonicSession(
      baseUrl: 'https://music.example.com',
      username: 'alice',
      salt: 'salt1',
      token: 'tok1',
    );

    late FakeJellyfinClient jellyfin;
    late FakeSubsonicClient subsonic;
    late _FakeLocalLyricsReader reader;
    late LyricsResolver resolver;

    setUp(() {
      jellyfin = FakeJellyfinClient();
      subsonic = FakeSubsonicClient();
      reader = _FakeLocalLyricsReader(lrc: '[00:01.00]local line\n');
      resolver = LyricsResolver(<LyricsProvider>[
        JellyfinLyricsProvider(
          client: jellyfin,
          session: () => jellyfinSession,
        ),
        SubsonicLyricsProvider(
          client: subsonic,
          session: () => subsonicSession,
        ),
        LocalLyricsProvider(reader),
        NoLyricsProvider(MusicProviders.plex.sourceId),
      ]);
    });

    test('a Jellyfin track resolves via Jellyfin, untouched by local',
        () async {
      jellyfin.lyrics = const Lyrics(lines: <LyricLine>[LyricLine(text: 'jf')]);

      final Lyrics? lyrics = await resolver.lyricsFor(
        const Track(id: 'j-7', title: 'Song', uri: 'jellyfin:j-7'),
      );

      expect(lyrics?.lines.single.text, 'jf');
      expect(jellyfin.lastLyricsItemId, 'j-7');
      // The local reader was never consulted for a remote track.
      expect(reader.requestedExtensions, isEmpty);
    });

    test('a Subsonic track resolves via Subsonic, untouched by local',
        () async {
      subsonic.lyrics =
          const Lyrics(lines: <LyricLine>[LyricLine(text: 'sub')]);

      final Lyrics? lyrics = await resolver.lyricsFor(
        const Track(id: 's-7', title: 'Song', uri: 'subsonic:s-7'),
      );

      expect(lyrics?.lines.single.text, 'sub');
      expect(subsonic.lastLyricsSongId, 's-7');
      expect(reader.requestedExtensions, isEmpty);
    });

    test('a local track resolves via the local sidecar', () async {
      final Lyrics? lyrics = await resolver.lyricsFor(_localTrack);

      expect(lyrics?.lines.single.text, 'local line');
      // The remote backends were never hit for a local track.
      expect(jellyfin.lastLyricsItemId, isNull);
      expect(subsonic.lastLyricsSongId, isNull);
    });

    test('a Plex track stays on "no lyrics" without touching any backend',
        () async {
      final Lyrics? lyrics = await resolver.lyricsFor(_plexTrack);

      expect(lyrics, isNull);
      expect(jellyfin.lastLyricsItemId, isNull);
      expect(subsonic.lastLyricsSongId, isNull);
      expect(reader.requestedExtensions, isEmpty);
    });
  });
}
