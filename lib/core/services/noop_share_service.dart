import 'share_service.dart';

/// A [ShareService] that does nothing.
///
/// It is the default provider binding (so unit/widget tests stay free of
/// platform channels) and the fallback on every non-Android platform, where
/// there is no native share sheet wired up. [isSupported] is `false` and
/// [share] is a no-op returning `false`, so the About page simply hides the
/// "Share Linthra" entry and the rest of the page is unaffected.
class NoopShareService implements ShareService {
  const NoopShareService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> share(String text) async => false;
}
