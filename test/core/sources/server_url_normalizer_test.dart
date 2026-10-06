import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/server_url_normalizer.dart';

void main() {
  group('ServerUrlNormalizer.parse ports', () {
    test('keeps any port a server can listen on', () {
      expect(ServerUrlNormalizer.parse('https://h.example.com:1').port, 1);
      expect(
          ServerUrlNormalizer.parse('https://h.example.com:65535').port, 65535);
      expect(ServerUrlNormalizer.parse('h.example.com:8096').toBase(),
          'https://h.example.com:8096');
    });

    test('leaves an omitted or default port out', () {
      expect(ServerUrlNormalizer.parse('https://h.example.com').port, isNull);
      expect(ServerUrlNormalizer.parse('https://h.example.com:').port, isNull);
    });

    test('rejects a port no server can listen on', () {
      for (final String input in <String>[
        'https://h.example.com:0',
        'https://h.example.com:65536',
        // 8096 with a slipped key.
        'https://h.example.com:80966',
        'http://[::1]:70000/jellyfin',
        // Too long for an int: Uri parses it, then throws on reading it.
        'https://h.example.com:99999999999999999999',
      ]) {
        expect(
          () => ServerUrlNormalizer.parse(input),
          throwsA(isA<ServerUrlParseFailure>().having(
              (ServerUrlParseFailure f) => f.kind,
              'kind',
              ServerUrlErrorKind.invalidPort)),
          reason: input,
        );
      }
    });
  });
}
