/// Network reachability, abstracted so the downloads feature can enforce the
/// user's "Wi-Fi only downloads" preference without binding to a plugin.
enum NetworkStatus { offline, wifi, mobile }

abstract interface class ConnectivityService {
  /// Emits whenever connectivity changes.
  Stream<NetworkStatus> get statusStream;

  /// One-shot read of the current status.
  Future<NetworkStatus> currentStatus();
}
