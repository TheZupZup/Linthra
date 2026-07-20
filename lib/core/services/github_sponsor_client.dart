import '../models/github_device_authorization.dart';
import '../models/github_sponsor_verification.dart';

/// Minimal GitHub API surface needed to unlock supporter cosmetics.
abstract interface class GitHubSponsorClient {
  bool get isConfigured;

  Future<GitHubDeviceAuthorization> requestDeviceAuthorization();

  Future<String> pollForAccessToken(
    GitHubDeviceAuthorization authorization,
  );

  Future<GitHubSponsorVerification> verifySponsorship(String accessToken);
}

class GitHubSponsorAuthenticationException implements Exception {
  const GitHubSponsorAuthenticationException(this.message);

  final String message;

  @override
  String toString() => message;
}
