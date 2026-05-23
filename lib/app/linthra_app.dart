import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/services/notification_permission.dart';
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

class _LinthraAppState extends ConsumerState<LinthraApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationPermissionProvider).ensureGranted();
    });
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
