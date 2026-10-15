import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_server_url.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_server_url.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_pin_auth.dart';
import 'package:linthra/core/sources/plex/plex_server_url.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';
import 'package:linthra/core/sources/server_url_normalizer.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_server_url.dart';

import 'plex/fake_plex_client.dart';
import 'plex/fake_plex_tv_client.dart';

// A server address pasted with credentials in it (`user:password@host`, the
// form a browser bookmark or a password manager can hand back) must lose them
// in normalization. The normalized base URL is what every provider persists in
// its session, builds every request and artwork URL from, and reduces into
// diagnostics, so a password that survived here would be at rest in the
// session record and on the wire in every request line. These tests pin that
// every provider's normalizer, and the Plex sign-in path that normalizes the
// addresses plex.tv advertises, rebuild the base from scheme, host, port and
// path only.

/// A password distinctive enough that any surviving fragment is found.
const String _password = 'hunter2';

/// Every fragment of [_password] or the user name that must not survive.
const List<String> _credentialFragments = <String>[
  'alice',
  _password,
  '@',
];

/// The four provider normalizers, as plain functions, with the exception type
/// each throws for an unusable address.
final List<
    ({
      String name,
      String Function(String) normalize,
      String? Function(String) tryNormalize,
      Matcher invalid,
    })> _providers = <({
  String name,
  String Function(String) normalize,
  String? Function(String) tryNormalize,
  Matcher invalid,
})>[
  (
    name: 'Jellyfin',
    normalize: JellyfinServerUrl.normalize,
    tryNormalize: JellyfinServerUrl.tryNormalize,
    invalid: isA<JellyfinException>().having(
        (JellyfinException e) => e.kind, 'kind', JellyfinErrorKind.invalidUrl),
  ),
  (
    name: 'Plex',
    normalize: PlexServerUrl.normalize,
    tryNormalize: PlexServerUrl.tryNormalize,
    invalid: isA<PlexException>()
        .having((PlexException e) => e.kind, 'kind', PlexErrorKind.invalidUrl),
  ),
  (
    name: 'Audiobookshelf',
    normalize: AudiobookshelfServerUrl.normalize,
    tryNormalize: AudiobookshelfServerUrl.tryNormalize,
    invalid: isA<AudiobookshelfException>().having(
        (AudiobookshelfException e) => e.kind,
        'kind',
        AudiobookshelfErrorKind.invalidUrl),
  ),
  (
    name: 'Subsonic',
    normalize: SubsonicServerUrl.normalize,
    tryNormalize: SubsonicServerUrl.tryNormalize,
    invalid: isA<SubsonicException>().having(
        (SubsonicException e) => e.kind, 'kind', SubsonicErrorKind.invalidUrl),
  ),
];

void _expectNoCredentials(String value, {required String reason}) {
  for (final String fragment in _credentialFragments) {
    expect(value, isNot(contains(fragment)), reason: '$reason: $value');
  }
}

/// A [FakePlexClient] that records every address it is asked to probe, not
/// only the last one.
class _RecordingPlexClient extends FakePlexClient {
  _RecordingPlexClient()
      : super(
          identity: const PlexServerIdentity(machineIdentifier: 'machine-abc'),
        );

  final List<String> probedBaseUrls = <String>[];

  @override
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  }) {
    probedBaseUrls.add(baseUrl);
    return super.fetchIdentity(baseUrl: baseUrl, token: token);
  }
}

void main() {
  group('ServerUrlNormalizer.parse drops userinfo', () {
    test('a full URL keeps scheme, host, port and path, and nothing else', () {
      final ParsedServerUrl parsed = ServerUrlNormalizer.parse(
        'https://alice:$_password@music.example.com:8096/jf?api_key=X#f',
      );

      expect(parsed.host, 'music.example.com');
      expect(parsed.port, 8096);
      expect(parsed.path, '/jf');
      expect(parsed.toBase(), 'https://music.example.com:8096/jf');
    });

    test('an IPv6 literal behind userinfo keeps only its brackets', () {
      expect(
        ServerUrlNormalizer.parse('http://alice:$_password@[::1]:8096/jf')
            .toBase(),
        'http://[::1]:8096/jf',
      );
    });
  });

  for (final provider in _providers) {
    group('${provider.name} server URL normalization drops userinfo', () {
      test('user:password@ on a full URL, with query and fragment', () {
        final String base = provider.normalize(
          'https://alice:$_password@music.example.com/jf?api_key=X#f',
        );

        expect(base, 'https://music.example.com/jf');
        _expectNoCredentials(base, reason: provider.name);
        expect(base, isNot(contains('api_key')));
      });

      test('user:password@ on a scheme-less address with a port', () {
        final String base =
            provider.normalize('alice:$_password@music.example.com:8096');

        expect(base, 'https://music.example.com:8096');
        _expectNoCredentials(base, reason: provider.name);
      });

      test('a user name alone, or a password alone, is dropped too', () {
        expect(
          provider.normalize('https://alice@music.example.com'),
          'https://music.example.com',
        );
        expect(
          provider.normalize('https://:$_password@music.example.com'),
          'https://music.example.com',
        );
      });

      test('a percent-encoded @ in the password does not survive', () {
        final String base =
            provider.normalize('https://alice:p%40ss@music.example.com');

        expect(base, 'https://music.example.com');
        expect(base, isNot(contains('p%40ss')));
        expect(base, isNot(contains('%40')));
      });

      test('a raw @ in the password is refused without quoting any of it', () {
        // The URL parser cannot split `alice:p@ss@host` into userinfo and host,
        // so the address is refused. What must not happen is a host of
        // `ss@host` or an error message that echoes the input back.
        for (final String input in <String>[
          'https://alice:p@ss@music.example.com',
          'https://alice:p@ss@music.example.com:8096/jf',
          'alice:p@ss@music.example.com:8096',
        ]) {
          Object? thrown;
          try {
            provider.normalize(input);
          } catch (error) {
            thrown = error;
          }

          expect(thrown, provider.invalid, reason: input);
          final String message = thrown.toString();
          for (final String fragment in <String>[
            'alice',
            'p@ss',
            'ss@',
            'music.example.com',
          ]) {
            expect(message, isNot(contains(fragment)), reason: input);
          }
          expect(provider.tryNormalize(input), isNull, reason: input);
        }
      });

      test('userinfo with no host is refused without quoting it', () {
        Object? thrown;
        try {
          provider.normalize('https://alice:$_password@');
        } catch (error) {
          thrown = error;
        }

        expect(thrown, provider.invalid);
        _expectNoCredentials(thrown.toString(), reason: provider.name);
      });
    });
  }

  group('Subsonic keeps its /rest stripping when userinfo is dropped', () {
    test('a pasted API URL with credentials in both places reduces to root',
        () {
      final String base = SubsonicServerUrl.normalize(
        'https://alice:$_password@music.example.com:4533/rest'
        '?u=alice&t=tok&s=salt',
      );

      expect(base, 'https://music.example.com:4533');
      _expectNoCredentials(base, reason: 'Subsonic');
      expect(base, isNot(contains('tok')));
      expect(base, isNot(contains('salt')));
    });
  });

  group('PlexPinAuth.connectToServer normalizes advertised addresses', () {
    const PlexClientIdentity identity = PlexClientIdentity(
      clientIdentifier: 'install-uuid-1',
      product: 'Linthra',
      version: '0.1.5',
      platform: 'Android',
      device: 'Pixel',
    );

    PlexPinAuth auth(_RecordingPlexClient serverClient) => PlexPinAuth(
          tvClient: FakePlexTvClient(),
          serverClient: serverClient,
          identity: identity,
          wait: (_) async {},
        );

    test('userinfo in a plex.tv connection URI is neither probed nor saved',
        () async {
      final _RecordingPlexClient serverClient = _RecordingPlexClient();
      const PlexResource server = PlexResource(
        name: 'Office Server',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        accessToken: 'server-token',
        connections: <PlexResourceConnection>[
          PlexResourceConnection(
            uri: 'https://alice:$_password@10-0-0-5.abc.plex.direct:32400',
            local: true,
          ),
        ],
      );

      final PlexSession session = await auth(serverClient).connectToServer(
        server: server,
        accountToken: 'account-token',
      );

      expect(session.baseUrl, 'https://10-0-0-5.abc.plex.direct:32400');
      expect(serverClient.probedBaseUrls,
          <String>['https://10-0-0-5.abc.plex.direct:32400']);
      _expectNoCredentials(session.toString(), reason: 'PlexSession');
    });

    test('an address the parser cannot split is skipped, not half-used',
        () async {
      final _RecordingPlexClient serverClient = _RecordingPlexClient();
      const PlexResource server = PlexResource(
        name: 'Office Server',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        accessToken: 'server-token',
        connections: <PlexResourceConnection>[
          PlexResourceConnection(
            uri: 'https://alice:p@ss@10-0-0-5.abc.plex.direct:32400',
            local: true,
          ),
          PlexResourceConnection(
            uri: 'https://93-184-216-34.abc.plex.direct:32400',
          ),
        ],
      );

      final PlexSession session = await auth(serverClient).connectToServer(
        server: server,
        accountToken: 'account-token',
      );

      // The unsplittable address is never probed, so no request ever goes to
      // a host such as `ss@10-0-0-5…` carrying part of the password.
      expect(serverClient.probedBaseUrls,
          <String>['https://93-184-216-34.abc.plex.direct:32400']);
      expect(session.baseUrl, 'https://93-184-216-34.abc.plex.direct:32400');
    });
  });
}
