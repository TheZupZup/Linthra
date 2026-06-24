import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/launcher_icon_service.dart';
import '../../core/services/noop_launcher_icon_service.dart';
import '../../core/services/platform_launcher_icon_service.dart';

/// The single [LauncherIconService] the app switches the real Android launcher
/// icon through.
///
/// Defaults to the no-op implementation so widget and unit tests stay free of
/// platform channels (and non-Android hosts ignore the feature). The running
/// app overrides this with [platformLauncherIconServiceOverride] so the choice
/// actually changes the home-screen icon on Android. Mirrors the
/// [appIconVariantStoreProvider] seam.
final launcherIconServiceProvider = Provider<LauncherIconService>((ref) {
  return const NoopLauncherIconService();
});

/// Production binding: real launcher-icon switching on Android via
/// `<activity-alias>` toggling, a safe no-op elsewhere. Applied in `main`.
final platformLauncherIconServiceOverride =
    launcherIconServiceProvider.overrideWithValue(
  const PlatformLauncherIconService(),
);
