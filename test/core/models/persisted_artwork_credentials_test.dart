// A cover URL that signs in by itself never reaches the persisted queue.
//
// isPersistableArtworkUri keeps a credential-bearing cover URL out of the
// persisted queue (logicalTrackToJson), but its markers only knew the
// Jellyfin, Plex and OAuth spellings (api_key=, x-plex-token=,
// access_token=, ...). A resolved Subsonic getCoverArt URL carries the
// account's credentials as `t=` (token) with `s=` (salt), or `p=`
// (password), and passed, as did a `user:password@` address. No current
// path puts such a URL into Track.artworkUri, so this is defence in depth.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/track.dart';

void main() {
  const List<String> subsonicCovers = <String>[
    // Token auth, as SubsonicEndpoints builds it.
    'https://navi.example.com/rest/getCoverArt.view'
        '?u=alice&t=26719a1196d2a940705a59634eb18eab&s=c19b2d'
        '&v=1.16.1&c=Linthra&f=json&id=al-1&size=512',
    // Legacy password auth (hex-encoded password).
    'https://navi.example.com/rest/getCoverArt.view'
        '?u=alice&p=enc:68756e74657232&v=1.13.0&c=Linthra&id=al-1',
  ];

  test('a credentialed Subsonic cover URL is not persistable', () {
    final List<String> accepted = <String>[
      for (final String cover in subsonicCovers)
        if (isPersistableArtworkUri(Uri.parse(cover))) cover,
    ];

    expect(accepted, isEmpty);
  });

  test('nor is a cover whose address carries a user and password', () {
    expect(
      isPersistableArtworkUri(
        Uri.parse('https://alice:hunter2@jelly.example.com/Items/1/Images/'
            'Primary'),
      ),
      isFalse,
    );
  });

  test('credential-free covers are still persistable', () {
    for (final String cover in <String>[
      'https://jelly.example.com/Items/1/Images/Primary?maxWidth=512&tag=abc',
      'subsonic-cover:al-1',
      'plex-thumb:/library/metadata/1/thumb/2',
      '/storage/emulated/0/Music/cover.jpg',
      // A lone `t` is a cache-buster, not a Subsonic token.
      'https://cdn.example.com/cover.jpg?t=1700000000',
    ]) {
      expect(isPersistableArtworkUri(Uri.parse(cover)), isTrue, reason: cover);
    }
  });

  test('and so never reaches the persisted queue document', () {
    final Map<String, dynamic> json = logicalTrackToJson(
      Track(
        id: 'subsonic:tr-1',
        title: 'Song',
        uri: 'subsonic:tr-1',
        duration: const Duration(minutes: 3),
        artworkUri: Uri.parse(subsonicCovers.first),
      ),
    );

    expect(json.containsKey('artwork'), isFalse, reason: '${json['artwork']}');
  });
}
