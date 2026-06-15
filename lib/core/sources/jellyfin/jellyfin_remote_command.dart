import '../../services/remote_command.dart';

/// Maps a Jellyfin control-WebSocket message to a neutral [RemoteCommand], or
/// `null` when the message is not a transport command Linthra acts on.
///
/// Jellyfin pushes remote-control intents over the session WebSocket as JSON
/// envelopes `{ "MessageType": "...", "Data": {...} }`. The transport commands
/// arrive as `MessageType: "Playstate"` with a `Data.Command` naming the action
/// (and, for a seek, `Data.SeekPositionTicks`). Everything else — other message
/// types, the volume/`GeneralCommand`s Linthra has no transport for, unknown or
/// unsupported commands — maps to `null` and is ignored, so the socket can
/// carry anything without surprising playback.
///
/// Pure and side-effect-free: it only translates, so it is exhaustively
/// unit-testable and carries no transport, auth, or I/O concerns. The match is
/// case-insensitive on both the message type and the command name, so a casing
/// difference between server versions can't silently drop a command.
abstract final class JellyfinRemoteCommand {
  /// The `MessageType` that carries a playstate transport command.
  static const String playstateMessageType = 'Playstate';

  /// Jellyfin records position in ticks of 100 ns, so there are 10 ticks per
  /// microsecond (10,000,000 per second) — the same unit `PositionTicks` and
  /// `RunTimeTicks` use elsewhere. A seek's `SeekPositionTicks` is converted to
  /// a [Duration] through this.
  static const int _ticksPerMicrosecond = 10;

  /// Translates one decoded WebSocket [message] into a neutral command, or
  /// returns `null` when it is not a transport command Linthra applies.
  static RemoteCommand? fromMessage(Map<String, dynamic> message) {
    final Object? type = message['MessageType'];
    if (type is! String) return null;
    if (type.toLowerCase() != playstateMessageType.toLowerCase()) return null;

    final Object? data = message['Data'];
    if (data is! Map<String, dynamic>) return null;

    final Object? command = data['Command'];
    if (command is! String) return null;

    switch (command.toLowerCase()) {
      case 'play':
      case 'unpause':
        return const RemotePlay();
      case 'pause':
        return const RemotePause();
      case 'playpause':
        return const RemotePlayPause();
      case 'stop':
        return const RemoteStop();
      case 'nexttrack':
        return const RemoteNext();
      case 'previoustrack':
        return const RemotePrevious();
      case 'seek':
        final Duration? position = _seekPosition(data);
        return position == null ? null : RemoteSeek(position);
      default:
        // Rewind / FastForward and anything else Linthra doesn't model.
        return null;
    }
  }

  static Duration? _seekPosition(Map<String, dynamic> data) {
    final Object? ticks = data['SeekPositionTicks'];
    int? value;
    if (ticks is int) {
      value = ticks;
    } else if (ticks is double) {
      value = ticks.toInt();
    }
    if (value == null || value < 0) return null;
    return Duration(microseconds: value ~/ _ticksPerMicrosecond);
  }
}
