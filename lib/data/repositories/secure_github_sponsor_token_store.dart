import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/repositories/github_sponsor_token_store.dart';

/// Stores the GitHub OAuth token in platform-encrypted storage.
class SecureGitHubSponsorTokenStore implements GitHubSponsorTokenStore {
  const SecureGitHubSponsorTokenStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const String _key = 'github_sponsor_oauth_token_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    final String? token = await _storage.read(key: _key);
    if (token == null || token.trim().isEmpty) {
      return null;
    }
    return token;
  }

  @override
  Future<void> write(String accessToken) async {
    await _storage.write(key: _key, value: accessToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}
