import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_history.dart';
import 'package:linthra/core/models/track.dart';

Track _track(String id, {String? uri}) => Track(
      id: id,
      title: 'Song $id',
      uri: uri ?? 'jellyfin:$id',
      artistName: 'Artist $id',
    );

DateTime _at(int minute) => DateTime.utc(2026, 1, 1, 12, minute);

PlaybackHistory _recordAll(
  PlaybackHistory history,
  Iterable<Track> tracks, {
  PlaybackHistoryOutcome outcome = PlaybackHistoryOutcome.completed,
}) {
  PlaybackHistory next = history;
  int minute = 0;
  for (final Track track in tracks) {
    next = next.record(track, outcome: outcome, at: _at(minute++));
  }
  return next;
}

void main() {
  group('PlaybackHistory ordering', () {
    test('starts empty', () {
      expect(PlaybackHistory.empty.isEmpty, isTrue);
      expect(PlaybackHistory.empty.entries, isEmpty);
    });

    test('the most recently played track is first', () {
      final PlaybackHistory history = _recordAll(
        PlaybackHistory.empty,
        <Track>[_track('1'), _track('2'), _track('3')],
      );
      expect(
        <String>[for (final e in history.entries) e.track.id],
        <String>['3', '2', '1'],
      );
    });

    test('replaying a track moves it to the front instead of duplicating it',
        () {
      PlaybackHistory history = _recordAll(
        PlaybackHistory.empty,
        <Track>[_track('1'), _track('2')],
      );
      history = history.record(
        _track('1'),
        outcome: PlaybackHistoryOutcome.skipped,
        at: _at(9),
      );

      expect(history.length, 2, reason: 'one entry per track, not per play');
      expect(history.entries.first.track.id, '1');
      expect(history.entries.first.outcome, PlaybackHistoryOutcome.skipped);
      expect(history.entries.first.playedAt, _at(9));
    });

    test('two providers copies of one song are separate entries', () {
      // They share a bare id but not a uri, and they are different rows in a
      // list whose whole purpose is replaying one of them.
      final PlaybackHistory history = _recordAll(
        PlaybackHistory.empty,
        <Track>[
          _track('101', uri: 'jellyfin:101'),
          _track('101', uri: 'subsonic:101'),
        ],
      );
      expect(history.length, 2);
    });

    test('the outcome is carried per entry', () {
      PlaybackHistory history = PlaybackHistory.empty.record(
        _track('1'),
        outcome: PlaybackHistoryOutcome.completed,
        at: _at(0),
      );
      history = history.record(
        _track('2'),
        outcome: PlaybackHistoryOutcome.skipped,
        at: _at(1),
      );
      expect(history.entryFor('jellyfin:2')!.wasCompleted, isFalse);
      expect(history.entryFor('jellyfin:1')!.wasCompleted, isTrue);
      expect(history.entryFor('jellyfin:missing'), isNull);
    });
  });

  group('the retention bound', () {
    test('the documented default is 50', () {
      expect(PlaybackHistory.defaultLimit, 50);
      expect(PlaybackHistory.empty.limit, 50);
    });

    test('a long session never grows past the bound', () {
      final PlaybackHistory history = _recordAll(
        const PlaybackHistory(limit: 3),
        <Track>[for (int i = 0; i < 200; i++) _track('$i')],
      );
      expect(history.length, 3);
    });

    test('the oldest entries are the ones that roll off', () {
      final PlaybackHistory history = _recordAll(
        const PlaybackHistory(limit: 2),
        <Track>[_track('1'), _track('2'), _track('3')],
      );
      expect(
        <String>[for (final e in history.entries) e.track.id],
        <String>['3', '2'],
      );
      expect(history.entryFor('jellyfin:1'), isNull);
    });

    test('a repeated track cannot push the rest of the list off the end', () {
      PlaybackHistory history = _recordAll(
        const PlaybackHistory(limit: 3),
        <Track>[_track('1'), _track('2'), _track('3')],
      );
      for (int i = 0; i < 20; i++) {
        history = history.record(
          _track('3'),
          outcome: PlaybackHistoryOutcome.completed,
          at: _at(10 + i),
        );
      }
      expect(history.length, 3);
      expect(history.entryFor('jellyfin:1'), isNotNull);
    });

    test('clearing empties it and keeps the bound', () {
      final PlaybackHistory history = _recordAll(
        const PlaybackHistory(limit: 4),
        <Track>[_track('1')],
      ).cleared();
      expect(history.isEmpty, isTrue);
      expect(history.limit, 4);
    });
  });

  group('only logical identities get in', () {
    test('an authenticated stream URL is refused outright', () {
      final PlaybackHistory history = PlaybackHistory.empty.record(
        _track(
          '1',
          uri: 'https://media.example.com/Audio/101/stream?api_key=secret',
        ),
        outcome: PlaybackHistoryOutcome.completed,
        at: _at(0),
      );
      expect(history.isEmpty, isTrue);
    });

    test('any http(s) uri is refused, token or not', () {
      final PlaybackHistory history = PlaybackHistory.empty.record(
        _track('1', uri: 'http://media.example.com/song.mp3'),
        outcome: PlaybackHistoryOutcome.completed,
        at: _at(0),
      );
      expect(history.isEmpty, isTrue);
    });

    test('provider ids and local paths are kept', () {
      final PlaybackHistory history = _recordAll(
        PlaybackHistory.empty,
        <Track>[
          _track('1', uri: 'jellyfin:101'),
          _track('2', uri: 'subsonic:202'),
          _track('3', uri: 'plex:303'),
          _track('4', uri: '/home/listener/Music/song.flac'),
        ],
      );
      expect(history.length, 4);
    });

    test('nothing in a recorded entry can be a playable source', () {
      final PlaybackHistory history = _recordAll(
        PlaybackHistory.empty,
        <Track>[_track('1')],
      );
      for (final PlaybackHistoryEntry entry in history.entries) {
        expect(entry.track.uri, isNot(startsWith('http')));
        expect(entry.track.uri.toLowerCase(), isNot(contains('token')));
        expect(entry.track.uri.toLowerCase(), isNot(contains('api_key')));
      }
    });
  });
}
