import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lifecycle/async_disposal_registry.dart';
import '../core/models/desktop_close_behavior.dart';
import '../core/models/plex_session.dart';
import '../core/models/subsonic_session.dart';
import '../core/services/artwork_disk_cache.dart';
import '../core/services/desktop_window_lifecycle_service.dart';
import '../core/services/media_session_binding.dart';
import '../core/services/playback_session_persistence.dart';
import '../core/services/playback_volume_persistence.dart';
import '../core/sources/plex/plex_artwork.dart';
import '../core/sources/subsonic/subsonic_artwork.dart';
import '../data/repositories/download_repository_provider.dart';
import '../data/repositories/favorites_repository_provider.dart';
import '../data/repositories/music_library_repository_provider.dart';
import '../data/repositories/playback_preferences_provider.dart';
import '../data/repositories/playback_session_store_provider.dart';
import '../data/repositories/playlist_repository_provider.dart';
import '../data/repositories/remote_cache_index_provider.dart';
import '../features/player/media_artwork_providers.dart';
import '../features/player/player_providers.dart';
import '../features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import '../features/settings/desktop/close_behavior_controller.dart';
import '../features/settings/desktop/desktop_window_providers.dart';
import '../features/settings/jellyfin/jellyfin_settings_controller.dart';
import '../features/settings/playback/audio_output_controller.dart';
import '../features/settings/playback/normalize_volume_controller.dart';
import '../features/settings/plex/plex_settings_controller.dart';
import '../features/settings/subsonic/subsonic_settings_controller.dart';
import '../shared/widgets/artwork_image.dart';

export 'application_container.dart' show productionApplicationOverrides;

/// Owns the root [ProviderContainer] and every resource `main()` installs
/// outside Riverpod.
///
/// [shutdown] is idempotent, safe after a partial startup, and — the part that
/// makes it a lifecycle rather than a best-effort teardown — **awaited to
/// completion**: when its future completes, every app-owned resource that has
/// to be gone before the app can start again (the SQLite connection, the audio
/// engine, the Jellyfin control socket, the artwork HTTP client, the
/// subscriptions and global hooks installed at bootstrap) has actually
/// finished closing. See [AsyncDisposalRegistry] for how the asynchronous half
/// of that guarantee is collected out of Riverpod's synchronous
/// `ProviderContainer.dispose()`.
///
/// One thing it deliberately does not release: the Android media session. The
/// graceful-shutdown path is desktop-only (see `PlatformShutdownPolicy`), and
/// on Android the session belongs to `audio_service`'s foreground service and
/// the platform, not to this handle — so its [MediaSession] detaches to
/// nothing. Linux's MPRIS session *is* released here: the bus name is Linthra's
/// to give back.
class ApplicationHandle {
  /// Creates a handle for [container].
  ///
  /// [bootstrapApplication] registers what it owns as it goes; the two named
  /// resources are accepted here so a caller that wired the same two things
  /// itself (tests, and any future embedder) gets the same teardown.
  ApplicationHandle({
    required this.container,
    ProviderSubscription<AsyncValue<bool>>? normalizeVolumeSubscription,
    ArtworkDiskCache? artworkDiskCache,
  }) : _asyncDisposals = container.read(asyncDisposalRegistryProvider) {
    if (normalizeVolumeSubscription != null) {
      ownSubscription(normalizeVolumeSubscription);
    }
    if (artworkDiskCache != null) {
      ownArtworkDiskCache(artworkDiskCache);
    }
  }

  final ProviderContainer container;

  /// The container's collector of asynchronous provider teardown. Captured at
  /// construction because it cannot be read back once the container is gone.
  final AsyncDisposalRegistry _asyncDisposals;

  /// Teardown steps for everything installed *outside* Riverpod, newest first:
  /// bootstrap registers each one the moment the matching resource exists, so a
  /// bootstrap that throws halfway still unwinds exactly what it created.
  final List<FutureOr<void> Function()> _teardowns =
      <FutureOr<void> Function()>[];

  Future<void>? _shutdown;

  /// Whether [shutdown] has been started.
  bool get isShuttingDown => _shutdown != null;

  /// Registers [teardown] to run during [shutdown], before the container is
  /// disposed. Steps run in reverse registration order, and a step that throws
  /// never stops the ones behind it.
  void own(FutureOr<void> Function() teardown) => _teardowns.add(teardown);

  /// Closes [subscription] on shutdown.
  void ownSubscription(ProviderSubscription<Object?> subscription) =>
      own(subscription.close);

  /// Disposes [cache] and clears the global artwork-cache hook on shutdown.
  void ownArtworkDiskCache(ArtworkDiskCache cache) {
    own(() {
      installArtworkDiskCache(null);
      cache.dispose();
    });
  }

  /// Waits for best-effort startup work before [shutdown] completes.
  ///
  /// Bootstrap deliberately starts a couple of things without awaiting them so
  /// the first frame is not held up. "Not awaited by startup" must not mean
  /// "still running while the next container opens the same files", so the work
  /// is parked in the same registry the asynchronous teardown uses.
  void ownPendingWork(Future<void> work) => _asyncDisposals.track(work);

  /// Clears the global artwork-resolver hook on shutdown.
  void ownArtworkReferenceResolver() {
    own(() => installArtworkReferenceResolver(null));
  }

  /// Stops playback, releases everything installed at bootstrap, disposes the
  /// root container, and waits for the asynchronous teardown that container
  /// started to finish.
  ///
  /// Never throws: a resource that fails to close is skipped so the ones behind
  /// it still get their chance (the failures stay readable through
  /// [AsyncDisposalRegistry.failures]). Calling it again — or concurrently —
  /// returns the same future instead of tearing anything down twice.
  Future<void> shutdown() => _shutdown ??= _runShutdown();

  Future<void> _runShutdown() async {
    // Silence the speakers first, before anything it depends on goes away.
    await _guard(() async {
      if (!container.exists(playbackControllerProvider)) return;
      await container.read(playbackControllerProvider).stop();
    });

    // The engines are also disposed by their providers below; doing it here
    // first keeps the audio device release ahead of the rest of the teardown,
    // and both disposals are idempotent.
    await _guard(() async {
      if (!container.exists(playbackControllerProvider)) return;
      await container.read(playbackControllerProvider).dispose();
    });
    await _guard(() async {
      if (!container.exists(localPlaybackControllerProvider)) return;
      await container.read(localPlaybackControllerProvider).dispose();
    });

    // Snapshot first: a teardown is allowed to register another one (and must
    // not trip a concurrent modification if it does).
    final List<FutureOr<void> Function()> steps =
        List<FutureOr<void> Function()>.of(_teardowns.reversed);
    _teardowns.clear();
    for (final FutureOr<void> Function() teardown in steps) {
      await _guard(teardown);
    }

    await _guard(container.dispose);

    // `ProviderContainer.dispose()` only *starts* asynchronous teardown; this
    // is where "the database is closed" becomes true rather than pending.
    await _asyncDisposals.settle();
  }

  Future<void> _guard(FutureOr<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Best-effort: shutdown must never throw.
    }
  }
}

/// Wires the same side-effect services and session warm-up `main()` performs
/// between container creation and `runApp`.
///
/// Exception-safe: if any step throws, everything already initialized is torn
/// down (through the very same [ApplicationHandle.shutdown] the app uses) and
/// the original error is rethrown with its original stack trace. `main()` never
/// receives a handle for a failed bootstrap, so the cleanup cannot be left to
/// a caller that has nothing to call it on.
Future<ApplicationHandle> bootstrapApplication(
  ProviderContainer container, {
  bool installPersistentArtworkCache = true,
  Directory? artworkCacheDirectory,
  MediaSessionBinding mediaSessionBinding = const PlatformMediaSessionBinding(),
}) async {
  final ApplicationHandle handle = ApplicationHandle(container: container);
  try {
    // The desktop window lifecycle (#401): what a window close does, and the
    // explicit quit. Started before the media session so MPRIS can offer the
    // same Raise/Quit the window itself does, and handed the graceful shutdown
    // so an explicit quit releases audio, the bus name and the database before
    // the process ends rather than racing the engine on the way down.
    //
    // Inert off the desktop: the window controller is then the no-op one, so
    // nothing is pushed anywhere and nothing is ever hidden.
    final DesktopWindowLifecycleService desktopWindow =
        container.read(desktopWindowLifecycleServiceProvider);
    desktopWindow.installShutdown(handle.shutdown);
    desktopWindow.start();

    // Mirror the user's close-behaviour choice onto the runner, seeding the
    // persisted value now and pushing every later change. The runner has to
    // answer a GTK delete-event synchronously, so it is told the answer ahead
    // of time rather than asked for one.
    handle.ownSubscription(
      container.listen<AsyncValue<DesktopCloseBehavior>>(
        desktopCloseBehaviorControllerProvider,
        (_, AsyncValue<DesktopCloseBehavior> next) {
          desktopWindow.setCloseBehavior(
            next.valueOrNull ?? DesktopCloseBehavior.defaultBehavior,
          );
        },
        fireImmediately: true,
      ),
    );

    // Attaching the session is best-effort and platform-routed: Android gets
    // the real `audio_service` session, Linux gets MPRIS, and every other
    // platform gets the inert binding so `audio_service` is never initialised
    // where it has no implementation.
    //
    // Injectable for the same reason `MprisMediaSessionBinding` takes a D-Bus
    // client factory: the default reads the real host, so a bootstrap test run
    // on a Linux machine reaches the real session bus. That is not this
    // suite's business, and it is not deterministic either — how long the
    // connection attempt takes decides how far bootstrap has got by the time
    // the test looks, which is what made the failure-cleanup test flaky.
    final MediaSession? session = await mediaSessionBinding.attach(
      container.read(playbackControllerProvider),
      container.read(musicLibraryRepositoryProvider),
      playlists: container.read(playlistRepositoryProvider),
      favorites: container.read(favoritesRepositoryProvider),
      downloads: container.read(downloadRepositoryProvider),
      artwork: container.read(mediaArtworkCacheProvider),
      // Raise and Quit for the desktop session. Off the desktop this is still
      // the inert service, and the Android session ignores it entirely.
      application: desktopWindow,
    );
    // Owned so shutdown gives the session back. On Android that is a no-op (the
    // session belongs to the foreground service), but on Linux it releases the
    // MPRIS bus name — a player that exits still holding it leaves a ghost in
    // every shell that was listening.
    if (session != null) handle.own(session.detach);

    // Side-effect-only services: instantiating each one wires its listener.
    // They are disposed with the container, and — because each registers with
    // [AsyncDisposalRef.onDisposeAsync] — awaited by [ApplicationHandle].
    container.read(mediaArtworkPrewarmServiceProvider);
    container.read(smartPrecacheServiceProvider);
    container.read(remotePrebufferServiceProvider);
    // Loads and prunes the credential-free remote-cache manifest off the
    // first-frame path. Owned rather than merely unawaited: it writes to the
    // app-support directory, so a restart must not race a prune still in
    // flight.
    handle.ownPendingWork(container.read(remoteCacheIndexProvider).load());
    container.read(playbackReportingServiceProvider);
    container.read(remoteControlServiceProvider);
    container.read(remoteControlActivatorProvider);

    // Mirror the user's "Normalize volume" choice onto the local audio engine,
    // seeding the persisted value now and pushing every later toggle.
    handle.ownSubscription(
      container.listen<AsyncValue<bool>>(
        normalizeVolumeControllerProvider,
        (_, next) {
          container
              .read(localPlaybackControllerProvider)
              .setVolumeNormalizationEnabled(next.valueOrNull ?? false);
        },
        fireImmediately: true,
      ),
    );

    // Re-apply a saved audio output (Linux) so a chosen headset, DAC or HDMI
    // sink survives a restart without the listener re-picking it.
    //
    // Awaited, because the alternative leaks audio: the media_kit player is
    // built when the first track loads, and it reads the chosen output at
    // construction. A restore still in flight at that moment means the opening
    // seconds play on the system default and only then jump to the right
    // speakers. Waiting here closes that window — a track cannot be started
    // before the first frame.
    //
    // Bounded, because a wedged audio backend must not hold the window shut:
    // past the deadline launch continues and the restore lands whenever the
    // backend answers, moving live playback then. It is owned either way, so
    // shutdown still waits for it.
    //
    // Cheap by design when there is nothing to restore: the controller does not
    // probe the backend just to confirm the system default, and off Linux the
    // seam is a no-op that never loads libmpv at all — in both cases this
    // returns without touching anything.
    final Future<void> audioOutputRestored = _restoreAudioOutput(container);
    handle.ownPendingWork(audioOutputRestored);
    try {
      await audioOutputRestored.timeout(_audioOutputRestoreDeadline);
    } on TimeoutException {
      // Deliberately ignored: see above.
    }

    // Warm the persisted sessions before the first frame so a synced remote
    // track can stream on the first tap. Best-effort and secret-free: a
    // missing/corrupt record loads as "not connected".
    for (final Future<void> Function() ensureLoaded
        in <Future<void> Function()>[
      container.read(jellyfinSettingsControllerProvider.notifier).ensureLoaded,
      container.read(subsonicSettingsControllerProvider.notifier).ensureLoaded,
      container.read(plexSettingsControllerProvider.notifier).ensureLoaded,
      container
          .read(audiobookshelfSettingsControllerProvider.notifier)
          .ensureLoaded,
    ]) {
      try {
        await ensureLoaded();
      } catch (_) {
        // Ignore: the user can still connect in Settings.
      }
    }

    // Teach the shared artwork seam how to turn a credential-free cover
    // reference (subsonic-cover:<id> or plex-thumb:<path>) into an
    // authenticated cover URL, weaving the live session's credential in at
    // render time. Secret-free: only the resolved URL is built, never logged.
    Uri? resolveArtworkReference(Uri reference) {
      final SubsonicSession? subsonicSession =
          container.read(subsonicSettingsControllerProvider.notifier).session;
      if (subsonicSession != null) {
        final Uri? resolved =
            SubsonicArtwork.resolve(reference, subsonicSession);
        if (resolved != null) return resolved;
      }
      final PlexSession? plexSession =
          container.read(plexMusicSourceProvider)?.session;
      if (plexSession != null) {
        final Uri? resolved = PlexArtwork.resolve(reference, plexSession);
        if (resolved != null) return resolved;
      }
      return null;
    }

    // Global hooks: owned from the moment they are installed, so a later
    // bootstrap failure cannot leave this container's closures wired into the
    // process-wide artwork seam.
    installArtworkReferenceResolver(resolveArtworkReference);
    handle.ownArtworkReferenceResolver();

    if (installPersistentArtworkCache) {
      // Persistent, credential-free artwork cache (issue #356). Only the
      // credential-free key ever reaches disk — see [ArtworkDiskCache].
      final ArtworkDiskCache artworkDiskCache = ArtworkDiskCache(
        directory:
            artworkCacheDirectory ?? await ArtworkDiskCache.defaultDirectory(),
        resolveFetchUrl: (Uri key) => resolveArtworkReference(key) ?? key,
      );
      installArtworkDiskCache(artworkDiskCache);
      handle.ownArtworkDiskCache(artworkDiskCache);
    }

    // Pull the user's server favourites and playlists so both reflect the
    // servers from the first frame. Best-effort and offline-tolerant.
    //
    // Not owned like the manifest load above: these are network round-trips,
    // and making shutdown wait for one would hand a shutting-down app's exit
    // time to a slow or unreachable server. They write only through
    // repositories that are themselves torn down by the container, and both
    // swallow their own failures, so an in-flight refresh at shutdown ends
    // without touching anything the next container owns.
    unawaited(container.read(favoritesRepositoryProvider).refreshFromRemote());
    unawaited(container.read(playlistRepositoryProvider).refreshFromRemote());

    // Desktop volume: come back at the level the listener left, before anything
    // can play. Never blocks launch, and never restores a mute.
    final PlaybackVolumePersistence? volumePersistence =
        container.read(playbackVolumePersistenceProvider);
    if (volumePersistence != null) await volumePersistence.restore();

    // Linux crash-safe restore: rehydrate any persisted logical queue as a
    // paused/resumable state. Never autoplay, and never block launch on a bad
    // record.
    final PlaybackSessionPersistence? sessionPersistence =
        container.read(playbackSessionPersistenceProvider);
    if (sessionPersistence != null) {
      try {
        await sessionPersistence.restore();
      } catch (_) {
        // Ignore: a failed restore must never stop the app from launching.
      }
    }

    return handle;
  } catch (error, stackTrace) {
    // Unwind everything this bootstrap managed to create, then surface the
    // original failure untouched — the cleanup must not become the error the
    // caller sees.
    await handle.shutdown();
    Error.throwWithStackTrace(error, stackTrace);
  }
}

/// How long launch waits for a saved audio output to be re-applied.
///
/// libmpv publishes its device list while a player initializes, so the normal
/// cost of this is milliseconds. The deadline exists for the backend that never
/// answers at all, and is shorter than the enumeration timeout underneath it so
/// the wait is bounded by *this* value rather than by that one.
const Duration _audioOutputRestoreDeadline = Duration(milliseconds: 1500);

/// Builds the audio-output controller, which re-applies a saved output device.
///
/// Failure is swallowed on purpose: an audio backend that will not answer must
/// never break launch, and the fallback — the system default — is exactly what
/// the app does without this.
Future<void> _restoreAudioOutput(ProviderContainer container) async {
  try {
    await container.read(audioOutputControllerProvider.future);
  } catch (_) {
    // Ignore: playback stays on the system default.
  }
}
