import '../models/github_device_authorization.dart';
import '../models/github_sponsor_verification.dart';

/// Minimal GitHub API surface needed to unlock supporter cosmetics.
abstract interface class GitHubSponsorClient {
  bool get isConfigured;

  Future<GitHubDeviceAuthorization> requestDeviceAuthorization();

  /// Polls until the user approves the code, the code expires, or
  /// [isCancelled] says nobody is waiting for the answer any more. A
  /// cancelled poll stops before its next request and throws.
  Future<String> pollForAccessToken(
    GitHubDeviceAuthorization authorization, {
    bool Function()? isCancelled,
  });

  Future<GitHubSponsorVerification> verifySponsorship(String accessToken);
}

class GitHubSponsorAuthenticationException implements Exception {
  const GitHubSponsorAuthenticationException(this.message);

  final String message;

  @override
  String toString() => message;
}
