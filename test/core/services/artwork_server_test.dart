import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/services/artwork_server.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';

const SubsonicSession _navidrome = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'salt',
  token: 'secret-token',
);

void main() {
  final Uri subsonicCover = SubsonicArtwork.reference('al-12');
  final Uri plexThumb = Uri.parse('plex-thumb:/library/metadata/1/thumb/1');

  test('a Subsonic cover is told apart by its server, never in the clear', () {
    final String? server = artworkServerOf(subsonicCover, subsonic: _navidrome);

    expect(server, startsWith('subsonic:'));
    expect(server, isNot(contains('music.example.com')));
    expect(server, isNot(contains('alice')));
    expect(server, isNot(contains('secret-token')));
    expect(
      artworkServerOf(
        subsonicCover,
        subsonic: const SubsonicSession(
          baseUrl: 'https://other.example.com',
          username: 'alice',
          salt: 'salt',
          token: 'secret-token',
        ),
      ),
      isNot(server),
    );
    // Another user on the same server sees the same covers.
    expect(
      artworkServerOf(
        subsonicCover,
        subsonic: const SubsonicSession(
          baseUrl: 'https://music.example.com',
          username: 'bob',
          salt: 'pepper',
          token: 'other-token',
        ),
      ),
      server,
    );
  });

  test('a Plex cover is told apart by its machine identifier', () {
    const PlexSession plex = PlexSession(
      baseUrl: 'https://plex.example.com',
      token: 'plex-token',
      machineIdentifier: 'machine-1',
    );

    expect(artworkServerOf(plexThumb, plex: plex), 'plex:machine-1');
  });

  test('signed out, a reference has no server', () {
    expect(artworkServerOf(subsonicCover), isNull);
    expect(artworkServerOf(plexThumb), isNull);
  });

  test('a URL names its own server', () {
    expect(
      artworkServerOf(Uri.parse('https://jf.example/Items/1/Images/Primary')),
      '',
    );
  });
}
