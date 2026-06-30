import 'dart:io';

import 'android_share_service.dart';
import 'noop_share_service.dart';
import 'share_service.dart';

/// The default [ShareService]: the real share sheet on Android, a safe no-op
/// everywhere else.
///
/// This is the one place that knows about the platform split, mirroring
/// [PlatformLauncherIconService]. On Android it delegates to
/// [AndroidShareService] (the `ACTION_SEND` chooser); on every other platform
/// it uses [NoopShareService] so the feature is ignored safely and the About
/// page simply omits the "Share Linthra" entry.
class PlatformShareService implements ShareService {
  const PlatformShareService({
    ShareService androidService = const AndroidShareService(),
    ShareService fallbackService = const NoopShareService(),
  })  : _androidService = androidService,
        _fallbackService = fallbackService;

  final ShareService _androidService;
  final ShareService _fallbackService;

  ShareService get _delegate =>
      Platform.isAndroid ? _androidService : _fallbackService;

  @override
  bool get isSupported => _delegate.isSupported;

  @override
  Future<bool> share(String text) => _delegate.share(text);
}
