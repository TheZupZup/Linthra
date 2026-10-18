// A cover URL that carries a credential is never handed to the platform.
//
// isPlatformLoadableArtwork decides what the Android media session
// (LinthraAudioHandler._sessionArtUri -> MediaItem.artUri) and MPRIS
// (MprisPlayerObject._artUrl -> mpris:artUrl) publish unchanged. Any http(s)
// URL passed, on the assumption that a remote cover is token-free (Jellyfin's
// primary image), so a credentialed one would have reached another process
// (the system media session, Android Auto, a desktop shell) as is. No current
// path puts such a URL into Track.artworkUri, so this is defence in depth.
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/media_artwork_source.dart';

void main() {
  test('a credentialed http(s) cover is not platform-loadable as is', () {
    final List<String> passed = <String>[
      for (final String cover in <String>[
        'https://navi.example.com/rest/getCoverArt.view?u=a&t=TOKEN&s=SALT'
            '&id=al-1',
        'https://jelly.example.com/Items/1/Images/Primary?ApiKey=SECRET',
        'http://10.0.0.5:32400/photo/:/transcode?url=%2Fthumb'
            '&X-Plex-Token=SECRET',
        'https://alice:hunter2@jelly.example.com/Items/1/Images/Primary',
      ])
        if (isPlatformLoadableArtwork(Uri.parse(cover))) cover,
    ];

    expect(passed, isEmpty);
  });

  test('a token-free remote cover and local ones still load directly', () {
    for (final String cover in <String>[
      'https://jelly.example.com/Items/1/Images/Primary?maxWidth=512&tag=abc',
      'file:///data/user/0/app/cache/cover.jpg',
      'content://app.linthra.artwork/cover/1',
    ]) {
      expect(isPlatformLoadableArtwork(Uri.parse(cover)), isTrue,
          reason: cover);
    }
    // A reference is fetched first, as before.
    expect(
        isPlatformLoadableArtwork(Uri.parse('subsonic-cover:al-1')), isFalse);
  });
}
