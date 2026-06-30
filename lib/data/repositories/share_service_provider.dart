import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/noop_share_service.dart';
import '../../core/services/platform_share_service.dart';
import '../../core/services/share_service.dart';

/// The single [ShareService] the app opens the native share sheet through.
///
/// Defaults to the no-op implementation so widget and unit tests stay free of
/// platform channels (and non-Android hosts ignore the feature). The running
/// app overrides this with [platformShareServiceOverride] so "Share Linthra"
/// actually opens the system share sheet on Android. Mirrors the
/// [launcherIconServiceProvider] seam.
final shareServiceProvider = Provider<ShareService>((ref) {
  return const NoopShareService();
});

/// Production binding: the real Android share sheet, a safe no-op elsewhere.
/// Applied in `main`.
final platformShareServiceOverride =
    shareServiceProvider.overrideWithValue(const PlatformShareService());
