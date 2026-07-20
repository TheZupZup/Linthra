import 'package:flutter_riverpod/flutter_riverpod.dart';

class GitHubSponsorConfig {
  const GitHubSponsorConfig({
    required this.oauthClientId,
    required this.sponsorableLogin,
  });

  final String oauthClientId;
  final String sponsorableLogin;

  bool get isConfigured => oauthClientId.trim().isNotEmpty;
}

final githubSponsorConfigProvider = Provider<GitHubSponsorConfig>((ref) {
  return const GitHubSponsorConfig(
    oauthClientId: String.fromEnvironment('LINTHRA_GITHUB_OAUTH_CLIENT_ID'),
    sponsorableLogin: String.fromEnvironment(
      'LINTHRA_GITHUB_SPONSOR_LOGIN',
      defaultValue: 'TheZupZup',
    ),
  );
});
