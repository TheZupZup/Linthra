import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Explicit test-only override for GitHub Sponsor entitlement.
///
/// Public release workflows never pass this define. F-Droid does not consult it.
enum GitHubSponsorSimulation {
  real,
  locked,
  unlocked,
}

GitHubSponsorSimulation githubSponsorSimulationFor(String value) {
  return switch (value.trim().toLowerCase()) {
    'locked' => GitHubSponsorSimulation.locked,
    'unlocked' => GitHubSponsorSimulation.unlocked,
    _ => GitHubSponsorSimulation.real,
  };
}

final githubSponsorSimulationProvider = Provider<GitHubSponsorSimulation>((ref) {
  return githubSponsorSimulationFor(
    const String.fromEnvironment('LINTHRA_GITHUB_SPONSOR_SIMULATION'),
  );
});
