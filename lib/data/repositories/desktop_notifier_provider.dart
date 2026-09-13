import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import '../../core/services/notifications/desktop_notifier.dart';
import '../../core/services/notifications/platform_desktop_notifier.dart';

/// The single seam the app shows a desktop notification through.
///
/// Defaults to the no-op implementation so unit and widget tests never open a
/// session bus. The running app overrides this with
/// [platformDesktopNotifierOverride], which gives Linux the real D-Bus
/// notifier and leaves every other platform, Android included, on the no-op.
/// Mirrors the [audioOutputDeviceServiceProvider] seam.
final desktopNotifierProvider = Provider<DesktopNotifier>(
  (ref) => const NoopDesktopNotifier(),
);

/// Production binding: real D-Bus notifications on Linux, a safe no-op
/// elsewhere. Applied in `main`.
///
/// Overridden with a builder rather than a value because this seam owns a
/// resource: the bus connection it opens on first use is released with the
/// container, and awaited by the shutdown lifecycle.
final platformDesktopNotifierOverride =
    desktopNotifierProvider.overrideWith((ref) {
  final PlatformDesktopNotifier notifier = PlatformDesktopNotifier();
  ref.onDisposeAsync(notifier.dispose);
  return notifier;
});
