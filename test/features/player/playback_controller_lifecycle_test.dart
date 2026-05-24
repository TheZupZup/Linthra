import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';

/// Locks in the playback-lifecycle guarantee from the alpha bug report: the
/// single [PlaybackController] must be pinned for the app session, so navigating
/// between tabs/screens and changing settings can never recreate or dispose it
/// (which would dispose the live `AudioPlayer` and cut the music). These tests
/// drive the *real* `playbackControllerProvider`; on a non-mobile test host the
/// `just_audio` engine constructs without touching any platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('playback controller lifecycle', () {
    test('is read once and survives a resolver/locator rebuild', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final first = container.read(playbackControllerProvider);

      // Invalidate the resolution chain the controller depends on — the kind of
      // churn navigation and settings changes can trigger. With read-once
      // wiring this must NOT rebuild the controller.
      container.invalidate(cachedTrackLocatorProvider);
      container.invalidate(playableUriResolverProvider);

      final second = container.read(playbackControllerProvider);

      expect(
        identical(first, second),
        isTrue,
        reason: 'the controller must not be recreated when its resolver '
            'dependencies rebuild',
      );
    });

    test('survives a download-store rebuild (e.g. a download completing)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final first = container.read(playbackControllerProvider);

      // These feed the offline-cache locator, which feeds the resolver. A
      // watch-based controller would be torn down by this cascade; a read-based
      // one is untouched.
      container.invalidate(downloadStoreProvider);
      container.invalidate(offlineFileStoreProvider);

      final second = container.read(playbackControllerProvider);

      expect(identical(first, second), isTrue);
    });

    test('the same instance backs the provider on every read', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final reads = List.generate(
        5,
        (_) => container.read(playbackControllerProvider),
      );

      expect(reads.every((c) => identical(c, reads.first)), isTrue);
    });
  });
}
