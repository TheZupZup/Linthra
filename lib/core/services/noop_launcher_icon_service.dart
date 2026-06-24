import 'launcher_icon_service.dart';

/// A [LauncherIconService] that does nothing.
///
/// It is the default provider binding (so unit/widget tests stay free of
/// platform channels) and the fallback on every non-Android platform, where
/// there is no runtime launcher-icon switching. [isSupported] is `false` and
/// [applyVariant] is a no-op returning `false`, so the in-app branding
/// selection keeps working and the UI degrades gracefully.
class NoopLauncherIconService implements LauncherIconService {
  const NoopLauncherIconService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> applyVariant(String variantId) async => false;
}
