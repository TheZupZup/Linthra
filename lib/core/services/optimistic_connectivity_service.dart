import 'connectivity_service.dart';

/// A placeholder [ConnectivityService] that always reports Wi-Fi.
///
/// There is no network detection plugin yet (and nothing downloads over the
/// network — the offline cache foundation only marks already-local tracks). The
/// real implementation, backed by `connectivity_plus`, lands alongside remote
/// (Jellyfin/WebDAV) downloads, where the mobile-data gate actually has data
/// to guard. Until then this keeps the seam wired and the default app behaving
/// as "connected", while tests inject a fake to exercise the mobile/offline/
/// unknown branches of the download policy.
class OptimisticConnectivityService implements ConnectivityService {
  const OptimisticConnectivityService();

  @override
  Stream<NetworkStatus> get statusStream =>
      Stream<NetworkStatus>.value(NetworkStatus.wifi);

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}
