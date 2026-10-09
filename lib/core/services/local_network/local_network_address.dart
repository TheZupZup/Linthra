import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Whether a server host sits on the local network as Android 17 defines it
/// for ACCESS_LOCAL_NETWORK.
enum HostLocality {
  /// Resolves to a local network address: the permission applies.
  local,

  /// Resolves only to internet (or loopback) addresses: the permission has
  /// nothing to do with it.
  internet,

  /// The name didn't resolve (offline, a typo, DNS down). Nothing can be said,
  /// so nothing is blocked or asked on its account.
  unknown,
}

/// Looks a host name up. Swappable so tests never touch real DNS.
typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Whether [address] is a local network address under Android's definition:
/// the RFC 1918 private ranges, carrier-grade NAT space, link-local, multicast
/// and broadcast, plus IPv6 unique-local and link-local.
///
/// Loopback is deliberately not local: it never leaves the device, and Android
/// keeps it out of the permission's scope.
bool isLocalNetworkAddress(InternetAddress address) {
  final Uint8List bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isLocalIPv4(bytes);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    // An IPv4-mapped address (::ffff:a.b.c.d) is that IPv4 address.
    if (_isIPv4Mapped(bytes)) return _isLocalIPv4(bytes.sublist(12));
    final int first = bytes[0];
    if ((first & 0xfe) == 0xfc) return true; // unique local
    if (first == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // link-local
    if (first == 0xff) return true; // multicast
  }
  return false;
}

/// Lists the names of the device's network interfaces. Swappable so tests
/// never depend on the machine they run on.
typedef InterfaceNameLister = Future<List<String>> Function();

Future<List<String>> _systemInterfaceNames() async => <String>[
      for (final NetworkInterface interface
          in await NetworkInterface.list(includeLinkLocal: true))
        interface.name,
    ];

/// Whether [name] is a VPN tunnel: Android's VpnService (`tun`), WireGuard's
/// kernel driver (`wg`), the platform IKEv2 VPN (`ipsec`) and the legacy
/// PPTP/L2TP ones (`ppp`). Android's 464XLAT interface (`v4-wlan0`) is not a
/// VPN and doesn't match.
bool isVpnInterfaceName(String name) {
  final String lower = name.toLowerCase();
  return lower.startsWith('tun') ||
      lower.startsWith('wg') ||
      lower.startsWith('ipsec') ||
      lower.startsWith('ppp');
}

/// Whether a VPN tunnel is up on the device. Android's local network
/// permission covers Wi-Fi and Ethernet, not a VPN, so behind one a private
/// address may not be on the local network at all. Never throws: anything
/// that can't be read counts as no VPN.
Future<bool> vpnInterfaceUp({
  InterfaceNameLister list = _systemInterfaceNames,
  Duration timeout = const Duration(seconds: 1),
}) async {
  try {
    final List<String> names = await list().timeout(timeout);
    return names.any(isVpnInterfaceName);
  } catch (_) {
    return false;
  }
}

bool _isLocalIPv4(List<int> b) {
  final int a = b[0];
  if (a == 10) return true;
  if (a == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (a == 192 && b[1] == 168) return true;
  if (a == 169 && b[1] == 254) return true;
  if (a == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT
  if (a >= 224 && a <= 239) return true; // multicast
  return a == 255 && b[1] == 255 && b[2] == 255 && b[3] == 255;
}

bool _isIPv4Mapped(Uint8List b) {
  for (int i = 0; i < 10; i++) {
    if (b[i] != 0) return false;
  }
  return b[10] == 0xff && b[11] == 0xff;
}

/// Classifies [host] (a URL's host part), resolving it when it is a name.
///
/// DNS itself is outside the permission (Android exempts the device's own
/// resolver), so the lookup is safe to make before anything is granted. A
/// `.local` name is local by definition: resolving it is multicast DNS, which
/// is local traffic itself. Never throws.
Future<HostLocality> classifyHost(
  String host, {
  HostLookup lookup = InternetAddress.lookup,
  Duration timeout = const Duration(seconds: 3),
}) async {
  String name = host.trim().toLowerCase();
  if (name.startsWith('[') && name.endsWith(']')) {
    name = name.substring(1, name.length - 1);
  }
  if (name.isEmpty) return HostLocality.unknown;
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);

  final InternetAddress? literal = InternetAddress.tryParse(name);
  if (literal != null) {
    return isLocalNetworkAddress(literal)
        ? HostLocality.local
        : HostLocality.internet;
  }
  if (name == 'localhost') return HostLocality.internet;
  if (name.endsWith('.local')) return HostLocality.local;

  try {
    final List<InternetAddress> addresses = await lookup(name).timeout(timeout);
    if (addresses.isEmpty) return HostLocality.unknown;
    return addresses.any(isLocalNetworkAddress)
        ? HostLocality.local
        : HostLocality.internet;
  } catch (_) {
    return HostLocality.unknown;
  }
}
