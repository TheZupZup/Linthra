import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/services/active_playback_controller.dart';
import '../core/services/notification_permission.dart';
import '../core/services/stability_diagnostics.dart';
import '../features/player/player_providers.dart';
import 'router.dart';
import 'theme.dart';

/// The notification-permission seam the app asks through on first launch.
///
/// Defaults to the `permission_handler`-backed request (a no-op off Android and
/// when already granted); tests override it with a fake so pumping the app
/// never triggers a real OS prompt.
final notificationPermissionProvider = Provider<NotificationPermission>((ref) {
  return const PermissionHandlerNotificationPermission();
});

/// Root widget. Dark mode is the primary experience; the light theme follows
/// the system setting when the user opts out of dark.
///
/// On first build it asks for the notification permission once, after the first
/// frame, so the Android 13+ `POST_NOTIFICATIONS` prompt has an attached
/// activity and the media notification can actually appear. The request is
/// best-effort and never blocks the UI.
class LinthraApp extends ConsumerStatefulWidget {
  const LinthraApp({super.key});

  @override
  ConsumerState<LinthraApp> createState() => _LinthraAppState();
}

class _LinthraAppState extends ConsumerState<LinthraApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationPermissionProvider).ensureGranted();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A secret-free breadcrumb (debug only): freezes/ANRs cluster around
    // background/foreground, so logging the transition makes them correlatable.
    StabilityDiagnostics.lifecycle(state.name);
    // Returning from the background while casting: re-sync from the receiver so
    // the position the UI shows is fresh. This never starts local playback —
    // backgrounding/foregrounding the app must not recreate or resume the local
    // engine while a cast session owns playback.
    if (state == AppLifecycleState.resumed) {
      final controller = ref.read(playbackControllerProvider);
      if (controller is ActivePlaybackController) {
        controller.onAppResumed();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
