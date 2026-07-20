import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/services/github_sponsor_client.dart';
import '../../features/support/github_sponsor_config.dart';
import 'http_github_sponsor_client.dart';

final githubSponsorHttpClientProvider = Provider<http.Client>((ref) {
  final http.Client client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final githubSponsorClientProvider = Provider<GitHubSponsorClient>((ref) {
  return HttpGitHubSponsorClient(
    httpClient: ref.watch(githubSponsorHttpClientProvider),
    config: ref.watch(githubSponsorConfigProvider),
  );
});
