import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/player/shuffle_play.dart';

import 'fake_playback_controller.dart';

List<Track> _album(int count) => <Track>[
      for (int i = 0; i < count; i++)
        Track(id: 't$i', title: 'Song $i', uri: '/music/$i.flac'),
    ];

/// A [Random] that always lands on the same index.
class _FixedRandom implements Random {
  _FixedRandom(this.index);

  final int index;

  @override
  int nextInt(int max) => index;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

void main() {
  test('starts from the song the shuffle picked, with shuffle on', () async {
    final FakePlaybackController controller = FakePlaybackController();
    final List<Track> album = _album(10);

    await playShuffled(controller, album, random: _FixedRandom(6));

    expect(controller.state.shuffleEnabled, isTrue);
    expect(controller.state.currentTrack?.uri, album[6].uri);
    expect(controller.state.upNext, hasLength(9));
  });

  test('does not always open with the first song', () async {
    // Before, every shuffle started on album[0] whatever the seed.
    final List<Track> album = _album(10);
    final Set<String> firstSongs = <String>{};
    for (int seed = 0; seed < 20; seed++) {
      final FakePlaybackController controller = FakePlaybackController();
      await playShuffled(controller, album, random: Random(seed));
      firstSongs.add(controller.state.currentTrack!.uri);
    }

    expect(firstSongs.length, greaterThan(1));
  });

  test('an empty collection plays nothing', () async {
    final FakePlaybackController controller = FakePlaybackController();

    await playShuffled(controller, const <Track>[]);

    expect(controller.state.currentTrack, isNull);
    expect(controller.state.shuffleEnabled, isFalse);
  });
}
