import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linthra/core/models/github_device_authorization.dart';
import 'package:linthra/data/services/http_github_sponsor_client.dart';
import 'package:linthra/features/support/github_sponsor_config.dart';

void main() {
  const GitHubSponsorConfig config = GitHubSponsorConfig(
    oauthClientId: 'client-id',
    sponsorableLogin: 'TheZupZup',
  );

  test('requests and parses a GitHub device authorization', () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      expect(request.url.path, '/login/device/code');
      expect(request.bodyFields['client_id'], 'client-id');
      expect(request.bodyFields['scope'], 'read:user');
      return http.Response(
        jsonEncode(<String, Object>{
          'device_code': 'device-code',
          'user_code': 'ABCD-EFGH',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 5,
        }),
        200,
      );
    });
    final HttpGitHubSponsorClient client = HttpGitHubSponsorClient(
      httpClient: httpClient,
      config: config,
    );

    final GitHubDeviceAuthorization authorization =
        await client.requestDeviceAuthorization();

    expect(authorization.deviceCode, 'device-code');
    expect(authorization.userCode, 'ABCD-EFGH');
    expect(
      authorization.verificationUri,
      Uri.parse('https://github.com/login/device'),
    );
    expect(authorization.pollInterval, const Duration(seconds: 5));
  });

  test('polls until GitHub returns an access token', () async {
    int requests = 0;
    final MockClient httpClient = MockClient((http.Request request) async {
      requests += 1;
      if (requests == 1) {
        return http.Response(
          jsonEncode(<String, String>{'error': 'authorization_pending'}),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, String>{'access_token': 'token'}),
        200,
      );
    });
    final HttpGitHubSponsorClient client = HttpGitHubSponsorClient(
      httpClient: httpClient,
      config: config,
    );
    final GitHubDeviceAuthorization authorization = GitHubDeviceAuthorization(
      deviceCode: 'device-code',
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://github.com/login/device'),
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      pollInterval: Duration.zero,
    );

    expect(await client.pollForAccessToken(authorization), 'token');
    expect(requests, 2);
  });

  test('active monthly sponsorship unlocks access', () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      expect(
        (body['variables'] as Map<String, dynamic>)['login'],
        'TheZupZup',
      );
      return http.Response(
        jsonEncode(<String, Object>{
          'data': <String, Object>{
            'viewer': <String, String>{'login': 'music-fan'},
            'user': <String, Object>{
              'sponsorshipForViewerAsSponsor': <String, bool>{
                'isOneTimePayment': false,
              },
            },
          },
        }),
        200,
      );
    });
    final HttpGitHubSponsorClient client = HttpGitHubSponsorClient(
      httpClient: httpClient,
      config: config,
    );

    final verification = await client.verifySponsorship('token');

    expect(verification.login, 'music-fan');
    expect(verification.hasActiveMonthlySponsorship, isTrue);
  });

  test('one-time sponsorship does not unlock monthly access', () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object>{
          'data': <String, Object>{
            'viewer': <String, String>{'login': 'music-fan'},
            'user': <String, Object>{
              'sponsorshipForViewerAsSponsor': <String, bool>{
                'isOneTimePayment': true,
              },
            },
          },
        }),
        200,
      );
    });
    final HttpGitHubSponsorClient client = HttpGitHubSponsorClient(
      httpClient: httpClient,
      config: config,
    );

    final verification = await client.verifySponsorship('token');

    expect(verification.hasActiveMonthlySponsorship, isFalse);
  });

  test('missing sponsorship remains locked', () async {
    final MockClient httpClient = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object>{
          'data': <String, Object>{
            'viewer': <String, String>{'login': 'music-fan'},
            'user': <String, Object?>{
              'sponsorshipForViewerAsSponsor': null,
            },
          },
        }),
        200,
      );
    });
    final HttpGitHubSponsorClient client = HttpGitHubSponsorClient(
      httpClient: httpClient,
      config: config,
    );

    final verification = await client.verifySponsorship('token');

    expect(verification.hasActiveMonthlySponsorship, isFalse);
  });
}
