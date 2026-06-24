import 'dart:io';

import 'android_launcher_icon_service.dart';
import 'launcher_icon_service.dart';
import 'noop_launcher_icon_service.dart';

/// The default [LauncherIconService]: real switching on Android, a safe no-op
/// everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// `PlatformFolderPickerService`. On Android it delegates to
/// [AndroidLauncherIconService] (the `<activity-alias>` toggle); on every other
/// platform it uses [NoopLauncherIconService] so the feature is ignored safely
/// and the in-app branding selection still applies.
class PlatformLauncherIconService implements LauncherIconService {
  const PlatformLauncherIconService({
    LauncherIconService androidService = const AndroidLauncherIconService(),
    LauncherIconService fallbackService = const NoopLauncherIconService(),
  })  : _androidService = androidService,
        _fallbackService = fallbackService;

  final LauncherIconService _androidService;
  final LauncherIconService _fallbackService;

  LauncherIconService get _delegate =>
      Platform.isAndroid ? _androidService : _fallbackService;

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<bool> applyVariant(String variantId) =>
      _delegate.applyVariant(variantId);
}
