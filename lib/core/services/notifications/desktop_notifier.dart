import 'package:flutter/foundation.dart';

/// One notification Linthra is asking the desktop to show, reduced to the
/// three things a shell actually draws.
///
/// Deliberately a plain value with no provider, session or playback types in
/// it. Everything that decides *what may be said* happens before a
/// [DesktopNotification] exists (see `nowPlayingNotification`), so the
/// transport underneath can be read as "put these fields on the bus" rather
/// than audited for what it might reach into.
@immutable
class DesktopNotification {
  const DesktopNotification({
    required this.title,
    this.body = '',
    this.image,
  });

  /// The heading: a track title, never a path, id or URL.
  final String title;

  /// The second line, empty when the catalog knows nothing to put there.
  final String body;

  /// A cover the notification daemon can open by itself, or null.
  ///
  /// Only ever a `file:` URI into one of Linthra's own artwork caches. Those
  /// live under the application cache directory, which is a real host path
  /// inside a Flatpak as much as outside it, so the daemon can read it, and
  /// the file is a credential-free copy Linthra wrote, not a file from the
  /// user's library. Nothing else gets this far: see
  /// `nowPlayingNotification`.
  final Uri? image;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DesktopNotification &&
          other.title == title &&
          other.body == body &&
          other.image == image);

  @override
  int get hashCode => Object.hash(title, body, image);

  @override
  String toString() =>
      'DesktopNotification(title: $title, body: $body, image: $image)';
}

/// The one seam Linthra shows a desktop notification through.
///
/// It exists so the *decision* to notify (see `TrackChangeNotifier`) is
/// testable without a session bus, and so the platform-specific transport is
/// reached through one narrow interface rather than from wherever a widget
/// happens to want a toast. In particular there is no "run notify-send"
/// anywhere in the app: on Linux this is a D-Bus call
/// (`DBusDesktopNotifier`), which is what a desktop notification actually is.
abstract interface class DesktopNotifier {
  /// Whether this host has a notification seam at all. False for the no-op,
  /// which is what every non-Linux platform gets.
  bool get isSupported;

  /// Shows [notification], replacing whichever one this notifier showed last.
  ///
  /// Best-effort: an implementation swallows a missing daemon, a refused call
  /// and a bus that went away, because a notification that did not appear is
  /// never worth failing anything else over. Callers guard anyway (see
  /// `TrackChangeNotifier`), so a future or test implementation that does
  /// throw still cannot reach playback.
  Future<void> show(DesktopNotification notification);

  /// Releases whatever the notifier holds (on Linux, a bus connection).
  /// Idempotent and never throws.
  Future<void> dispose();
}

/// A [DesktopNotifier] that shows nothing.
///
/// What Android and every non-Linux platform get, and what tests get unless
/// they ask for something else. A real, named class rather than a nullable
/// notifier: "this platform has no desktop notifications" is a fact the
/// settings card and diagnostics can read, and one the notification path can
/// short-circuit on without a platform check of its own.
class NoopDesktopNotifier implements DesktopNotifier {
  const NoopDesktopNotifier();

  @override
  bool get isSupported => false;

  @override
  Future<void> show(DesktopNotification notification) async {}

  @override
  Future<void> dispose() async {}
}
