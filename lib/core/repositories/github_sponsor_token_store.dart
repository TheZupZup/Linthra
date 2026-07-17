/// Encrypted persistence for the GitHub OAuth access token.
abstract interface class GitHubSponsorTokenStore {
  Future<String?> read();

  Future<void> write(String accessToken);

  Future<void> clear();
}
