import '../platform/host_platform.dart';

/// How long ending a desktop app (closing the window, or an explicit quit)
/// waits for the graceful shutdown before the process ends anyway. The
/// shutdown normally takes well under a second; this is the bound for one that
/// does not finish.
const Duration exitShutdownDeadline = Duration(seconds: 5);

/// Which platforms treat `AppLifecycleState.detached` as "the application is
/// ending — run the graceful shutdown".
///
/// One named rule instead of a bare `state == detached` in the widget layer,
/// because the same lifecycle value means two different things:
///
///  * On a **desktop** host, the embedder detaches the engine when the last
///    window is closing and the process is on its way out. Nothing else keeps
///    Linthra alive, so this is exactly the moment to close the database, stop
///    the audio engine, and drop the remote-control socket — the deterministic
///    Linux shutdown issue #464 asks for.
///  * On **Android** (and iOS), `detached` also arrives when the *Activity* is
///    destroyed while the application keeps running: `audio_service` holds a
///    foreground service so playback continues with no UI attached, and the
///    engine can be re-attached to a new Activity afterwards. Shutting the app
///    down there would stop background audio and leave a re-attached UI talking
///    to a disposed container. Android's teardown stays where it already is —
///    the platform stopping the service, and the process ending.
///
/// So the graceful-shutdown path is desktop-only. It is not "Linux only" by
/// name: any host whose detach means the process is ending belongs here, and
/// Linux is the desktop target Linthra ships today.
abstract final class PlatformShutdownPolicy {
  /// Whether [AppLifecycleState.detached] should run
  /// `ApplicationHandle.shutdown()` on [host].
  static bool shutsDownOnDetached(HostPlatform host) =>
      host == HostPlatform.linux ||
      host == HostPlatform.macOS ||
      host == HostPlatform.windows;
}
