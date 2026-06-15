import 'dart:async';

import 'remote_command.dart';

/// A source of [RemoteCommand]s for one provider: it owns its own transport (a
/// control WebSocket to a Jellyfin server, a local Companion HTTP server + GDM
/// responder for Plex, …) and surfaces the neutral commands it receives on
/// [commands]. The provider-specific protocol, auth, and connection lifecycle
/// stay behind this seam — the mirror image of how `ServerPlaybackReporter`
/// hides the *reporting* side.
///
/// Contract for implementations:
///  - **Best-effort, never fatal.** A transport failure must never throw out of
///    [commands] or disturb playback; reconnects are the receiver's own
///    business.
///  - **Transport only.** A receiver may only ever emit the closed set of
///    [RemoteCommand]s, so remote control can never reach into the library.
abstract interface class RemoteControlReceiver {
  /// The neutral commands this provider's controller(s) have asked for. A
  /// broadcast stream: nothing is buffered for late listeners, so a command
  /// that arrives before [RemoteControlService] subscribes is simply dropped.
  Stream<RemoteCommand> get commands;

  /// Releases the transport (closes sockets/subscriptions). Idempotent.
  Future<void> dispose();
}

/// The receiver for setups with no remote control (no signed-in controllable
/// provider): an inert, empty command stream. Lets the wiring always hold a
/// receiver instead of special-casing "nothing to receive".
class NoOpRemoteControlReceiver implements RemoteControlReceiver {
  const NoOpRemoteControlReceiver();

  @override
  Stream<RemoteCommand> get commands => const Stream<RemoteCommand>.empty();

  @override
  Future<void> dispose() async {}
}
