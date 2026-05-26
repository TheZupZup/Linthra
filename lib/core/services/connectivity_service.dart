/// Network reachability, abstracted so the downloads feature can enforce the
/// user's mobile-data download preference without binding to a plugin.
///
///  - [offline]: no usable connection — downloads wait.
///  - [wifi]: an unmetered connection — downloads always allowed.
///  - [mobile]: a metered/cellular connection — downloads allowed only when the
///    user has turned on "Allow mobile data".
///  - [unknown]: the connection type couldn't be determined. Treated
///    conservatively (like [mobile]): downloads run only when the user has
///    allowed mobile data, so an unknown connection is never assumed unmetered.
enum NetworkStatus { offline, wifi, mobile, unknown }

abstract interface class ConnectivityService {
  /// Emits whenever connectivity changes.
  Stream<NetworkStatus> get statusStream;

  /// One-shot read of the current status.
  Future<NetworkStatus> currentStatus();
}
