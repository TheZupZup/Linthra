import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/desktop_window_controller.dart';
import '../../core/services/method_channel_linux_window.dart';

/// The desktop window Linthra manages its close behaviour through (#401).
///
/// Defaults to [NoopDesktopWindowController] so widget and unit tests stay
/// free of platform channels and every non-desktop host ignores the feature.
/// The running Linux app overrides this with
/// [linuxDesktopWindowControllerOverride]. Mirrors the
/// [launcherIconServiceProvider] seam.
final desktopWindowControllerProvider = Provider<DesktopWindowController>(
  (ref) => const NoopDesktopWindowController(),
);

/// Production binding for Linux: the runner's window-lifecycle channel.
/// Applied in `main` only on Linux, so no other host ever opens the channel.
final linuxDesktopWindowControllerOverride =
    desktopWindowControllerProvider.overrideWith((ref) {
  final MethodChannelLinuxWindow controller = MethodChannelLinuxWindow();
  ref.onDispose(controller.dispose);
  return controller;
});
