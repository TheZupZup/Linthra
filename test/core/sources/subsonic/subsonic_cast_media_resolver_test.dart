import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_cast_media_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';

class _FakeStreamSource implements SubsonicStreamSource {
  _FakeStreamSource({this.uri, this.verifyError});

  Uri? uri;
  SubsonicException? verifyError;

  @override
  Future<void> verifyReachable() async {
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<Uri?> resolvePlayableUri(Track track) async => uri;

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => uri;
}

const _track = Track(
  id: 's1',
  title: 'One',
  uri: 'subsonic:s1',
  artistName: 'Kavinsky',
  albumName: 'Drive',
  duration: Duration(minutes: 4, seconds: 5),
);

void main() {
  test('canCast is true for subsonic tracks only', () {
    final resolver = SubsonicCastMediaResolver(() => _FakeStreamSource());
    expect(resolver.canCast(_track), isTrue);
    expect(
      resolver.canCast(const Track(id: 'l', title: 'x', uri: '/a.mp3')),
      isFalse,
    );
  });

  test('resolves castable media from the minted stream URL', () async {
    final source = _FakeStreamSource(
      uri: Uri.parse(
          'https://music.example.com/rest/stream.view?id=s1&t=tok&s=salt'),
    );
    final resolver = SubsonicCastMediaResolver(() => source);

    final media = await resolver.resolve(_track);

    expect(media.url.queryParameters['id'], 's1');
    expect(media.title, 'One');
    expect(media.artist, 'Kavinsky');
    expect(media.album, 'Drive');
    expect(media.duration, const Duration(minutes: 4, seconds: 5));
    expect(media.contentType, 'audio/mpeg');
  });

  test('omits artwork: Subsonic cover art needs auth, so a token never leaks',
      () async {
    final source = _FakeStreamSource(
      uri: Uri.parse(
          'https://music.example.com/rest/stream.view?id=s1&t=tok&s=salt'),
    );
    final resolver = SubsonicCastMediaResolver(() => source);

    final media = await resolver.resolve(_track);

    // The cover-art endpoint would embed the salt+token, so it is deliberately
    // never sent to the receiver — only the stream URL carries the credential.
    expect(media.artworkUrl, isNull);
  });

  test('throws notSignedIn when no source is connected', () async {
    final resolver = SubsonicCastMediaResolver(() => null);
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<CastMediaException>()
          .having((e) => e.kind, 'kind', CastMediaErrorKind.notSignedIn)),
    );
  });

  test('maps an expired session to a sign-in-again cast error', () async {
    final resolver = SubsonicCastMediaResolver(
      () => _FakeStreamSource(verifyError: SubsonicException.unauthorized()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<CastMediaException>()
          .having((e) => e.kind, 'kind', CastMediaErrorKind.notSignedIn)),
    );
  });
}
