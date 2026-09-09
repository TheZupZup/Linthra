import 'dart:async';

/// Whether the desktop window is on screen or hidden in the background.
enum DesktopWindowVisibility { shown, hidden }

/// The native desktop window, as much of it as the close-behaviour feature
/// needs (issue #401).
///
/// The Linux implementation talks to Linthra's own GTK runner
/// (`linux/runner/window_lifecycle_channel.cc`); every other platform gets
/// [NoopDesktopWindowController], so the shared lifecycle code can be written
/// once without asking which host it is on.
abstract interface class DesktopWindowController {
  /// Tells the runner what the next window close should do: hide the window
  /// ([hideOnClose] true) or let it be destroyed, which ends the process.
  ///
  /// Pushed rather than asked for, because a GTK `delete-event` handler has to
  /// answer synchronously and Dart cannot be consulted inside it.
  Future<void> setHideOnClose(bool hideOnClose);

  /// Brings a hidden window back: what MPRIS `Raise` and a second launch of
  /// an already-running Linthra both mean.
  Future<void> showWindow();

  /// Ends the process. Called only after the app has released what it owns.
  Future<void> quit();

  /// Visibility changes reported by the runner: the window being hidden by a
  /// close, and being presented again.
  Stream<DesktopWindowVisibility> get visibility;
}

/// The "this platform has no window to manage" controller: Android, and any
/// desktop whose runner does not implement the channel.
///
/// A real named class rather than a silent `if`, for the same reason
/// [UnsupportedMediaSessionBinding] is one: the shared service can then be
/// wired identically everywhere and simply do nothing off the desktop.
class NoopDesktopWindowController implements DesktopWindowController {
  const NoopDesktopWindowController();

  @override
  Future<void> setHideOnClose(bool hideOnClose) async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> quit() async {}

  @override
  Stream<DesktopWindowVisibility> get visibility =>
      const Stream<DesktopWindowVisibility>.empty();
}
