import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playlist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/playlist_repository.dart';
import 'package:linthra/features/playlists/playlist_add.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

Playlist _playlist({
  PlaylistSource source = PlaylistSource.local,
  List<String> trackIds = const <String>[],
  String name = 'My Mix',
}) {
  return Playlist(id: 'p1', name: name, source: source, trackIds: trackIds);
}

/// Records what reached the repository, so a test can tell "wrote nothing"
/// apart from "wrote an empty list".
class _RecordingRepository implements PlaylistRepository {
  final List<(String, List<String>)> calls = <(String, List<String>)>[];

  @override
  Future<void> addTracks(String playlistId, List<String> trackUris) async {
    calls.add((playlistId, trackUris));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  group('PlaylistAddPlan', () {
    test('a local playlist takes tracks from every source', () {
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(),
        tracks: <Track>[_local('a'), _jellyfin('1'), _subsonic('2')],
      );

      expect(plan.accepts, isTrue);
      expect(plan.addable, hasLength(3));
      expect(plan.newTracks, hasLength(3));
      expect(plan.refusalMessage, isNull);
    });

    test('a synced playlist keeps only its own server\'s tracks', () {
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(source: PlaylistSource.jellyfin),
        tracks: <Track>[_local('a'), _jellyfin('1'), _subsonic('2')],
      );

      expect(plan.uris, <String>['jellyfin:1']);
      expect(plan.accepts, isTrue);
      // The two it could not take are still counted, so the message can own up
      // to them rather than quietly reporting a clean add.
      expect(plan.requested, 3);
      expect(
        plan.resultMessage,
        'Added to My Mix. 2 skipped (already added or not supported).',
      );
    });

    test('a synced playlist refuses a selection with none of its tracks', () {
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(source: PlaylistSource.subsonic),
        tracks: <Track>[_local('a'), _jellyfin('1')],
      );

      expect(plan.accepts, isFalse);
      expect(
        plan.refusalMessage,
        'Only Navidrome tracks can be added to My Mix.',
      );
      expect(plan.resultMessage, plan.refusalMessage);
    });

    test('an empty drop on a local playlist has nothing to refuse', () {
      // A local playlist never refuses on source, so "nothing addable" here
      // only means "nothing was offered", which has no message to give.
      final PlaylistAddPlan plan =
          PlaylistAddPlan.of(playlist: _playlist(), tracks: <Track>[]);

      expect(plan.accepts, isFalse);
      expect(plan.refusalMessage, isNull);
      expect(plan.changesAnything, isFalse);
    });

    test('tracks already in the playlist are addable but not new', () {
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(trackIds: <String>['file:///a.mp3']),
        tracks: <Track>[_local('a'), _local('b')],
      );

      // Accepting the drop is the right answer even for a song already there:
      // it is a harmless no-op, and refusing the whole drop over one duplicate
      // would be worse than saying so afterwards.
      expect(plan.accepts, isTrue);
      expect(plan.addable, hasLength(2));
      expect(plan.newTracks.single.uri, 'file:///b.mp3');
      expect(
        plan.resultMessage,
        'Added to My Mix. 1 skipped (already added or not supported).',
      );
    });

    test('a drop of nothing but duplicates says so, in the plural it was', () {
      final PlaylistAddPlan one = PlaylistAddPlan.of(
        playlist: _playlist(trackIds: <String>['file:///a.mp3']),
        tracks: <Track>[_local('a')],
      );
      final PlaylistAddPlan many = PlaylistAddPlan.of(
        playlist: _playlist(
          trackIds: <String>['file:///a.mp3', 'file:///b.mp3'],
        ),
        tracks: <Track>[_local('a'), _local('b')],
      );

      expect(one.resultMessage, "That song's already in My Mix.");
      expect(many.resultMessage, 'Those songs are already in My Mix.');
    });

    test('membership is by namespaced uri, not by bare id', () {
      // `jellyfin:101` in the playlist must not make `subsonic:101` look like a
      // duplicate: they are different songs on different servers.
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(trackIds: <String>['jellyfin:101']),
        tracks: <Track>[_subsonic('101')],
      );

      expect(plan.newTracks.single.uri, 'subsonic:101');
      expect(plan.resultMessage, 'Added to My Mix.');
    });

    test('a clean multi-track add claims exactly what it added', () {
      final PlaylistAddPlan plan = PlaylistAddPlan.of(
        playlist: _playlist(),
        tracks: <Track>[_local('a'), _local('b'), _local('c')],
      );

      expect(plan.resultMessage, 'Added 3 songs to My Mix.');
    });
  });

  group('addTracksToPlaylist', () {
    test('writes the addable uris and reports the plan', () async {
      final repository = _RecordingRepository();
      final PlaylistAddPlan plan = await addTracksToPlaylist(
        repository: repository,
        playlist: _playlist(source: PlaylistSource.jellyfin),
        tracks: <Track>[_jellyfin('1'), _local('a')],
      );

      expect(repository.calls.single.$1, 'p1');
      expect(repository.calls.single.$2, <String>['jellyfin:1']);
      expect(plan.resultMessage, contains('1 skipped'));
    });

    test('a refused add never touches the repository', () async {
      // Not a detail: an add of nothing would still bump `updatedAt` and queue
      // a sync for a playlist the user never actually changed.
      final repository = _RecordingRepository();
      await addTracksToPlaylist(
        repository: repository,
        playlist: _playlist(source: PlaylistSource.jellyfin),
        tracks: <Track>[_local('a')],
      );

      expect(repository.calls, isEmpty);
    });

    test('an all-duplicates add still goes through, and is a no-op', () async {
      // The repository is what knows about duplicates, so the call is made and
      // it skips them. The plan is what keeps the *message* honest.
      final repository = _RecordingRepository();
      final PlaylistAddPlan plan = await addTracksToPlaylist(
        repository: repository,
        playlist: _playlist(trackIds: <String>['file:///a.mp3']),
        tracks: <Track>[_local('a')],
      );

      expect(repository.calls.single.$2, <String>['file:///a.mp3']);
      expect(plan.resultMessage, "That song's already in My Mix.");
    });
  });
}
