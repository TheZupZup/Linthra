import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/now_playing.dart';

Track _jelly(String id, {String title = 'Careful'}) => Track(
      id: id,
      title: title,
      uri: 'jellyfin:$id',
      artistName: 'NF',
      albumName: 'Perception',
      duration: const Duration(seconds: 200),
    );

Track _sub(String id, {String title = 'Careful'}) => Track(
      id: id,
      title: title,
      uri: 'subsonic:$id',
      artistName: 'NF',
      albumName: 'Perception',
      duration: const Duration(seconds: 200),
    );

void main() {
  group('NowPlaying.stateForRow', () {
    test('nothing playing -> no row is current', () {
      expect(const NowPlaying().stateForRow(_jelly('a')), isNull);
    });

    test('the current row animates while playback is playing', () {
      final Track track = _jelly('a');
      expect(
        NowPlaying(currentTrack: track, isPlaying: true).stateForRow(track),
        NowPlayingRowState.playing,
      );
    });

    test('the current row is static while playback is paused', () {
      final Track track = _jelly('a');
      expect(
        NowPlaying(currentTrack: track, isPlaying: false).stateForRow(track),
        NowPlayingRowState.paused,
      );
    });

    test('a different song shows nothing', () {
      final NowPlaying np = NowPlaying(
          currentTrack: _jelly('a', title: 'Alpha'), isPlaying: true);
      expect(np.stateForRow(_jelly('b', title: 'Beta')), isNull);
    });

    test('a fallback source copy still marks the logical song as current', () {
      // Navidrome copy is what actually plays; the Jellyfin row still lights up.
      final NowPlaying np =
          NowPlaying(currentTrack: _sub('s1'), isPlaying: true);
      expect(np.stateForRow(_jelly('j1')), NowPlayingRowState.playing);
    });

    test('the same logical song is current wherever it is shown', () {
      final Track current = _jelly('a');
      final NowPlaying np = NowPlaying(currentTrack: current, isPlaying: false);
      // Library row and a playlist row that are the same logical track (same id,
      // separate instances) both report current.
      final Track libraryRow = _jelly('a');
      final Track playlistRow = _jelly('a', title: 'Careful (from a playlist)');
      expect(np.stateForRow(libraryRow), NowPlayingRowState.paused);
      expect(np.stateForRow(playlistRow), NowPlayingRowState.paused);
    });
  });

  group('NowPlaying value', () {
    test('equals ignores everything but track + isPlaying', () {
      final Track t = _jelly('a');
      expect(
        NowPlaying(currentTrack: t, isPlaying: true),
        NowPlaying(currentTrack: t, isPlaying: true),
      );
      expect(
        NowPlaying(currentTrack: t, isPlaying: true),
        isNot(NowPlaying(currentTrack: t, isPlaying: false)),
      );
    });
  });

  group('nowPlayingProvider', () {
    test('defaults to nothing playing, with no engine dependency', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(nowPlayingProvider), const NowPlaying());
    });
  });
}
