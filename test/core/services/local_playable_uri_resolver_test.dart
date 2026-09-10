import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/reachability.dart';

import '../../support/fake_local_file_presence.dart';

void main() {
  group('LocalPlayableUriResolver', () {
    late FakeLocalFilePresence presence;
    late LocalPlayableUriResolver resolver;

    setUp(() {
      presence = FakeLocalFilePresence.all();
      resolver = LocalPlayableUriResolver(presence: presence);
    });

    test('resolves a filesystem path to a local-file source', () async {
      const track = Track(id: '1', title: 'One', uri: '/music/song.mp3');

      final resolved = await resolver.resolve(track);

      expect(resolved.uri, Uri.file('/music/song.mp3'));
      expect(resolved.uri.scheme, 'file');
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('passes a content:// URI through unchanged', () async {
      const raw = 'content://com.android.externalstorage.documents/'
          'tree/primary%3AMusic/document/primary%3AMusic%2FOne.mp3';
      const track = Track(id: raw, title: 'One', uri: raw);

      final resolved = await resolver.resolve(track);

      expect(resolved.uri.scheme, 'content');
      // Compare parsed URIs (not strings) so the assertion doesn't depend on
      // Dart's percent-encoding normalization of the content URI.
      expect(resolved.uri, Uri.parse(raw));
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('a content:// document is never probed on disk', () async {
      const raw = 'content://com.android.externalstorage.documents/tree/x';
      await resolver.resolve(const Track(id: raw, title: 'One', uri: raw));

      expect(presence.probed, isEmpty);
    });

    test('handles on-device tracks but not remote (Jellyfin/Subsonic) ones',
        () {
      const file = Track(id: '1', title: 'One', uri: '/music/song.mp3');
      const content = Track(id: '2', title: 'Two', uri: 'content://x/y');
      const jellyfin = Track(id: 't1', title: 'J', uri: 'jellyfin:t1');
      const subsonic = Track(id: 's1', title: 'S', uri: 'subsonic:s1');

      expect(resolver.handles(file), isTrue);
      expect(resolver.handles(content), isTrue);
      // Remote tracks are left to their own resolvers, composed ahead of this.
      expect(resolver.handles(jellyfin), isFalse);
      expect(resolver.handles(subsonic), isFalse);
    });

    group('when the file is no longer there', () {
      setUp(() => presence.present = <String>{'/music/still-here.mp3'});

      test('it fails with the local-file-missing kind', () async {
        const track = Track(id: '1', title: 'One', uri: '/music/gone.mp3');

        await expectLater(
          resolver.resolve(track),
          throwsA(
            isA<PlaybackResolutionException>().having(
              (PlaybackResolutionException e) => e.kind,
              'kind',
              PlaybackResolutionErrorKind.localFileMissing,
            ),
          ),
        );
      });

      test('the message says what happened without leaking the path', () async {
        const track = Track(
          id: '1',
          title: 'One',
          uri: '/home/someone/Music/private/gone.mp3',
        );

        try {
          await resolver.resolve(track);
          fail('expected a PlaybackResolutionException');
        } on PlaybackResolutionException catch (error) {
          expect(error.message, contains('moved or deleted'));
          expect(error.message, contains('Rescan'));
          expect(error.message, isNot(contains('/home/someone')));
        }
      });

      test('a file that is still there resolves normally', () async {
        const track =
            Track(id: '1', title: 'One', uri: '/music/still-here.mp3');

        final resolved = await resolver.resolve(track);

        expect(resolved.uri, Uri.file('/music/still-here.mp3'));
      });

      test('it says nothing about any server being unreachable', () {
        // A missing local file must not poison the provider-wide reachability
        // cache: a Jellyfin copy of the same song is still perfectly playable.
        expect(
          reachabilityFromPlaybackError(
            PlaybackResolutionErrorKind.localFileMissing,
          ),
          isNull,
        );
      });
    });
  });
}
