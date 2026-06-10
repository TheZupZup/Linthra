import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_artwork_prewarm_service.dart';

Track _subsonic(String id, String coverId) => Track(
      id: id,
      title: 'Song $id',
      uri: 'subsonic:$id',
      artworkUri: Uri.parse('subsonic-cover:$coverId'),
    );

PlaybackState _playing(
        {Track? current, List<Track> upNext = const <Track>[]}) =>
    PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: current,
      upNext: upNext,
    );

/// Lets a state pushed onto the controller stream reach the service's listener
/// and its sequential drain run before assertions.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late StreamController<PlaybackState> states;
  late List<Uri> warmed;

  setUp(() {
    states = StreamController<PlaybackState>.broadcast();
    warmed = <Uri>[];
  });

  tearDown(() => states.close());

  MediaArtworkPrewarmService serviceWith({
    int lookahead = 3,
    Future<Uri?> Function(Uri reference)? warm,
  }) {
    final service = MediaArtworkPrewarmService(
      playbackStates: states.stream,
      lookahead: lookahead,
      warm: warm ??
          (Uri reference) async {
            warmed.add(reference);
            return Uri.parse('file:///cache/${reference.pathSegments.first}');
          },
    );
    addTearDown(service.dispose);
    return service;
  }

  test('warms the now-playing cover and the look-ahead up-next covers',
      () async {
    serviceWith(lookahead: 2);

    states.add(_playing(
      current: _subsonic('a', 'al-a'),
      upNext: <Track>[
        _subsonic('b', 'al-b'),
        _subsonic('c', 'al-c'),
        _subsonic('d', 'al-d'), // beyond the look-ahead of 2
      ],
    ));
    await _settle();

    expect(warmed, <Uri>[
      Uri.parse('subsonic-cover:al-a'),
      Uri.parse('subsonic-cover:al-b'),
      Uri.parse('subsonic-cover:al-c'),
    ]);
  });

  test('skips platform-loadable covers (Jellyfin http, local file) and nulls',
      () async {
    serviceWith();

    states.add(_playing(
      current: Track(
        id: 'jf',
        title: 'JF',
        uri: 'jellyfin:jf',
        artworkUri: Uri.parse('https://music.example.com/Items/jf/Images/1'),
      ),
      upNext: <Track>[
        Track(
          id: 'loc',
          title: 'Loc',
          uri: '/loc.mp3',
          artworkUri: Uri.parse('file:///cache/loc.img'),
        ),
        const Track(id: 'none', title: 'None', uri: 'subsonic:none'), // no art
        _subsonic('sub', 'al-sub'),
      ],
    ));
    await _settle();

    // Only the credential-free reference is warmed; http/file/no-art are skipped.
    expect(warmed, <Uri>[Uri.parse('subsonic-cover:al-sub')]);
  });

  test('warms each reference at most once across position ticks', () async {
    serviceWith();

    final Track current = _subsonic('a', 'al-a');
    final List<Track> up = <Track>[_subsonic('b', 'al-b')];
    states.add(_playing(current: current, upNext: up));
    await _settle();
    // Pure position/status ticks (same tracks) must not re-warm.
    states.add(_playing(current: current, upNext: up));
    states.add(_playing(current: current, upNext: up));
    await _settle();

    expect(warmed, <Uri>[
      Uri.parse('subsonic-cover:al-a'),
      Uri.parse('subsonic-cover:al-b'),
    ]);
  });

  test('warms a newly-surfaced cover when the queue advances', () async {
    serviceWith(lookahead: 1);

    states.add(_playing(
      current: _subsonic('a', 'al-a'),
      upNext: <Track>[_subsonic('b', 'al-b')],
    ));
    await _settle();
    // Advance: b is now current, c surfaces as the next up-next.
    states.add(_playing(
      current: _subsonic('b', 'al-b'),
      upNext: <Track>[_subsonic('c', 'al-c')],
    ));
    await _settle();

    // a + b from the first state, then only the new c (b isn't re-warmed).
    expect(warmed, <Uri>[
      Uri.parse('subsonic-cover:al-a'),
      Uri.parse('subsonic-cover:al-b'),
      Uri.parse('subsonic-cover:al-c'),
    ]);
  });

  test('a warm that fails or throws never breaks the service', () async {
    int attempts = 0;
    serviceWith(
      warm: (Uri reference) async {
        attempts++;
        if (attempts == 1) return null; // a failed fetch
        if (attempts == 2) throw const SocketExceptionStub(); // a thrown error
        warmed.add(reference);
        return Uri.parse('file:///ok');
      },
    );

    states.add(_playing(
      current: _subsonic('a', 'al-a'),
      upNext: <Track>[_subsonic('b', 'al-b'), _subsonic('c', 'al-c')],
    ));
    // Must not throw out of the listener / drain.
    await _settle();
    await _settle();

    // The first two outcomes (null, throw) are swallowed; the drain continues to
    // the third reference.
    expect(attempts, 3);
    expect(warmed, <Uri>[Uri.parse('subsonic-cover:al-c')]);
  });

  test('does nothing when there is no current track', () async {
    serviceWith();
    states.add(_playing()); // idle: no current, no up-next
    await _settle();
    expect(warmed, isEmpty);
  });

  test('warms a newly now-playing cover ahead of an earlier look-ahead',
      () async {
    // Priority: when the track changes while a previous batch's look-ahead is
    // still pending, the new now-playing cover jumps ahead of it.
    final gate = Completer<void>();
    final order = <String>[];
    final service = MediaArtworkPrewarmService(
      playbackStates: states.stream,
      lookahead: 3,
      warm: (Uri reference) async {
        final String id = reference.pathSegments.first;
        order.add(id);
        if (id == 'al-a') await gate.future; // hold the first warm in-flight
        return Uri.parse('content://x/$id.img');
      },
    );
    addTearDown(service.dispose);

    // Batch 1: a (now-playing) starts warming and blocks; b is queued behind it.
    states.add(_playing(
      current: _subsonic('a', 'al-a'),
      upNext: <Track>[_subsonic('b', 'al-b')],
    ));
    await _settle();
    // Batch 2: skip to x — its cover must jump ahead of the still-pending b.
    states.add(_playing(current: _subsonic('x', 'al-x')));
    await _settle();
    gate.complete(); // let the held first warm finish; the drain proceeds
    await _settle();
    await _settle();

    // a was already in-flight; x (the new now-playing) warmed before b.
    expect(order, <String>['al-a', 'al-x', 'al-b']);
  });

  test('retries a failed warm on a later queue change', () async {
    int attemptsForA = 0;
    final service = MediaArtworkPrewarmService(
      playbackStates: states.stream,
      lookahead: 1,
      warm: (Uri reference) async {
        if (reference == Uri.parse('subsonic-cover:al-a')) {
          attemptsForA++;
          // First attempt fails (transient), later attempts succeed.
          return attemptsForA == 1 ? null : Uri.parse('content://x/a.img');
        }
        return Uri.parse('content://x/${reference.pathSegments.first}.img');
      },
    );
    addTearDown(service.dispose);

    states.add(_playing(current: _subsonic('a', 'al-a')));
    await _settle();
    expect(attemptsForA, 1); // failed and was dropped from the warmed set

    // A queue change re-evaluates; al-a (still now-playing) retries rather than
    // staying coverless for the session.
    states.add(_playing(
      current: _subsonic('a', 'al-a'),
      upNext: <Track>[_subsonic('b', 'al-b')],
    ));
    await _settle();
    expect(attemptsForA, 2); // retried
  });
}

/// A throwable stand-in so the failure test doesn't depend on dart:io.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
