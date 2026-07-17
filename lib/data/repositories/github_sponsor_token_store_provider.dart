import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/github_sponsor_token_store.dart';
import 'secure_github_sponsor_token_store.dart';

final githubSponsorTokenStoreProvider =
    Provider<GitHubSponsorTokenStore>((ref) {
  return const SecureGitHubSponsorTokenStore();
});
