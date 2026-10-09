import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/local_network/local_network_address.dart';

bool _local(String address) => isLocalNetworkAddress(InternetAddress(address));

void main() {
  group('isLocalNetworkAddress follows Android 17\'s local network ranges', () {
    test('private, CGNAT, link-local, multicast and broadcast are local', () {
      for (final String address in <String>[
        '10.0.0.1',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.50',
        '169.254.10.10',
        '100.64.0.1',
        '100.127.255.254',
        '224.0.0.251', // mDNS
        '239.255.255.250', // SSDP
        '255.255.255.255',
        'fd12:3456:789a::1', // unique local
        'fc00::1',
        'fe80::1', // link-local
        'ff02::fb', // mDNS multicast
        '::ffff:192.168.1.50', // IPv4-mapped
      ]) {
        expect(_local(address), isTrue, reason: address);
      }
    });

    test('internet and loopback addresses are not', () {
      for (final String address in <String>[
        '8.8.8.8',
        '1.1.1.1',
        '172.15.255.255', // just below 172.16/12
        '172.32.0.1', // just above it
        '100.63.255.255', // just below CGNAT
        '100.128.0.1', // just above it
        '192.169.0.1',
        '127.0.0.1',
        '::1',
        '2001:4860:4860::8888',
        '::ffff:8.8.8.8',
      ]) {
        expect(_local(address), isFalse, reason: address);
      }
    });
  });

  group('classifyHost', () {
    Future<List<InternetAddress>> never(String host) =>
        throw StateError('no lookup expected for $host');

    test('reads an IP literal without a lookup', () async {
      expect(
          await classifyHost('192.168.1.5', lookup: never), HostLocality.local);
      expect(
          await classifyHost('[fe80::1]', lookup: never), HostLocality.local);
      expect(await classifyHost('203.0.113.9', lookup: never),
          HostLocality.internet);
    });

    test('a .local name is local without resolving it', () async {
      expect(
          await classifyHost('nas.local', lookup: never), HostLocality.local);
      expect(
          await classifyHost('NAS.Local.', lookup: never), HostLocality.local);
    });

    test('localhost is not the local network', () async {
      expect(await classifyHost('localhost', lookup: never),
          HostLocality.internet);
    });

    test('a name that resolves to a LAN address is local (split DNS)',
        () async {
      // music.example.com answering 192.168.x.x at home is common for
      // self-hosted servers, and is exactly what Android 17 blocks.
      expect(
        await classifyHost('music.example.com',
            lookup: (_) async => <InternetAddress>[
                  InternetAddress('192.168.1.20'),
                ]),
        HostLocality.local,
      );
      expect(
        await classifyHost('music.example.com',
            lookup: (_) async => <InternetAddress>[
                  InternetAddress('2001:db8::5'),
                  InternetAddress('10.0.0.5'),
                ]),
        HostLocality.local,
      );
    });

    test('a name that resolves only to the internet is not', () async {
      expect(
        await classifyHost('demo.navidrome.org',
            lookup: (_) async => <InternetAddress>[
                  InternetAddress('203.0.113.7'),
                ]),
        HostLocality.internet,
      );
    });

    test('a failed, empty or hung lookup says nothing', () async {
      expect(
          await classifyHost('typo.invalid',
              lookup: (_) async => throw const SocketException('no host')),
          HostLocality.unknown);
      expect(
          await classifyHost('empty.example',
              lookup: (_) async => <InternetAddress>[]),
          HostLocality.unknown);
      expect(
          await classifyHost('slow.example',
              lookup: (_) => Completer<List<InternetAddress>>().future,
              timeout: const Duration(milliseconds: 10)),
          HostLocality.unknown);
      expect(await classifyHost('', lookup: never), HostLocality.unknown);
    });
  });
}
