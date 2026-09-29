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
    this.connected = false,
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

  /// Whether a GitHub authorization is stored on this device, whatever the
  /// last check said. Only then is there anything to disconnect.
  final bool connected;

  bool get hasActiveMonthlySponsorship => access == GitHubSponsorAccess.active;

  GitHubSponsorStatus copyWith({
    GitHubSponsorAccess? access,
    String? login,
    String? message,
    bool? connected,
  }) {
    return GitHubSponsorStatus(
      access: access ?? this.access,
      login: login ?? this.login,
      message: message ?? this.message,
      connected: connected ?? this.connected,
    );
  }
}
