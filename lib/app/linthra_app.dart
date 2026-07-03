import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/services/active_playback_controller.dart';
import '../core/services/notification_permission.dart';
import '../core/services/stability_diagnostics.dart';
import '../features/appearance/app_icon_controller.dart';
import '../features/library/remote_library_refresher.dart';
import '../features/player/player_providers.dart';
import 'brand_theme.dart';
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
      // Best-effort and defensive: a notification-permission seam that fails (a
      // plugin hiccup, or a denied/unavailable grant) must never crash startup
      // or playback — background audio works without the notification. The
      // production seam already swallows its own errors; guarding the call site
      // too keeps "permission denied does not crash the app" true end to end.
      ref
          .read(notificationPermissionProvider)
          .ensureGranted()
          .catchError((Object _) {});
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
    // On a background transition (screen off / app hidden), snapshot the
    // playback status so a "music stopped when I locked the phone" report can
    // show what state playback was in at that exact boundary. This only reads
    // the controller's status — it never pauses, stops, or disposes playback.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      final status = ref.read(playbackControllerProvider).state.status;
      StabilityDiagnostics.backgroundPlaybackState(status.name);
    }
    // Returning from the background while casting: re-sync from the receiver so
    // the position the UI shows is fresh. This never starts local playback —
    // backgrounding/foregrounding the app must not recreate or resume the local
    // engine while a cast session owns playback.
    if (state == AppLifecycleState.resumed) {
      final controller = ref.read(playbackControllerProvider);
      if (controller is ActivePlaybackController) {
        controller.onAppResumed();
      }
      // Smart refresh: pick up playlist/favourite changes made on a connected
      // server (Navidrome/Jellyfin) from another client while we were away, and
      // retry any heart that hadn't reached the server yet. Throttled,
      // best-effort, and offline-tolerant — never blocks the resume.
      ref.read(remoteLibraryRefresherProvider).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    // Retheme the whole app from the selected branding variant: the picker is a
    // complete visual theme selector, not only a launcher-icon picker. The
    // controller already loads the persisted choice on startup and serves
    // Classic until then, so the theme restores on restart for free.
    final variant = ref.watch(appIconControllerProvider);
    return MaterialApp.router(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        BrandPalettes.byId(variant.id, brightness: Brightness.light),
      ),
      darkTheme: AppTheme.dark(
        BrandPalettes.byId(variant.id, brightness: Brightness.dark),
      ),
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
