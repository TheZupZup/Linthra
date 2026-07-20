import '../../core/repositories/github_sponsor_token_store.dart';

class InMemoryGitHubSponsorTokenStore implements GitHubSponsorTokenStore {
  InMemoryGitHubSponsorTokenStore([this._token]);

  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String accessToken) async {
    _token = accessToken;
  }

  @override
  Future<void> clear() async {
    _token = null;
  }
}
