/// Result of checking the signed-in GitHub account's sponsorship.
enum GitHubSponsorAccess {
  unavailable,
  signedOut,
  checking,
  inactive,
  active,
  error,
}

class GitHubSponsorStatus {
  const GitHubSponsorStatus({
    required this.access,
    this.login,
    this.message,
  });

  static const GitHubSponsorStatus unavailable = GitHubSponsorStatus(
    access: GitHubSponsorAccess.unavailable,
  );

  static const GitHubSponsorStatus signedOut = GitHubSponsorStatus(
    access: GitHubSponsorAccess.signedOut,
  );

  static const GitHubSponsorStatus checking = GitHubSponsorStatus(
    access: GitHubSponsorAccess.checking,
  );

  final GitHubSponsorAccess access;
  final String? login;
  final String? message;

  bool get hasActiveMonthlySponsorship =>
      access == GitHubSponsorAccess.active;

  GitHubSponsorStatus copyWith({
    GitHubSponsorAccess? access,
    String? login,
    String? message,
  }) {
    return GitHubSponsorStatus(
      access: access ?? this.access,
      login: login ?? this.login,
      message: message ?? this.message,
    );
  }
}
