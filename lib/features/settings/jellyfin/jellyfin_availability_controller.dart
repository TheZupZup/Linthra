import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/lifecycle/app_visibility.dart';
import '../../../core/models/jellyfin_session.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/reachability.dart';
import '../../../core/sources/jellyfin/jellyfin_availability.dart';
import '../../../core/sources/jellyfin/jellyfin_exception.dart';
import '../../../core/sources/source_availability.dart';
import '../../../data/repositories/download_repository_provider.dart';
import '../../../data/repositories/host_platform_provider.dart';
import 'jellyfin_settings_controller.dart';
import 'jellyfin_settings_providers.dart';

/// How often a *configured* Jellyfin server is re-probed in the background, or
/// `null` for no polling at all.
///
/// Defaults to **no polling**, so a bare container (every widget and unit test)
/// never carries a live timer and probes only when something asks. The running
/// app applies [jellyfinAvailabilityPollOverride] — the same pattern the other
/// production-only bindings use — to switch it on.
final jellyfinAvailabilityPollIntervalProvider =
    Provider<Duration?>((ref) => null);

/// Production binding: re-probe a configured server periodically *while the
/// app is on screen*.
///
/// Short enough that walking back onto the home network restores the library on
/// its own, with no reconnect and no rescan, and long enough that an absent
/// server costs one cheap, already-authenticated request a minute rather than a
/// battery drain. App resume and the playback path cover the rest, so this is a
/// backstop, not the primary signal.
///
/// The poll runs only while the UI is visible ([appVisibilityProvider]). With
/// the screen off, `audio_service` keeps this isolate alive for playback, so
/// this timer would otherwise keep firing for the whole session — a network
/// round-trip (and on mobile data, a radio wake-up) every interval, refreshing
/// a library nobody is looking at. Nothing is lost by standing down: coming
/// back to the app re-probes immediately (see `LinthraApp`'s resume path), and
/// the playback path reports what it learns through [noteReachability] whether
/// the UI is up or not.
final jellyfinAvailabilityPollOverride =
    jellyfinAvailabilityPollIntervalProvider.overrideWithValue(
  const Duration(seconds: 45),
);

/// Tracks whether the configured Jellyfin server can actually be reached,
/// separately from whether one is configured at all.
///
/// The settings controller answers "is a session saved?" and must keep saying
/// yes while the user is away from the server — that saved session, the synced
/// catalog, the imported playlists, the favourites, and the downloads are
/// exactly what the user wants back when they get home. This notifier answers
/// the *other* question, "did the server answer just now?", and is the only
/// thing the active library and the diagnostics report gate on.
///
/// It probes with [JellyfinClient.verifySession] — the same cheap,
/// already-authenticated call the playback path uses — so a probe distinguishes
/// "can't be reached" from "session rejected" without fetching a library.
///
/// Nothing it does is destructive. Its whole output is one enum; no catalog row,
/// playlist, favourite, download, or saved session is touched by any transition
/// it can make.
class JellyfinAvailabilityController extends Notifier<SourceAvailabilityState> {
  Timer? _poll;
  bool _disposed = false;

  /// How often to re-probe while the app is on screen, or null for no polling
  /// at all. Read once per build from [jellyfinAvailabilityPollIntervalProvider].
  Duration? _interval;

  /// Whether a configured session exists, so a visibility change can restart
  /// the poll without re-reading the settings controller.
  bool _configured = false;

  /// Guards against a slow probe from a previous session/server landing on top
  /// of a newer answer. Every probe takes a ticket; only the newest one may
  /// write. Kept across `build()` re-runs (Riverpod reuses the notifier), which
  /// is precisely what makes a sign-out cancel an in-flight probe's result.
  int _generation = 0;

  @override
  SourceAvailabilityState build() {
    _disposed = false;
    // Re-runs whenever a session appears or disappears (sign-in, sign-out, a
    // restored session at startup), which is exactly when availability has to be
    // established from scratch.
    final bool configured = ref.watch(
      jellyfinSettingsControllerProvider.select((s) => s.isConnected),
    );
    _poll?.cancel();
    _poll = null;
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _poll = null;
    });

    _configured = configured;
    if (!configured) {
      // Nothing configured: no probe, no timer, and nothing hidden.
      _generation++;
      return const SourceAvailabilityState.notConfigured();
    }

    _interval = ref.read(jellyfinAvailabilityPollIntervalProvider);
    // Listened to rather than watched: a visibility flip must start or stop the
    // timer without re-running this build, which would reset a settled
    // availability back to `checking` (blinking the library) and fire a fresh
    // probe every time the user pockets the phone.
    ref.listen<bool>(
      appVisibilityProvider,
      (bool? previous, bool visible) => _syncPoll(visible: visible),
    );
    _syncPoll(visible: ref.read(appVisibilityProvider));
    _followNetwork();
    // Probe off the build so the notifier never writes state while building.
    // Until it lands the state is `checking`, which hides nothing (see
    // [SourceAvailability.hidesTracks]) — a library must not blink out while we
    // are still asking.
    scheduleMicrotask(() {
      if (!_disposed) unawaited(refresh());
    });
    return const SourceAvailabilityState.checking();
  }

  /// Starts or stops the background poll for the current visibility.
  ///
  /// Only ever touches the timer: it never probes and never writes state, so a
  /// pocketed phone (or a returning one) can't move the library on its own.
  void _syncPoll({required bool visible}) {
    final Duration? interval = _interval;
    final bool shouldPoll = !_disposed &&
        _configured &&
        visible &&
        interval != null &&
        interval > Duration.zero;
    if (!shouldPoll) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Re-probes when the device gets a connection back (or a different one),
  /// where the platform reports connection changes: Wi-Fi rejoined, mobile
  /// data back, a laptop's network up again after it woke. Otherwise a server
  /// found unreachable while the connection was down stays hidden until the
  /// next poll. Only while the app is on screen, like the poll: coming back
  /// to it re-probes anyway. Going offline probes nothing; that can only fail.
  void _followNetwork() {
    if (!hostReportsNetworkChanges(ref.read(hostPlatformProvider))) return;
    final StreamSubscription<NetworkStatus> changes =
        ref.read(connectivityServiceProvider).statusStream.listen(
      (NetworkStatus status) {
        if (_disposed || status == NetworkStatus.offline) return;
        if (!ref.read(appVisibilityProvider)) return;
        unawaited(refresh());
      },
      // A connectivity stream that fails only means no early re-probe; the
      // poll and resume still come.
      onError: (Object _, StackTrace __) {},
    );
    // Cancelling a platform event stream waits on the native side, which
    // must never hold up a rebuild or shutdown.
    ref.onDispose(() => unawaited(changes.cancel().catchError((Object _) {})));
  }

  /// Re-probes the configured server now. Safe to call from anywhere and at any
  /// rate: it never throws, and a stale answer can't overwrite a newer one.
  ///
  /// Called on app resume, on a network change, and by the background poll — the
  /// three moments a server realistically comes back.
  Future<void> refresh() async {
    final int generation = ++_generation;
    final JellyfinSession? session =
        ref.read(jellyfinSettingsControllerProvider.notifier).session;
    if (session == null) {
      _apply(generation, SourceAvailability.notConfigured);
      return;
    }
    _apply(generation, await _probe(session));
  }

  /// Adopts what the *playback* path just learned about the server, so the first
  /// track that fails to resolve updates availability immediately instead of the
  /// library waiting out a poll interval.
  ///
  /// This is the deliberately narrow bridge between a resolution error and the
  /// library: it can only ever move this enum. It cannot — and must not grow to —
  /// delete a track, a download, or the session, which is the coupling that made
  /// the old "remove the connection to get a usable library" workaround the only
  /// option. Ignored while no server is configured.
  void noteReachability(ReachabilityStatus status) {
    if (_disposed || !state.status.isConfigured) return;
    final SourceAvailability? availability =
        availabilityFromReachability(status);
    if (availability == null) return;
    _apply(++_generation, availability);
  }

  Future<SourceAvailability> _probe(JellyfinSession session) async {
    try {
      await ref.read(jellyfinClientProvider).verifySession(session);
      return SourceAvailability.available;
    } on JellyfinException catch (error) {
      return jellyfinAvailabilityFromError(error.kind);
    } catch (_) {
      // A transport fault the client didn't wrap. Treat it as "couldn't reach
      // the server" rather than letting it escape into the UI — and never as
      // available, which would leave unplayable tracks on screen.
      return SourceAvailability.unreachable;
    }
  }

  /// Writes [availability] when [generation] is still the newest probe and the
  /// notifier is alive. `notConfigured` clears the timestamp so a later
  /// "last checked" reading can't be attributed to a server that is gone.
  void _apply(int generation, SourceAvailability availability) {
    if (_disposed || generation != _generation) return;
    state = availability == SourceAvailability.notConfigured
        ? const SourceAvailabilityState.notConfigured()
        : SourceAvailabilityState(
            status: availability,
            lastCheckedAt: DateTime.now(),
          );
  }
}

/// The live Jellyfin availability. Watched by the active library (to hold back
/// unreachable tracks) and by diagnostics (to report the truth instead of
/// "configured").
final jellyfinAvailabilityProvider =
    NotifierProvider<JellyfinAvailabilityController, SourceAvailabilityState>(
  JellyfinAvailabilityController.new,
);
