/// A provider-neutral remote playback command: one transport action a remote
/// controller has asked Linthra to perform on whatever is playing now.
///
/// Remote controllers speak very different wire protocols — Plex's Companion
/// `/player/playback/*` requests, a Jellyfin control WebSocket's
/// `PlaystateCommand` messages — but they all reduce to the same small set of
/// transport intents. Each provider's `RemoteControlReceiver` maps its protocol
/// onto these neutral commands, and `RemoteControlService` maps these onto the
/// existing `PlaybackController`, so a remote command takes exactly the same
/// path as the user tapping the matching on-screen control.
///
/// The set is deliberately closed to **transport only**: there is no command
/// that reads, creates, edits, or deletes anything in the library — no
/// playlist, favorite, rating, or catalog mutation — so by construction remote
/// control can never reach past play/pause/skip/seek into the user's library.
sealed class RemoteCommand {
  const RemoteCommand();
}

/// Begin, or resume, playback of the current track.
final class RemotePlay extends RemoteCommand {
  const RemotePlay();

  @override
  bool operator ==(Object other) => other is RemotePlay;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Pause playback, keeping the current track and position.
final class RemotePause extends RemoteCommand {
  const RemotePause();

  @override
  bool operator ==(Object other) => other is RemotePause;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Toggle between playing and paused — what most controllers send for a single
/// play/pause button. [RemoteControlService] consults the live playback state
/// to decide which way to flip.
final class RemotePlayPause extends RemoteCommand {
  const RemotePlayPause();

  @override
  bool operator ==(Object other) => other is RemotePlayPause;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Stop playback.
final class RemoteStop extends RemoteCommand {
  const RemoteStop();

  @override
  bool operator ==(Object other) => other is RemoteStop;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Skip to the next track in the queue.
final class RemoteNext extends RemoteCommand {
  const RemoteNext();

  @override
  bool operator ==(Object other) => other is RemoteNext;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Skip to the previous track in the queue.
final class RemotePrevious extends RemoteCommand {
  const RemotePrevious();

  @override
  bool operator ==(Object other) => other is RemotePrevious;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Seek the current track to [position].
final class RemoteSeek extends RemoteCommand {
  const RemoteSeek(this.position);

  /// The absolute position to seek to from the start of the track.
  final Duration position;

  @override
  bool operator ==(Object other) =>
      other is RemoteSeek && other.position == position;

  @override
  int get hashCode => position.hashCode;
}
