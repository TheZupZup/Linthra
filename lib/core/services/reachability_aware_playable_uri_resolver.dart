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
///     instead of attempting a doomed connection. Judged fresh from the
///     [ConnectivityService] every call and never cached, so the moment the
///     network returns this stops firing. (Only when a [ConnectivityService] is
///     wired and reports offline.)
///  2. **This server seen unreachable recently** (a server-level outage within
///     the cache's brief TTL) → skip the probe and fail fast, so the *next*
///     tracks in a burst fall straight to a cached copy or another provider
///     rather than each re-paying the timeout.
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
    void Function(ReachabilityStatus status)? onReachabilityObserved,
  })  : _inner = inner,
        _providerKey = providerKey,
        _reachability = reachability,
        _connectivity = connectivity,
        _onReachabilityObserved = onReachabilityObserved;

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

  /// Optional observer told what each *live* attempt learned about the server,
  /// so the app's source-availability state can follow the truth the playback
  /// path already discovered instead of waiting out a background poll.
  ///
  /// Deliberately narrow: it is handed a [ReachabilityStatus] and nothing else —
  /// no track, no catalog handle — so an observer can update a visibility flag
  /// and cannot be grown into something that removes library rows off the back
  /// of a per-track resolution error. Never fired for the remembered-outage
  /// fast-fail (step 2), which teaches nothing new. Failures are swallowed: an
  /// observer must never be able to break playback.
  final void Function(ReachabilityStatus status)? _onReachabilityObserved;

  /// Numbers each attempt as it starts.
  int _attempts = 0;

  /// For each key, the latest-started attempt whose outcome was taken in.
  ///
  /// Attempts can finish out of order. A request stuck on a network that has
  /// since gone (Wi-Fi left behind for mobile data) times out long after a
  /// newer one reached the server, and its "unreachable" is older news than
  /// that answer. Kept, it would fast-fail every track for the memory's
  /// lifetime and hide the library while the server is answering.
  final Map<String, int> _newestSettled = <String, int>{};

  void _observe(ReachabilityStatus status) {
    final void Function(ReachabilityStatus)? observer = _onReachabilityObserved;
    if (observer == null) return;
    try {
      observer(status);
    } catch (_) {
      // An observer is a listener, not a participant; its failure is not the
      // player's problem.
    }
  }

  @override
  bool handles(Track track) => _inner.handles(track);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    final String? key = _providerKey();
    // No connected session for this provider: let the inner resolver give its
    // own precise answer ("sign in first"); reachability doesn't apply.
    if (key == null) return _inner.resolve(track);
    final int attempt = ++_attempts;

    // 1. The whole device is offline — no server is reachable, so don't attempt
    //    a connection that can only time out. The offline-first resolver above
    //    has already tried (and missed) a downloaded copy by the time we get
    //    here, so this is the honest end of the line for a streamed track.
    //    Judged fresh every call and never cached: the instant connectivity
    //    returns this is false again, so a reconnect is never blocked by a stale
    //    "offline" the way a cached value would be.
    if (await _isOffline()) {
      if (_isNewest(key, attempt)) {
        _observeFor(key, ReachabilityStatus.networkUnavailable);
      }
      throw _failFast(ReachabilityStatus.networkUnavailable);
    }

    // 2. We have a network, but saw this server fail to respond very recently —
    //    skip the doomed probe and let the caller fall back immediately. Only a
    //    server-level outage gates this (never the device-offline state from
    //    step 1, which is already judged fresh), so a reconnected device probes
    //    a recovered server straight away.
    final ReachabilityStatus? remembered = _reachability.statusOf(key);
    if (remembered != null && remembered.isServerOutage) {
      throw _failFast(remembered);
    }

    // 3. Resolve for real, recording what we learn so the memory stays current.
    try {
      final ResolvedPlayable resolved = await _inner.resolve(track);
      if (_isNewest(key, attempt)) {
        _reachability.record(key, ReachabilityStatus.reachable);
        _observeFor(key, ReachabilityStatus.reachable);
      }
      return resolved;
    } on PlaybackResolutionException catch (error) {
      final ReachabilityStatus? status =
          reachabilityFromPlaybackError(error.kind);
      if (status != null && _isNewest(key, attempt)) {
        _reachability.record(key, status);
        _observeFor(key, status);
      }
      rethrow;
    }
  }

  /// Tells the observer what an attempt made under [key] learned, if [key] is
  /// still the server and account signed in. An attempt can take as long as a
  /// connect timeout, and one started on an address the listener has since
  /// signed in past (a LAN address swapped for the public one, another
  /// account) says nothing about the server they use now: reported, it would
  /// hold that server's whole library back until the next probe.
  void _observeFor(String key, ReachabilityStatus status) {
    if (_providerKey() != key) return;
    _observe(status);
  }

  /// Whether what [attempt] learned is news for [key], that is, no attempt
  /// that started after it has been taken in yet. Marks it as the newest when
  /// it is.
  bool _isNewest(String key, int attempt) {
    final int? newest = _newestSettled[key];
    if (newest != null && newest > attempt) return false;
    _newestSettled[key] = attempt;
    return true;
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
