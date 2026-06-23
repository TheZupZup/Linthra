import 'playable_uri_resolver.dart';

/// Why a provider (Jellyfin, Plex, Subsonic/Navidrome) could or couldn't be
/// reached, at a finer grain than a bare "online/offline".
///
/// Wi-Fi being up does **not** mean a given server is reachable — a tunnel can
/// be down, the box can be asleep, a session can have expired, or the server can
/// simply be slow. Folding all of those into one "offline" bit makes the app
/// give the wrong advice (telling someone to "check your connection" when the
/// real fix is to sign in again). These five states are the vocabulary the rest
/// of the app branches on so it can pick a cached copy, fall back to another
/// provider, or show the *right* message:
///
///  - [reachable]: the server answered and accepted the session.
///  - [networkUnavailable]: the device has no usable network at all, so no
///    server can be reached — don't even try.
///  - [serverUnreachable]: there is a network, but this server couldn't be
///    reached (DNS, refused connection, TLS, or a 5xx). Another provider, or a
///    cached copy, may still work.
///  - [authFailure]: the server *was* reached but rejected the session
///    (expired/!invalid credentials). Retrying the same request won't help;
///    the user has to sign in again. Deliberately distinct from the offline
///    states so the UI never tells someone to "check your connection" when the
///    real fix is re-authenticating.
///  - [timeout]: a reachability probe ran past its deadline without an answer —
///    a hung or very slow server. Treated like [serverUnreachable] for
///    fallback, but named so diagnostics and messages can say "not responding"
///    rather than "couldn't connect".
enum ReachabilityStatus {
  reachable,
  networkUnavailable,
  serverUnreachable,
  authFailure,
  timeout;

  /// The server answered and accepted the session.
  bool get isReachable => this == ReachabilityStatus.reachable;

  /// The device has no usable network at all.
  bool get isOffline => this == ReachabilityStatus.networkUnavailable;

  /// The server was reached but rejected the session — a sign-in problem, not a
  /// connectivity one.
  bool get isAuthFailure => this == ReachabilityStatus.authFailure;

  /// A *server-level* outage worth remembering briefly so the next track skips a
  /// doomed probe: this server was found unreachable, or a probe ran past its
  /// deadline. These are the cacheable "don't re-try this server for a moment"
  /// states — a caller should prefer a cached or alternate copy instead.
  ///
  /// Two states are deliberately excluded:
  ///  - [networkUnavailable] is a *device-global* condition that flips the
  ///    instant the network returns, so it is judged fresh from connectivity on
  ///    every attempt and never cached — otherwise a stale "offline" would block
  ///    a working server for the cache's lifetime after a reconnect.
  ///  - [authFailure] means the server *was* reached; the fix is
  ///    re-authenticating, which must work immediately — never "don't bother".
  bool get isServerOutage =>
      this == ReachabilityStatus.serverUnreachable ||
      this == ReachabilityStatus.timeout;
}

/// Classifies a [PlaybackResolutionException] into the reachability signal it
/// implies about the *provider* (not the individual track), or `null` when the
/// failure says nothing reliable about whether the server is reachable.
///
/// This is the single bridge between the playback layer's per-track resolution
/// errors and the provider-wide reachability cache, so the two never drift: a
/// new [PlaybackResolutionErrorKind] is a compile error here rather than a
/// silently-misclassified outage.
///
/// Returns `null` for track-specific or content failures
/// ([PlaybackResolutionErrorKind.streamUnavailable],
/// [PlaybackResolutionErrorKind.invalidStream],
/// [PlaybackResolutionErrorKind.serverReturnedWebPage]) and for
/// [PlaybackResolutionErrorKind.notSignedIn]: the server may well be fine for
/// the *next* track, so caching "unreachable" off one of these would wrongly
/// suppress good copies.
ReachabilityStatus? reachabilityFromPlaybackError(
  PlaybackResolutionErrorKind kind,
) {
  switch (kind) {
    case PlaybackResolutionErrorKind.serverUnreachable:
      return ReachabilityStatus.serverUnreachable;
    case PlaybackResolutionErrorKind.sessionExpired:
      return ReachabilityStatus.authFailure;
    case PlaybackResolutionErrorKind.notSignedIn:
    case PlaybackResolutionErrorKind.invalidStream:
    case PlaybackResolutionErrorKind.serverReturnedWebPage:
    case PlaybackResolutionErrorKind.streamUnavailable:
      return null;
  }
}
