// Server answers that come back out of order must not undo what is newer
// than them: a later refresh's answer, or a heart whose push landed while the
// refresh was out (#808).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/data/repositories/in_memory_favorites_store.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';

Track _song(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

/// One request held until the test lets it land, or fails it.
class _Held {
  final Completer<bool> _gate = Completer<bool>();
  void land() => _gate.complete(true);
  void fail() => _gate.complete(false);
}

/// A server where every request waits for the test, so it picks the order
/// they land in. A fetch reads the starred list when it is sent, like a
/// server that answered before anything after it reached it.
class _Server implements RemoteFavoritesGateway {
  final Set<String> starred = <String>{};
  final List<_Held> fetches = <_Held>[];
  final List<_Held> pushes = <_Held>[];
  final StreamController<void> _sent = StreamController<void>.broadcast();

  /// Completes once [count] requests in all have been sent.
  Future<void> sent(int count) async {
    while (fetches.length + pushes.length < count) {
      await _sent.stream.first;
    }
  }

  @override
  String get uriScheme => 'subsonic:';

  @override
  bool get isConnected => true;

  @override
  Future<Set<String>> fetchFavoriteUris() async {
    final Set<String> answer = <String>{...starred};
    final _Held held = _Held();
    fetches.add(held);
    _sent.add(null);
    if (!await held._gate.future) throw const RemoteSyncException('offline');
    return answer;
  }

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    final _Held held = _Held();
    pushes.add(held);
    _sent.add(null);
    if (!await held._gate.future) throw const RemoteSyncException('offline');
    if (favorite) {
      starred.add(trackUri);
    } else {
      starred.remove(trackUri);
    }
  }
}

void main() {
  late _Server server;
  late InMemoryFavoritesStore store;
  late SyncedFavoritesRepository repo;

  setUp(() {
    server = _Server();
    store = InMemoryFavoritesStore();
    repo = SyncedFavoritesRepository(
      store: store,
      gateways: <RemoteFavoritesGateway>[server],
    );
  });

  tearDown(() => repo.dispose());

  test('an older refresh landing last does not undo a newer one', () async {
    final Future<FavoritesSyncResult> older = repo.refreshFromRemote();
    await server.sent(1);
    // Starred from another device between the two reads.
    server.starred.add('subsonic:x');
    final Future<FavoritesSyncResult> newer = repo.refreshFromRemote();
    await server.sent(2);

    server.fetches[1].land();
    await newer;
    expect(repo.isFavorite('subsonic:x'), isTrue);

    server.fetches[0].land();
    await older;

    expect(repo.isFavorite('subsonic:x'), isTrue);
    expect((await store.load()).remoteIds, <String>{'subsonic:x'});
  });

  test('a heart whose push lands while a refresh is out survives it', () async {
    // The heart's push is out (held).
    final Future<void> heart = repo.setFavorite(_song('a'), true);
    await server.sent(1);

    // A refresh sends the pending heart again; that one fails, and its
    // fetch reads the server before the first push lands.
    final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
    await server.sent(2);
    server.pushes[1].fail();
    await server.sent(3);

    // The first push lands: the server has the heart now.
    server.pushes[0].land();
    await heart;
    expect(server.starred, <String>{'subsonic:a'});

    // The answer from before it comes back.
    server.fetches[0].land();
    await refresh;

    expect(repo.isFavorite('subsonic:a'), isTrue);
    expect((await store.load()).remoteIds, <String>{'subsonic:a'});
  });
}
