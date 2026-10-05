import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/flatpak_sandbox.dart';
import '../../core/services/background_permission.dart';
import '../../core/services/portal_background_permission.dart';
import 'download_repository_provider.dart';

/// Asks the desktop whether Linthra may keep running with its window closed
/// (#754), or null where there is nothing to ask. Null by default, so tests
/// and every host but the Flatpak never put the question.
final backgroundPermissionRequesterProvider =
    Provider<BackgroundPermissionRequester?>((ref) => null);

/// Production binding (Linux): the Background portal, inside the Flatpak
/// only. That is where xdg-desktop-portal's background monitor kills an app
/// with no window open when its permission says no; a native build has no
/// such monitor, and nothing to ask.
final linuxBackgroundPermissionOverride =
    backgroundPermissionRequesterProvider.overrideWith((ref) {
  if (!isFlatpakSandbox) return null;
  return PortalBackgroundPermission(
      connect: ref.watch(linuxSessionBusProvider));
});
