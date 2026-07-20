/// Identity and sponsorship result returned by GitHub GraphQL.
class GitHubSponsorVerification {
  const GitHubSponsorVerification({
    required this.login,
    required this.hasActiveMonthlySponsorship,
  });

  final String login;
  final bool hasActiveMonthlySponsorship;
}
