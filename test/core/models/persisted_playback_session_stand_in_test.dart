// The saved position belongs to the saved current song. When restore has to
// land on another one (the saved song is on a drive that isn't there, or its
// record is unreadable), that one starts from the top, not at the old song's
// position or its own very end (#793).
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';

import '../../features/player/fake_playback_controller.dart';

const Track _a = Track(
  id: 'a',
  title: 'A',
  uri: '/media/usb/a.flac',
  duration: Duration(minutes: 5),
);
const Track _b = Track(
  id: 'b',
  title: 'B',
  uri: '/music/b.flac',
  duration: Duration(minutes: 3),
);
const Track _c = Track(
  id: 'c',
  title: 'C',
  uri: '/music/c.flac',
  duration: Duration(minutes: 4),
);

const Duration _saved = Duration(minutes: 4, seconds: 10);

Map<String, dynamic> _record({
  Object? index = 0,
  List<Object?> tracks = const <Object?>[],
  Duration position = _saved,
  bool shuffle = false,
  List<Track>? original,
}) =>
    <String, dynamic>{
      'v': PersistedPlaybackSession.currentSchemaVersion,
      'i': index,
      'p': position.inMilliseconds,
      's': shuffle,
      'r': 'off',
      't': <Object?>[
        for (final Object? t in tracks) t is Track ? logicalTrackToJson(t) : t,
      ],
      if (original != null)
        'o': <Map<String, dynamic>>[
          for (final Track t in original) logicalTrackToJson(t),
        ],
    };

bool _notOnUsb(Track t) => t.uri != _a.uri;

void main() {
  group('the saved position (#793)', () {
    test('is kept when the saved song is restored', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(index: 0, tracks: <Track>[_a, _b, _c]),
      )!;

      expect(s.current, _a);
      expect(s.position, _saved);
    });

    test('is kept when songs before the saved one are left out', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(
          index: 1,
          tracks: <Track>[_a, _c, _b],
          position: const Duration(minutes: 2),
        ),
        isTrackRestorable: _notOnUsb,
      )!;

      expect(s.current, _c);
      expect(s.currentIndex, 0);
      expect(s.position, const Duration(minutes: 2));
    });

    test('is not carried to the song standing in for one left out', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(index: 0, tracks: <Track>[_a, _b, _c]),
        isTrackRestorable: _notOnUsb,
      )!;

      // 4:10 is past B's end; clamped, B would restore finished.
      expect(s.current, _b);
      expect(s.position, Duration.zero);
    });

    test('is not carried even when it would fit the stand-in', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(
          index: 0,
          tracks: <Track>[_a, _b, _c],
          position: const Duration(minutes: 1),
        ),
        isTrackRestorable: _notOnUsb,
      )!;

      expect(s.current, _b);
      expect(s.position, Duration.zero);
    });

    test('is not carried past a saved song whose record is unreadable', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(index: 0, tracks: <Object?>[
          <String, dynamic>{'id': 'a', 'uri': _a.uri}, // no title
          _b,
        ]),
      )!;

      expect(s.current, _b);
      expect(s.position, Duration.zero);
    });

    for (final Object? index in <Object?>[-1, 3, 99, '0', 1.5, null]) {
      test('is not applied to anything under a saved index of $index', () {
        final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
          _record(index: index, tracks: <Track>[_b, _c, _a]),
        )!;

        expect(s.current, _b);
        expect(s.position, Duration.zero);
      });
    }

    test('is kept on another copy of the saved song', () {
      // The saved entry (the second A) is unreadable; the first A is the
      // same song.
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(index: 2, tracks: <Object?>[
          _a,
          _b,
          <String, dynamic>{'id': 'a', 'uri': _a.uri},
        ]),
      )!;

      expect(s.current, _a);
      expect(s.currentIndex, 0);
      expect(s.position, _saved);
    });

    test('leaves the shuffle order alone when another song stands in', () {
      final PersistedPlaybackSession s = PersistedPlaybackSession.fromJson(
        _record(
          index: 0,
          tracks: <Track>[_a, _c, _b],
          shuffle: true,
          original: <Track>[_a, _b, _c],
        ),
        isTrackRestorable: _notOnUsb,
      )!;

      expect(s.current, _c);
      expect(s.position, Duration.zero);
      expect(s.shuffleEnabled, isTrue);
      expect(s.originalOrder, <Track>[_b, _c]);
    });

    test('a queue with nothing left to restore restores nothing', () {
      expect(
        PersistedPlaybackSession.fromJson(
          _record(index: 0, tracks: <Track>[_a]),
          isTrackRestorable: _notOnUsb,
        ),
        isNull,
      );
    });
  });

  test('launch with the drive unplugged starts the next song from the top',
      () async {
    final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
      const PersistedPlaybackSession(
        tracks: <Track>[_a, _b, _c],
        currentIndex: 0,
        position: _saved,
      ),
    );
    final FakePlaybackController controller = FakePlaybackController();
    final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
      store: store,
      controller: controller,
      playbackStates: controller.stateStream,
      localFileExists: (String uri) => uri != _a.uri,
      positionSaveInterval: Duration.zero,
    );
    addTearDown(controller.dispose);
    addTearDown(persistence.dispose);

    await persistence.restore();

    expect(controller.state.currentTrack, _b);
    expect(controller.lastRestorePosition, Duration.zero);
    // What was saved is still A at 4:10, for a launch with the drive back.
    final PersistedPlaybackSession? saved = await store.load();
    expect(saved!.current, _a);
    expect(saved.position, _saved);
  });
}
