import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/models/track.dart';
import 'package:sonara/data/repositories/music_library_repository_provider.dart';
import 'package:sonara/features/library/library_controller.dart';
import 'package:sonara/features/library/library_state.dart';

import 'fake_music_library_repository.dart';

Track _track(String id) => Track(id: id, title: 'Track $id', uri: 'file://$id');

ProviderContainer _containerWith(FakeMusicLibraryRepository repository) {
  final container = ProviderContainer(
    overrides: [
      musicLibraryRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('LibraryController', () {
    test('starts in the loading state', () {
      final container = _containerWith(FakeMusicLibraryRepository());

      expect(
        container.read(libraryControllerProvider).status,
        LibraryStatus.loading,
      );
    });

    test('loads tracks from the repository', () async {
      final container = _containerWith(
        FakeMusicLibraryRepository(tracks: <Track>[_track('a'), _track('b')]),
      );

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.tracks, hasLength(2));
      expect(state.isEmpty, isFalse);
    });

    test('reports empty when the repository has no tracks', () async {
      final container = _containerWith(FakeMusicLibraryRepository());

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.loaded);
      expect(state.isEmpty, isTrue);
    });

    test('surfaces an error when the repository throws', () async {
      final container = _containerWith(
        FakeMusicLibraryRepository(error: Exception('boom')),
      );

      await container.read(libraryControllerProvider.notifier).refresh();

      final state = container.read(libraryControllerProvider);
      expect(state.status, LibraryStatus.error);
      expect(state.errorMessage, contains('boom'));
    });
  });
}
