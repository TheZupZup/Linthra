import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/core/repositories/local_store_write_exception.dart';
import 'package:linthra/core/repositories/remote_sync_gateway.dart';
import 'package:linthra/core/repositories/remote_sync_result.dart';
import 'package:linthra/data/repositories/synced_favorites_repository.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');
Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

/// A favourites store on a disk that can fill up: a refused write leaves the
/// saved document as it was and throws, as the preferences store does (#797).
class _DiskStore implements FavoritesStore {
  FavoritesData saved = FavoritesData.empty;
  bool refuse = false;
  int saves = 0;

  /// While set, the next save waits on [_release] and then fails or lands.
  bool _holdNext = false;
  Completer<bool> _release = Completer<bool>();
  Completer<void> _heldStarted = Completer<void>();

  /// Holds the next save until [releaseHeld] says whether it was written.
  void holdNextSave() {
    _holdNext = true;
    _release = Completer<bool>();
    _heldStarted = Completer<void>();
  }

  Future<void> get heldSaveStarted => _heldStarted.future;

  void releaseHeld({required bool written}) => _release.complete(written);

  @override
  Future<FavoritesData> load() async => saved;

  @override
  Future<void> save(FavoritesData data) async {
    saves++;
    bool written = !refuse;
    if (_holdNext) {
      _holdNext = false;
      _heldStarted.complete();
      written = await _release.future;
    }
    if (!written) {
      throw const LocalStoreWriteException(LocalStoreArea.favorites);
    }
    saved = data;
  }
}

class _Gateway implements RemoteFavoritesGateway {
  final Set<String> serverUris = <String>{};
  final List<({String uri, bool favorite})> pushes =
      <({String uri, bool favorite})>[];

  Completer<void>? _fetchGate;
  Completer<void> _fetchStarted = Completer<void>();

  void holdFetch() {
    _fetchGate = Completer<void>();
    _fetchStarted = Completer<void>();
  }

  Future<void> get fetchStarted => _fetchStarted.future;

  void releaseFetch() => _fetchGate!.complete();

  @override
  String get uriScheme => 'subsonic:';

  @override
  bool get isConnected => true;

  @override
  Future<Set<String>> fetchFavoriteUris() async {
    final Set<String> answer = <String>{...serverUris};
    if (!_fetchStarted.isCompleted) _fetchStarted.complete();
    final Completer<void>? gate = _fetchGate;
    if (gate != null) await gate.future;
    return answer;
  }

  @override
  Future<void> pushFavorite(String trackUri, bool favorite) async {
    pushes.add((uri: trackUri, favorite: favorite));
    if (favorite) {
      serverUris.add(trackUri);
    } else {
      serverUris.remove(trackUri);
    }
  }
}

Matcher get _refusedWrite => throwsA(isA<LocalStoreWriteException>());

/// Lets the stream deliver what was emitted so far.
Future<void> _delivered() => Future<void>.delayed(Duration.zero);

void main() {
  late _DiskStore store;
  late _Gateway gateway;
  late SyncedFavoritesRepository repo;
  late List<Set<String>> emitted;

  setUp(() async {
    store = _DiskStore();
    gateway = _Gateway();
    repo = SyncedFavoritesRepository(
      store: store,
      gateways: <RemoteFavoritesGateway>[gateway],
    );
    emitted = <Set<String>>[];
    repo.favoritesStream.listen(emitted.add);
    await _delivered();
    emitted.clear();
  });

  tearDown(() => repo.dispose());

  group('a heart whose save fails (#808)', () {
    test('is not kept, and the next heart that saves does not carry it',
        () async {
      store.refuse = true;
      await expectLater(repo.setFavorite(_local('a'), true), _refusedWrite);

      await _delivered();
      expect(repo.isFavorite('file:///a.mp3'), isFalse);
      expect(emitted, isEmpty);

      store.refuse = false;
      await repo.setFavorite(_local('b'), true);
      await _delivered();

      expect(store.saved.localIds, <String>{'file:///b.mp3'});
      expect(emitted.last, <String>{'file:///b.mp3'});
      expect(repo.isFavorite('file:///a.mp3'), isFalse);
    });

    test('on a server track is neither pushed nor queued for a push', () async {
      store.refuse = true;
      await expectLater(repo.setFavorite(_subsonic('a'), true), _refusedWrite);

      expect(repo.isFavorite('subsonic:a'), isFalse);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(gateway.pushes, isEmpty);

      store.refuse = false;
      await repo.refreshFromRemote();
      await repo.setFavorite(_subsonic('b'), true);

      expect(gateway.pushes, <({String uri, bool favorite})>[
        (uri: 'subsonic:b', favorite: true),
      ]);
      expect(gateway.serverUris, <String>{'subsonic:b'});
      expect(store.saved.remoteIds, <String>{'subsonic:b'});
      expect(store.saved.pendingWrites, isEmpty);
    });
  });

  group('an un-heart whose save fails (#808)', () {
    test('leaves the heart in place, now and after the next save', () async {
      await repo.setFavorite(_local('a'), true);
      await _delivered();
      emitted.clear();

      store.refuse = true;
      await expectLater(repo.setFavorite(_local('a'), false), _refusedWrite);

      await _delivered();
      expect(repo.isFavorite('file:///a.mp3'), isTrue);
      expect(emitted, isEmpty);

      store.refuse = false;
      await repo.setFavorite(_local('b'), true);
      await _delivered();

      expect(store.saved.localIds, <String>{'file:///a.mp3', 'file:///b.mp3'});
      expect(emitted.last, <String>{'file:///a.mp3', 'file:///b.mp3'});
    });

    test(
        'on a server track is not pushed, and a refresh keeps the server heart',
        () async {
      await repo.setFavorite(_subsonic('a'), true);
      gateway.pushes.clear();

      store.refuse = true;
      await expectLater(repo.setFavorite(_subsonic('a'), false), _refusedWrite);

      expect(repo.isFavorite('subsonic:a'), isTrue);
      expect(repo.pendingRemoteWriteCount, 0);
      expect(gateway.pushes, isEmpty);

      store.refuse = false;
      await repo.refreshFromRemote();

      expect(gateway.pushes, isEmpty);
      expect(gateway.serverUris, <String>{'subsonic:a'});
      expect(repo.isFavorite('subsonic:a'), isTrue);
    });
  });

  test('a heart made while a failing save is out is saved without it',
      () async {
    store.holdNextSave();
    final Future<void> first = repo.setFavorite(_local('a'), true);
    await store.heldSaveStarted;
    final Future<void> second = repo.setFavorite(_local('b'), true);

    store.releaseHeld(written: false);
    await expectLater(first, _refusedWrite);
    await second;
    await _delivered();

    expect(store.saved.localIds, <String>{'file:///b.mp3'});
    expect(repo.isFavorite('file:///a.mp3'), isFalse);
    expect(repo.isFavorite('file:///b.mp3'), isTrue);
    expect(emitted.last, <String>{'file:///b.mp3'});
  });

  test('two hearts saved at once both stand', () async {
    store.holdNextSave();
    final Future<void> first = repo.setFavorite(_local('a'), true);
    await store.heldSaveStarted;
    final Future<void> second = repo.setFavorite(_local('b'), true);

    store.releaseHeld(written: true);
    await first;
    await second;

    expect(store.saved.localIds, <String>{'file:///a.mp3', 'file:///b.mp3'});
    expect(repo.isFavorite('file:///a.mp3'), isTrue);
    expect(repo.isFavorite('file:///b.mp3'), isTrue);
  });

  test('an un-heart that failed during a refresh does not override its answer',
      () async {
    gateway.serverUris.add('subsonic:a');
    await repo.refreshFromRemote();
    expect(repo.isFavorite('subsonic:a'), isTrue);

    gateway.holdFetch();
    final Future<FavoritesSyncResult> refresh = repo.refreshFromRemote();
    await gateway.fetchStarted;
    store.refuse = true;
    await expectLater(repo.setFavorite(_subsonic('a'), false), _refusedWrite);
    store.refuse = false;
    gateway.releaseFetch();
    await refresh;

    expect(repo.isFavorite('subsonic:a'), isTrue);
    expect(store.saved.remoteIds, <String>{'subsonic:a'});
  });

  test('a moved heart whose save fails stays where it was', () async {
    await repo.setFavorite(_local('old'), true);

    store.refuse = true;
    await repo.reassignTrack(
      fromUri: 'file:///old.mp3',
      toUri: 'file:///new.mp3',
    );
    expect(repo.isFavorite('file:///old.mp3'), isTrue);
    expect(repo.isFavorite('file:///new.mp3'), isFalse);

    store.refuse = false;
    await repo.setFavorite(_local('b'), true);
    expect(
      store.saved.localIds,
      <String>{'file:///old.mp3', 'file:///b.mp3'},
    );
  });

  test('signing out drops the hearts even when the disk refuses it', () async {
    await repo.setFavorite(_subsonic('a'), true);
    await repo.setFavorite(_local('b'), true);

    store.refuse = true;
    await expectLater(
      repo.clearRemote(providerScheme: 'subsonic:'),
      _refusedWrite,
    );
    await _delivered();

    // The account is gone either way: its heart is neither shown nor kept for
    // whoever signs in next, and the next save that lands writes the clear.
    expect(repo.isFavorite('subsonic:a'), isFalse);
    expect(repo.pendingRemoteWriteCount, 0);
    expect(emitted.last, <String>{'file:///b.mp3'});

    store.refuse = false;
    await repo.setFavorite(_local('c'), true);
    expect(store.saved.remoteIds, isEmpty);
    expect(store.saved.pendingWrites, isEmpty);
  });
}
