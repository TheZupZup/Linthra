/// Codes returned by GitHub's OAuth device authorization endpoint.
class GitHubDeviceAuthorization {
  const GitHubDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.pollInterval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration pollInterval;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);
}
