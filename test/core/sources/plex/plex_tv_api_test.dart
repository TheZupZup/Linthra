import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';

const String _accessToken = 'super-secret-server-token';

void main() {
  group('PlexPin', () {
    test('parses id, code, and expiry', () {
      final PlexPin? pin = PlexPin.fromJson(const <String, dynamic>{
        'id': 123456,
        'code': 'abcDEF123',
        'expiresIn': 1800,
        'authToken': null,
      });

      expect(pin, isNotNull);
      expect(pin!.id, 123456);
      expect(pin.code, 'abcDEF123');
      expect(pin.expiresInSeconds, 1800);
    });

    test('tolerates string-typed numbers', () {
      final PlexPin? pin = PlexPin.fromJson(const <String, dynamic>{
        'id': '42',
        'code': 'c0de',
        'expiresIn': '900',
      });

      expect(pin!.id, 42);
      expect(pin.expiresInSeconds, 900);
    });

    test('returns null without an id or code', () {
      expect(PlexPin.fromJson(const <String, dynamic>{'code': 'x'}), isNull);
      expect(PlexPin.fromJson(const <String, dynamic>{'id': 1}), isNull);
      expect(
        PlexPin.fromJson(const <String, dynamic>{'id': 1, 'code': ''}),
        isNull,
      );
    });

    test('toString omits the code', () {
      const PlexPin pin = PlexPin(id: 9, code: 'should-not-print');
      expect(pin.toString(), isNot(contains('should-not-print')));
      expect(pin.toString(), contains('9'));
    });
  });

  group('PlexResource', () {
    test('parses a server resource with its connections', () {
      final PlexResource? resource =
          PlexResource.fromJson(const <String, dynamic>{
        'name': 'Office Server',
        'clientIdentifier': 'machine-abc',
        'provides': 'server',
        'accessToken': _accessToken,
        'owned': true,
        'productVersion': '1.41.0.8994',
        'connections': <Object?>[
          <String, dynamic>{
            'protocol': 'https',
            'address': '192.168.1.10',
            'port': 32400,
            'uri': 'https://192-168-1-10.abc.plex.direct:32400',
            'local': true,
            'relay': false,
          },
          <String, dynamic>{
            'protocol': 'https',
            'uri': 'https://relay.plex.direct:8443',
            'local': false,
            'relay': true,
          },
        ],
      });

      expect(resource, isNotNull);
      expect(resource!.name, 'Office Server');
      expect(resource.clientIdentifier, 'machine-abc');
      expect(resource.providesServer, isTrue);
      expect(resource.accessToken, _accessToken);
      expect(resource.owned, isTrue);
      expect(resource.productVersion, '1.41.0.8994');
      expect(resource.connections, hasLength(2));
      expect(resource.connections.first.uri,
          'https://192-168-1-10.abc.plex.direct:32400');
      expect(resource.connections.first.local, isTrue);
      expect(resource.connections.first.relay, isFalse);
      expect(resource.connections.last.relay, isTrue);
    });

    test('providesServer matches inside a comma-separated list only', () {
      PlexResource resource({required String provides}) =>
          PlexResource(name: 'X', clientIdentifier: 'id', provides: provides);

      expect(resource(provides: 'server').providesServer, isTrue);
      expect(resource(provides: 'client,server').providesServer, isTrue);
      expect(resource(provides: 'client, server').providesServer, isTrue);
      expect(resource(provides: 'client,player').providesServer, isFalse);
      // A *player* that merely contains the word must not match.
      expect(resource(provides: 'serverless').providesServer, isFalse);
      expect(resource(provides: '').providesServer, isFalse);
    });

    test('tolerates 0/1 and string booleans from older envelopes', () {
      final PlexResource? resource =
          PlexResource.fromJson(const <String, dynamic>{
        'name': 'S',
        'clientIdentifier': 'id',
        'provides': 'server',
        'owned': '0',
        'connections': <Object?>[
          <String, dynamic>{
            'uri': 'http://10.0.0.2:32400',
            'local': 1,
            'relay': '0'
          },
        ],
      });

      expect(resource!.owned, isFalse);
      expect(resource.connections.single.local, isTrue);
      expect(resource.connections.single.relay, isFalse);
    });

    test('skips malformed connections and tolerates a missing token', () {
      final PlexResource? resource =
          PlexResource.fromJson(const <String, dynamic>{
        'name': 'S',
        'clientIdentifier': 'id',
        'provides': 'server',
        'connections': <Object?>[
          <String, dynamic>{'local': true}, // no uri — unusable
          'garbage',
          <String, dynamic>{'uri': 'http://10.0.0.2:32400'},
        ],
      });

      expect(resource!.accessToken, isNull);
      expect(resource.connections, hasLength(1));
      expect(resource.connections.single.uri, 'http://10.0.0.2:32400');
    });

    test('returns null without a clientIdentifier', () {
      expect(
        PlexResource.fromJson(const <String, dynamic>{'name': 'S'}),
        isNull,
      );
    });

    test('toString redacts the access token', () {
      const PlexResource resource = PlexResource(
        name: 'Office Server',
        clientIdentifier: 'machine-abc',
        provides: 'server',
        accessToken: _accessToken,
        connections: <PlexResourceConnection>[
          PlexResourceConnection(uri: 'https://x.plex.direct:32400'),
        ],
      );

      final String text = resource.toString();
      expect(text, isNot(contains(_accessToken)));
      expect(text, contains('<redacted>'));
      // Display-safe fields still print, so debugging stays useful.
      expect(text, contains('Office Server'));
      expect(text, contains('machine-abc'));
    });

    test('toString says null when there is no token to redact', () {
      const PlexResource resource =
          PlexResource(name: 'S', clientIdentifier: 'id');
      expect(resource.toString(), contains('accessToken: null'));
    });
  });

  group('PlexHomeUser', () {
    test('parses the owner and a managed profile', () {
      final PlexHomeUser? owner = PlexHomeUser.fromJson(const <String, dynamic>{
        'id': 12345,
        'uuid': 'uuid-owner',
        'title': 'Dad',
        'admin': true,
        'restricted': false,
        'protected': true,
      });
      expect(owner, isNotNull);
      expect(owner!.uuid, 'uuid-owner');
      expect(owner.id, 12345);
      expect(owner.title, 'Dad');
      expect(owner.admin, isTrue);
      expect(owner.restricted, isFalse);
      expect(owner.protected, isTrue);

      final PlexHomeUser? kid = PlexHomeUser.fromJson(const <String, dynamic>{
        'uuid': 'uuid-kid',
        'title': 'Kids',
        'admin': false,
        'restricted': true,
        'protected': false,
      });
      expect(kid!.admin, isFalse);
      expect(kid.restricted, isTrue);
      expect(kid.protected, isFalse);
    });

    test('falls back to username, then empty, for a missing title', () {
      expect(
        PlexHomeUser.fromJson(const <String, dynamic>{
          'uuid': 'u',
          'username': 'guest42',
        })!
            .title,
        'guest42',
      );
      expect(
        PlexHomeUser.fromJson(const <String, dynamic>{'uuid': 'u'})!.title,
        '',
      );
    });

    test('tolerates 0/1 and string booleans from older envelopes', () {
      final PlexHomeUser? user = PlexHomeUser.fromJson(const <String, dynamic>{
        'uuid': 'u',
        'id': '99',
        'admin': '1',
        'restricted': 0,
        'protected': 'true',
      });
      expect(user!.id, 99);
      expect(user.admin, isTrue);
      expect(user.restricted, isFalse);
      expect(user.protected, isTrue);
    });

    test('returns null without a uuid (nothing to switch into)', () {
      expect(
        PlexHomeUser.fromJson(const <String, dynamic>{'title': 'No uuid'}),
        isNull,
      );
      expect(
        PlexHomeUser.fromJson(const <String, dynamic>{'uuid': ''}),
        isNull,
      );
    });
  });
}
