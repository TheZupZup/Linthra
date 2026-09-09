import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/desktop_window_lifecycle_service.dart';
import '../../../data/repositories/desktop_window_controller_provider.dart';
import '../../player/player_providers.dart';

/// The service that keeps the desktop runner's close behaviour in step with
/// the user's choice and with playback, and that owns the explicit quit
/// (issue #401).
///
/// Created lazily and inert off the desktop: with the default
/// [NoopDesktopWindowController] behind it, nothing is pushed anywhere. The
/// running app starts it from `bootstrapApplication`, which is also where it
/// is handed the graceful shutdown it runs before the process ends.
final desktopWindowLifecycleServiceProvider =
    Provider<DesktopWindowLifecycleService>((ref) {
  final DesktopWindowLifecycleService service = DesktopWindowLifecycleService(
    window: ref.watch(desktopWindowControllerProvider),
    playback: ref.watch(playbackControllerProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
