import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/services/active_playback_controller.dart';
import '../core/services/notification_permission.dart';
import '../core/services/stability_diagnostics.dart';
import '../features/appearance/app_icon_controller.dart';
import '../features/appearance/custom_brand_palette.dart';
import '../features/appearance/custom_theme_controller.dart';
import '../features/appearance/selected_logo_mark.dart';
import '../features/appearance/theme_mode_controller.dart';
import '../features/library/remote_library_refresher.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/player/player_providers.dart';
import '../features/support/support_actions_provider.dart';
import '../features/support/supporter_entitlement.dart';
import 'application_lifecycle.dart';
import 'brand_theme.dart';
import 'router.dart';
import 'theme.dart';

/// The notification-permission seam the app asks through after onboarding.
///
/// Defaults to the `permission_handler`-backed request (a no-op off Android and
/// when already granted); tests override it with a fake so pumping the app
/// never triggers a real OS prompt.
final notificationPermissionProvider = Provider<NotificationPermission>((ref) {
  return const PermissionHandlerNotificationPermission();
});

/// Root widget. Linthra follows the device's light/dark setting by default; the
/// user can pin Light or Dark in Settings → Appearance, and that choice is read
/// from storage before the first frame (see `readStoredThemeMode`) so launching
/// never flashes the wrong theme.
///
/// System mode is plain `ThemeMode.system`, handed to `MaterialApp` below along
/// with both `theme` and `darkTheme`: Flutter itself resolves it from the
/// engine's platform-brightness signal and repaints live whenever that signal
/// changes, via the same `WidgetsBindingObserver.didChangePlatformBrightness`
/// path on every platform. Linthra never reads that signal itself and never
/// shells out to `gsettings`, D-Bus, or a GNOME/KDE-specific command — there is
/// deliberately no Linux-only theme code; Light, Dark, and System all resolve
/// through this one shared path on Android and Linux alike.
///
/// On Linux, *supplying* that signal is the Flutter engine's job, not
/// Linthra's: the GTK embedder derives it from the desktop's own light/dark
/// preference (`flutter/engine`'s `fl_settings.cc`, via the XDG desktop portal
/// or a GNOME GSettings fallback) and pushes live changes the same way Android
/// does. That native bridge is outside this app's code and isn't independently
/// exercised by Linthra's widget tests — see docs/linux-desktop.md's
/// "Light/Dark/System theme" row for what is and isn't verified.
class LinthraApp extends ConsumerStatefulWidget {
  const LinthraApp({super.key, this.lifecycle});

  /// Root lifecycle handle installed by `main`. When the embedder delivers
  /// [AppLifecycleState.detached], this runs [ApplicationHandle.shutdown].
  final ApplicationHandle? lifecycle;

  @override
  ConsumerState<LinthraApp> createState() => _LinthraAppState();
}

class _LinthraAppState extends ConsumerState<LinthraApp>
    with WidgetsBindingObserver {
  bool _notificationPermissionRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _requestNotificationPermissionOnce() {
    if (_notificationPermissionRequested) return;
    _notificationPermissionRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // First installs reach this only after the user leaves onboarding, so the
      // very first thing Linthra does is never an unexplained Android permission
      // prompt. Existing/update installs keep the previous behaviour and ask on
      // their first app frame when needed.
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
    StabilityDiagnostics.lifecycle(state.name);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      final controller = ref.read(playbackControllerProvider);
      StabilityDiagnostics.backgroundPlaybackState(
          controller.state.status.name);
      // Arm suspend recovery only on a true pause (system sleep / window
      // background). Brief `inactive` (dialogs, focus blips) must not reload.
      if (state == AppLifecycleState.paused &&
          controller is ActivePlaybackController) {
        controller.onAppBackgrounded();
      }
    }
    if (state == AppLifecycleState.resumed) {
      final controller = ref.read(playbackControllerProvider);
      if (controller is ActivePlaybackController) {
        controller.onAppResumed();
      }
      ref.read(remoteLibraryRefresherProvider).refresh();
    }
    if (state == AppLifecycleState.detached) {
      unawaited(widget.lifecycle?.shutdown());
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeControllerProvider);
    final variant = ref.watch(appIconControllerProvider);
    final customTheme = ref.watch(customThemeControllerProvider);
    final distribution = ref.watch(supportDistributionProvider);
    final supporterEntitlement = ref.watch(supporterEntitlementProvider);
    final onboardingBootstrap = ref.watch(onboardingBootstrapProvider);

    BrandPalette paletteFor(Brightness brightness) {
      final bool mayApplyCustomPalette = distribution.offersCustomPalette &&
          supporterEntitlement.allowsCosmetics &&
          customTheme.enabled;
      if (mayApplyCustomPalette) {
        return customBrandPalette(customTheme, brightness: brightness);
      }
      return BrandPalettes.byId(variant.id, brightness: brightness);
    }

    final ThemeData lightTheme = AppTheme.light(paletteFor(Brightness.light));
    final ThemeData darkTheme = AppTheme.dark(paletteFor(Brightness.dark));

    // Do not construct the router until first-install/update state is known.
    // This tiny branded launch surface prevents both a library→welcome flash and
    // a welcome→library flash while SharedPreferences/native install history are
    // being resolved.
    if (onboardingBootstrap.isLoading) {
      return MaterialApp(
        title: AppInfo.name,
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: themeMode.materialThemeMode,
        home: const _BootstrapSurface(),
      );
    }

    final router = ref.watch(appRouterProvider);
    final bool onboardingCompleted = ref.watch(onboardingControllerProvider);
    if (onboardingCompleted) {
      _requestNotificationPermissionOnce();
    }

    return MaterialApp.router(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode.materialThemeMode,
      routerConfig: router,
    );
  }
}

class _BootstrapSurface extends StatelessWidget {
  const _BootstrapSurface();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SelectedLinthraLogoMark(size: 72),
            SizedBox(height: 24),
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
