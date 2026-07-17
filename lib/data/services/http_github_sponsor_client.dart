import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/models/github_device_authorization.dart';
import '../../core/models/github_sponsor_verification.dart';
import '../../core/services/github_sponsor_client.dart';
import '../../features/support/github_sponsor_config.dart';

/// GitHub OAuth device-flow and GraphQL client used by the GitHub Release APK.
class HttpGitHubSponsorClient implements GitHubSponsorClient {
  HttpGitHubSponsorClient({
    required http.Client httpClient,
    required GitHubSponsorConfig config,
  })  : _httpClient = httpClient,
        _config = config;

  static final Uri _deviceCodeUri =
      Uri.parse('https://github.com/login/device/code');
  static final Uri _accessTokenUri =
      Uri.parse('https://github.com/login/oauth/access_token');
  static final Uri _graphQlUri = Uri.parse('https://api.github.com/graphql');

  final http.Client _httpClient;
  final GitHubSponsorConfig _config;

  @override
  bool get isConfigured => _config.isConfigured;

  @override
  Future<GitHubDeviceAuthorization> requestDeviceAuthorization() async {
    _requireConfiguration();
    final http.Response response = await _httpClient.post(
      _deviceCodeUri,
      headers: const <String, String>{
        'Accept': 'application/json',
      },
      body: <String, String>{
        'client_id': _config.oauthClientId,
        'scope': 'read:user',
      },
    );
    final Map<String, dynamic> payload = _decodeObject(response);
    _throwForOAuthError(payload);

    final String deviceCode = _requiredString(payload, 'device_code');
    final String userCode = _requiredString(payload, 'user_code');
    final String verificationUri =
        _requiredString(payload, 'verification_uri');
    final int expiresIn = _requiredInt(payload, 'expires_in');
    final int interval = _requiredInt(payload, 'interval');

    return GitHubDeviceAuthorization(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: Uri.parse(verificationUri),
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      pollInterval: Duration(seconds: interval),
    );
  }

  @override
  Future<String> pollForAccessToken(
    GitHubDeviceAuthorization authorization,
  ) async {
    _requireConfiguration();
    Duration interval = authorization.pollInterval;

    while (!authorization.isExpired) {
      await Future<void>.delayed(interval);
      final http.Response response = await _httpClient.post(
        _accessTokenUri,
        headers: const <String, String>{
          'Accept': 'application/json',
        },
        body: <String, String>{
          'client_id': _config.oauthClientId,
          'device_code': authorization.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final Map<String, dynamic> payload = _decodeObject(response);
      final String? accessToken = payload['access_token'] as String?;
      if (accessToken != null && accessToken.isNotEmpty) {
        return accessToken;
      }

      switch (payload['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'expired_token':
          throw const GitHubSponsorAuthenticationException(
            'The GitHub sign-in code expired. Start again.',
          );
        case 'access_denied':
          throw const GitHubSponsorAuthenticationException(
            'GitHub sign-in was cancelled.',
          );
        default:
          _throwForOAuthError(payload);
          throw const GitHubSponsorAuthenticationException(
            'GitHub did not return an access token.',
          );
      }
    }

    throw const GitHubSponsorAuthenticationException(
      'The GitHub sign-in code expired. Start again.',
    );
  }

  @override
  Future<GitHubSponsorVerification> verifySponsorship(
    String accessToken,
  ) async {
    _requireConfiguration();
    final http.Response response = await _httpClient.post(
      _graphQlUri,
      headers: <String, String>{
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer $accessToken',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, Object>{
        'query': r'''
          query VerifyLinthraSponsor($login: String!) {
            viewer {
              login
            }
            user(login: $login) {
              sponsorshipForViewerAsSponsor(activeOnly: true) {
                isOneTimePayment
              }
            }
          }
        ''',
        'variables': <String, String>{
          'login': _config.sponsorableLogin,
        },
      }),
    );

    if (response.statusCode == 401) {
      throw const GitHubSponsorAuthenticationException(
        'The saved GitHub authorization is no longer valid.',
      );
    }
    final Map<String, dynamic> payload = _decodeObject(response);
    final Object? errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw const GitHubSponsorAuthenticationException(
        'GitHub could not verify the sponsorship.',
      );
    }

    final Map<String, dynamic> data = _requiredMap(payload, 'data');
    final Map<String, dynamic> viewer = _requiredMap(data, 'viewer');
    final String login = _requiredString(viewer, 'login');
    final Object? sponsorableValue = data['user'];
    if (sponsorableValue is! Map<String, dynamic>) {
      throw GitHubSponsorAuthenticationException(
        'The GitHub sponsor account ${_config.sponsorableLogin} was not found.',
      );
    }

    final Object? sponsorship =
        sponsorableValue['sponsorshipForViewerAsSponsor'];
    final bool hasActiveMonthlySponsorship =
        sponsorship is Map<String, dynamic> &&
            sponsorship['isOneTimePayment'] == false;

    return GitHubSponsorVerification(
      login: login,
      hasActiveMonthlySponsorship: hasActiveMonthlySponsorship,
    );
  }

  void _requireConfiguration() {
    if (!isConfigured) {
      throw const GitHubSponsorAuthenticationException(
        'GitHub sponsor verification is not configured in this build.',
      );
    }
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GitHubSponsorAuthenticationException(
        'GitHub returned HTTP ${response.statusCode}.',
      );
    }
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Fall through to the consistent error below.
    }
    throw const GitHubSponsorAuthenticationException(
      'GitHub returned an invalid response.',
    );
  }

  void _throwForOAuthError(Map<String, dynamic> payload) {
    final String? error = payload['error'] as String?;
    if (error == null || error.isEmpty) {
      return;
    }
    final String? description = payload['error_description'] as String?;
    throw GitHubSponsorAuthenticationException(
      description?.trim().isNotEmpty == true
          ? description!
          : 'GitHub authorization failed: $error.',
    );
  }

  String _requiredString(Map<String, dynamic> payload, String key) {
    final Object? value = payload[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw GitHubSponsorAuthenticationException(
      'GitHub response is missing $key.',
    );
  }

  int _requiredInt(Map<String, dynamic> payload, String key) {
    final Object? value = payload[key];
    if (value is int) {
      return value;
    }
    throw GitHubSponsorAuthenticationException(
      'GitHub response is missing $key.',
    );
  }

  Map<String, dynamic> _requiredMap(
    Map<String, dynamic> payload,
    String key,
  ) {
    final Object? value = payload[key];
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw GitHubSponsorAuthenticationException(
      'GitHub response is missing $key.',
    );
  }
}
