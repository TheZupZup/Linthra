import '../sources/source_availability.dart';

/// What a library row can honestly say about whether this track plays right
/// now, and what it would play *from*.
///
/// The row already carries a download glyph — queued, downloading, a failed
/// ring — but that describes an in-flight *task*. This is the other axis: the
/// settled answer, once nothing is being transferred. It exists because a row
/// backed by a server raises a question a row backed by a file never does —
/// "will this still play when the server is away?" — and the answer differs per
/// row: an explicitly downloaded copy, an auto-preloaded one, a server that is
/// answering, a server that is not.
///
/// Two properties are deliberate:
///
///  * **[none] is the answer for the overwhelming majority of rows**, including
///    every on-device track and every server-backed track whose server is
///    answering and which has no copy of its own. An indicator that is always
///    lit is an indicator nobody reads, and a library row is the busiest pixel
///    in the app — so the interesting entries have to earn their place by being
///    the exception.
///  * **It is derived, never probed.** Every input below already exists in the
///    app: the per-source availability the probe controller publishes and the
///    live offline-cache set. Nothing here reaches a network, and nothing here
///    knows what a URL, a token, or a file path is — which is what keeps the
///    indicator safe to render on a row that may be showing a locked-down
///    server's music.
enum TrackAvailabilityStatus {
  /// Nothing worth saying: on-device music, or server-backed music whose server
  /// is answering and which has no saved copy. Renders nothing.
  none,

  /// A copy the user asked for is on this device, and its server is answering.
  downloaded,

  /// A copy is on this device only because the app prefetched it ahead of play
  /// (see `CachedTrack.preloaded`), and its server is answering. Cached, but
  /// evictable — which is exactly what separates it from [downloaded].
  cached,

  /// A copy is on this device and its server is *away*. This is the good news
  /// case: it is the only reason this row still plays, so it says what the
  /// listener is getting rather than what they are missing.
  offlineCopy,

  /// The owning server is configured and a probe is in flight, so we do not
  /// know yet. Deliberately rendered as *checking*, not as a failure — matching
  /// [SourceAvailability.checking], which hides nothing for the same reason.
  checking,

  /// The server could not be reached and this device has no copy, so this row
  /// will not play right now. Recoverable: nothing was deleted, and the row
  /// returns to [none] the moment the server answers again.
  unreachable,

  /// The server was reached but rejected the saved session, and this device has
  /// no copy. Kept distinct from [unreachable] because the fix is signing in
  /// again, not moving closer to the server — the same distinction
  /// [SourceAvailability] draws for diagnostics.
  sessionRejected,
}

/// Resolves the settled availability of one row from state that already exists.
///
/// Pure and total, so every combination — including the ones that are awkward to
/// stage in a widget test — is pinned down in `track_availability_test.dart`
/// rather than inferred from pixels.
///
/// [isRemote] short-circuits first: on-device music has no server to be away
/// from, so it can never have anything to report. Everything below is about a
/// row that came off a server.
///
/// A saved copy outranks the server's state on purpose. A copy that plays —
/// [downloaded], [cached], [offlineCopy] — is a better answer than "the server
/// is down", because the server's state has stopped being the interesting fact;
/// whether the listener can hear the song has not. That is also why
/// [offlineCopy] is reported even while a probe is still running.
TrackAvailabilityStatus resolveTrackAvailability({
  required bool isRemote,
  required bool hasOfflineCopy,
  required bool isExplicitDownload,
  required SourceAvailability availability,
}) {
  if (!isRemote) return TrackAvailabilityStatus.none;

  if (hasOfflineCopy) {
    // The only case where the server's absence changes the sentence rather
    // than silencing it: the copy is not a convenience any more, it is the
    // whole reason this row works.
    if (availability.isUnavailable) return TrackAvailabilityStatus.offlineCopy;
    return isExplicitDownload
        ? TrackAvailabilityStatus.downloaded
        : TrackAvailabilityStatus.cached;
  }

  // Nothing saved locally, so the server is the only way this plays.
  if (availability == SourceAvailability.authenticationError) {
    return TrackAvailabilityStatus.sessionRejected;
  }
  if (availability == SourceAvailability.unreachable) {
    return TrackAvailabilityStatus.unreachable;
  }
  if (availability.isChecking) return TrackAvailabilityStatus.checking;

  // `available`, and `notConfigured` with it: an unconfigured source has no
  // rows, and the availability map treats every source it does not list as
  // reachable (see `sourceAvailabilityProvider`). Either way there is no
  // server fact worth putting on the row.
  return TrackAvailabilityStatus.none;
}
