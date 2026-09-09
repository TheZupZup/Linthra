import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/track_selection.dart';

/// The awkward halves of desktop multi-select (#387): an anchor for a row that
/// has since been filtered out, a range dragged backwards, and a selection that
/// outlives the tracks it named. All of it decided here, where it can be
/// checked without pumping a list.
List<Track> _tracks(int count, {String provider = 'jellyfin'}) => <Track>[
      for (int i = 0; i < count; i++)
        Track(id: '$i', title: 'Song $i', uri: '$provider:$i'),
    ];

List<String> _titles(List<Track> tracks) =>
    <String>[for (final Track track in tracks) track.title];

void main() {
  group('TrackSelection', () {
    test('starts empty', () {
      final TrackSelection selection = TrackSelection();
      expect(selection.isActive, isFalse);
      expect(selection.length, 0);
      expect(selection.anchorUri, isNull);
    });

    test('a long-press replaces whatever was picked', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()
        ..toggle(tracks[0])
        ..toggle(tracks[1])
        ..start(tracks[3]);

      expect(_titles(selection.resolve(tracks)), <String>['Song 3']);
      expect(selection.anchorUri, tracks[3].uri);
    });

    test('Ctrl-click adds and removes one row at a time', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()
        ..toggle(tracks[0])
        ..toggle(tracks[2]);
      expect(_titles(selection.resolve(tracks)), <String>['Song 0', 'Song 2']);

      selection.toggle(tracks[0]);
      expect(_titles(selection.resolve(tracks)), <String>['Song 2']);

      selection.toggle(tracks[2]);
      expect(selection.isActive, isFalse);
      // Nothing left to extend from.
      expect(selection.anchorUri, isNull);
    });

    test('Shift-click takes everything between, in either direction', () {
      final List<Track> tracks = _tracks(6);
      final TrackSelection down = TrackSelection()
        ..start(tracks[1])
        ..extendTo(tracks, 4);
      expect(
        _titles(down.resolve(tracks)),
        <String>['Song 1', 'Song 2', 'Song 3', 'Song 4'],
      );

      final TrackSelection up = TrackSelection()
        ..start(tracks[4])
        ..extendTo(tracks, 1);
      expect(
        _titles(up.resolve(tracks)),
        <String>['Song 1', 'Song 2', 'Song 3', 'Song 4'],
      );
    });

    test('the anchor stays put, so a range can be dragged back', () {
      final List<Track> tracks = _tracks(6);
      final TrackSelection selection = TrackSelection()
        ..start(tracks[1])
        ..extendTo(tracks, 5)
        ..extendTo(tracks, 2);

      expect(selection.anchorUri, tracks[1].uri);
      // Everything reached so far stays picked: extending never un-picks, which
      // is what makes Ctrl-click the way to drop a row.
      expect(selection.length, 5);
    });

    test('Shift-click with no anchor is just a click', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()..extendTo(tracks, 2);

      expect(_titles(selection.resolve(tracks)), <String>['Song 2']);
      expect(selection.anchorUri, tracks[2].uri);
    });

    test('an anchor filtered out of the list cannot select a stray run', () {
      final List<Track> all = _tracks(6);
      final TrackSelection selection = TrackSelection()..start(all[0]);

      // The search narrowed the list, and the anchored row is no longer in it.
      final List<Track> filtered = <Track>[all[3], all[4], all[5]];
      selection.extendTo(filtered, 2);

      expect(_titles(selection.resolve(filtered)), <String>['Song 5']);
    });

    test('an index outside the list does nothing', () {
      final List<Track> tracks = _tracks(3);
      final TrackSelection selection = TrackSelection()..start(tracks[0]);

      selection
        ..extendTo(tracks, 7)
        ..extendTo(tracks, -1)
        ..extendTo(<Track>[], 0);

      expect(_titles(selection.resolve(tracks)), <String>['Song 0']);
    });

    test('a bulk action only ever sees rows that are still in the list', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()
        ..start(tracks[0])
        ..extendTo(tracks, 3);

      // Two of them have since been removed from the catalog.
      final List<Track> remaining = <Track>[tracks[1], tracks[2]];
      expect(
          _titles(selection.resolve(remaining)), <String>['Song 1', 'Song 2']);
    });

    test('resolve returns rows in the list order, not the click order', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()
        ..toggle(tracks[3])
        ..toggle(tracks[0])
        ..toggle(tracks[2]);

      expect(
        _titles(selection.resolve(tracks)),
        <String>['Song 0', 'Song 2', 'Song 3'],
      );
    });

    test('two providers’ same-id copies are different rows', () {
      final List<Track> jellyfin = _tracks(2);
      final List<Track> subsonic = _tracks(2, provider: 'subsonic');
      final TrackSelection selection = TrackSelection()..toggle(jellyfin[0]);

      expect(selection.contains(jellyfin[0].uri), isTrue);
      expect(selection.contains(subsonic[0].uri), isFalse);
      expect(selection.resolve(subsonic), isEmpty);
    });

    test('clearing forgets the anchor too', () {
      final List<Track> tracks = _tracks(4);
      final TrackSelection selection = TrackSelection()
        ..start(tracks[1])
        ..clear();

      expect(selection.isActive, isFalse);
      expect(selection.anchorUri, isNull);

      // …so the next Shift-click starts a fresh selection rather than reaching
      // back to a row from before.
      selection.extendTo(tracks, 3);
      expect(_titles(selection.resolve(tracks)), <String>['Song 3']);
    });
  });
}
