import '../models/track.dart';
import 'connectivity_service.dart';
import 'playable_uri_resolver.dart';
import 'provider_reachability.dart';
import 'reachability.dart';

/// A [PlayableUriResolver] decorator that remembers, briefly, when a provider is
/// unreachable — so a server that's offline doesn't stall every track behind its
/// own connect timeout before the player falls back.
///
/// It wraps one provider's resolver (the Jellyfin/Plex/Subsonic resolver inside
/// the source router) and adds a short-lived reachability memory around it:
///
///  1. **No network at all** → fail fast with a clear "you're offline" message
///     instead of attempting a doomed connection. (Only when a
///     [ConnectivityService] is wired and reports offline.)
///  2. **Recently seen unreachable** (within the cache's brief TTL) → skip the
///     probe and fail fast, so the *next* tracks in a burst fall straight to a
///     cached copy or another provider rather than each re-paying the timeout.
///  3. **Otherwise** → resolve for real and record the outcome (reachable, or
///     the kind of failure), so the memory stays current.
///
/// What it deliberately does **not** do:
///  - It never short-circuits an [ReachabilityStatus.authFailure]. The server is
///    reachable; the fix is re-authenticating, and a fresh sign-in must work
///    immediately — so an auth failure is recorded (for diagnostics/UI) but
///    never used to suppress a later attempt.
///  - It never touches the offline cache or cross-provider fallback. Those live
///    *above* this in the chain (the offline-first resolver tries a downloaded
///    copy before this runs; the controller tries sibling provider candidates
///    when this throws). This only makes those existing paths fire promptly.
///
/// The fast-fail it throws always carries
/// [PlaybackResolutionErrorKind.serverUnreachable], so every downstream caller
/// treats it exactly like a live "couldn't reach the server" — no new branch is
/// needed and the cross-provider fallback engages unchanged.
class ReachabilityAwarePlayableUriResolver implements PlayableUriResolver {
  ReachabilityAwarePlayableUriResolver({
    required PlayableUriResolver inner,
    required String? Function() providerKey,
    required ProviderReachability reachability,
    ConnectivityService? connectivity,
  })  : _inner = inner,
        _providerKey = providerKey,
        _reachability = reachability,
        _connectivity = connectivity;

  final PlayableUriResolver _inner;

  /// The provider-namespaced cache key (e.g. `jellyfin`), or `null` when no
  /// session is connected — in which case reachability is irrelevant and the
  /// inner resolver's own "not signed in" answer is what the user should see.
  final String? Function() _providerKey;

  final ProviderReachability _reachability;

  /// Optional device-level signal. When absent (tests, or before a real
  /// connectivity backend is wired) the offline short-circuit is simply skipped
  /// and reachability is judged purely from probe outcomes.
  final ConnectivityService? _connectivity;

  @override
  bool handles(Track track) => _inner.handles(track);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final String? key = _providerKey();
    // No connected session for this provider: let the inner resolver give its
    // own precise answer ("sign in first"); reachability doesn't apply.
    if (key == null) return _inner.resolve(track);

    // 1. The whole device is offline — no server is reachable, so don't attempt
    //    a connection that can only time out. The offline-first resolver above
    //    has already tried (and missed) a downloaded copy by the time we get
    //    here, so this is the honest end of the line for a streamed track.
    if (await _isOffline()) {
      _reachability.record(key, ReachabilityStatus.networkUnavailable);
      throw _failFast(ReachabilityStatus.networkUnavailable);
    }

    // 2. We saw this provider fail to respond very recently — skip the doomed
    //    probe and let the caller fall back immediately.
    final ReachabilityStatus? remembered = _reachability.statusOf(key);
    if (remembered != null && remembered.isTransientOutage) {
      throw _failFast(remembered);
    }

    // 3. Resolve for real, recording what we learn so the memory stays current.
    try {
      final ResolvedPlayable resolved = await _inner.resolve(track);
      _reachability.record(key, ReachabilityStatus.reachable);
      return resolved;
    } on PlaybackResolutionException catch (error) {
      final ReachabilityStatus? status =
          reachabilityFromPlaybackError(error.kind);
      if (status != null) _reachability.record(key, status);
      rethrow;
    }
  }

  /// Whether the device currently has no usable network. Defensive: any failure
  /// reading the signal is treated as "not offline" so a connectivity hiccup can
  /// never block playback that might otherwise work.
  Future<bool> _isOffline() async {
    final ConnectivityService? connectivity = _connectivity;
    if (connectivity == null) return false;
    try {
      return await connectivity.currentStatus() == NetworkStatus.offline;
    } catch (_) {
      return false;
    }
  }

  /// Builds the fast-fail error for a [status], with a clear, secret-free
  /// message. Always [PlaybackResolutionErrorKind.serverUnreachable] so it is
  /// handled identically to a live unreachable result (cross-provider fallback,
  /// offline-cache retry) with no extra branching downstream.
  PlaybackResolutionException _failFast(ReachabilityStatus status) {
    switch (status) {
      case ReachabilityStatus.networkUnavailable:
        return const PlaybackResolutionException(
          "You appear to be offline. Connect to a network to stream this "
          'track, or play a downloaded copy.',
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case ReachabilityStatus.timeout:
        return const PlaybackResolutionException(
          "Your music server isn't responding right now.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
      case ReachabilityStatus.serverUnreachable:
      case ReachabilityStatus.reachable:
      case ReachabilityStatus.authFailure:
        // Only the transient-outage states reach here (the guard above), but the
        // switch stays exhaustive; the rest share the generic unreachable line.
        return const PlaybackResolutionException(
          "Couldn't reach your music server. It may be offline.",
          kind: PlaybackResolutionErrorKind.serverUnreachable,
        );
    }
  }
}
