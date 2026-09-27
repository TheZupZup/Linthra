import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/cast_media.dart';
import 'cast_media_access.dart';
import 'cast_media_relay.dart';

/// A small HTTP server on the phone that re-serves the current cast item, so
/// the receiver never sees the server's credential-bearing URL.
///
/// The receiver is handed `http://<phone-lan-ip>:<port>/cast/<token>`. When it
/// asks for that, the proxy checks the token, fetches the real stream from the
/// music server itself (the URL the resolver minted, credential included, which
/// is the same request local playback already makes from this phone), and
/// streams the answer back. Someone watching the LAN sees a random token that
/// points at the phone and dies with the session, not the account credential.
///
/// What it holds to:
///  - **Only while casting.** Nothing listens until [start]; [stop] closes the
///    socket, drops every token and cuts transfers in flight. It also stops by
///    itself after [idleTimeout] with no requests and nothing in flight, as a
///    safety net for a session that ended without telling it.
///  - **One live item.** [publish] mints a fresh 256-bit token from
///    [Random.secure] per item and forgets every earlier one. A token also
///    expires after [tokenLifetime] even if the session is still up. Unknown
///    and expired tokens get the same bare 404.
///  - **Seeking works.** A `Range` request is forwarded upstream and the answer
///    relayed as is: `206 Partial Content`, `Content-Range`, `Accept-Ranges`,
///    `Content-Length`. Without that the receiver cannot scrub or buffer.
///  - **Nothing leaks back.** An upstream failure becomes an empty `502`, with
///    none of the server's body or headers. Only a fixed list of media headers
///    is copied. Nothing here logs.
///  - **LAN only.** It binds to the phone's private Wi-Fi/Ethernet address
///    rather than every interface, so it is not offered on mobile data or a VPN
///    tunnel.
///
/// It runs in the app's main isolate, the same process as the background audio
/// service, so it lives exactly as long as playback does.
class LocalCastMediaProxy implements CastMediaRelay {
  LocalCastMediaProxy({
    Future<InternetAddress> Function()? lanAddress,
    Future<HttpServer> Function(InternetAddress address)? bind,
    HttpClient Function()? httpClient,
    DateTime Function()? clock,
    this.idleTimeout = const Duration(minutes: 30),
    this.tokenLifetime = const Duration(hours: 6),
  })  : _lanAddress = lanAddress ?? findLanAddress,
        _bind = bind ?? _bindEphemeral,
        _httpClient = httpClient ?? HttpClient.new,
        _clock = clock ?? DateTime.now;

  /// The first path segment of every relayed URL.
  static const String pathPrefix = 'cast';

  /// Token size in bytes before encoding: 256 bits, 43 base64url characters.
  static const int tokenBytes = 32;

  /// How long the proxy waits with no request, nothing in flight and no
  /// [touch] before it shuts itself down.
  final Duration idleTimeout;

  /// How long one item's token stays valid, however long the session lasts.
  final Duration tokenLifetime;

  final Future<InternetAddress> Function() _lanAddress;
  final Future<HttpServer> Function(InternetAddress address) _bind;
  final HttpClient Function() _httpClient;
  final DateTime Function() _clock;

  static final Random _random = Random.secure();

  /// A `Range` header this proxy is willing to forward: byte ranges only, in
  /// the plain `bytes=a-b[, c-d]` form. Anything else is dropped, and the
  /// upstream answers with the whole body as usual.
  static final RegExp _rangePattern =
      RegExp(r'^bytes=\d*-\d*(\s*,\s*\d*-\d*)*$');

  /// Response headers copied from upstream. Anything not listed (cookies,
  /// server banners, auth challenges) stays on the phone.
  static const List<String> _relayedHeaders = <String>[
    HttpHeaders.contentRangeHeader,
    HttpHeaders.acceptRangesHeader,
    HttpHeaders.lastModifiedHeader,
    HttpHeaders.etagHeader,
  ];

  HttpServer? _server;
  HttpClient? _client;
  Uri? _base;
  Future<void>? _starting;
  Timer? _idleTimer;
  int _inFlight = 0;
  final Map<String, _PublishedItem> _items = <String, _PublishedItem>{};

  @override
  bool get isRunning => _server != null;

  /// The address and port the proxy is reachable on, or null when stopped.
  /// Exposed for tests; the token is never part of it.
  @visibleForTesting
  Uri? get baseUrl => _base;

  /// A fresh, URL-safe token from the platform's secure random source.
  @visibleForTesting
  static String newToken() {
    final List<int> bytes =
        List<int>.generate(tokenBytes, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  @override
  Future<void> start() {
    if (_server != null) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final InternetAddress address;
    final HttpServer server;
    try {
      address = await _lanAddress();
      server = await _bind(address);
    } catch (_) {
      // Which step failed, and why, is not the user's problem and may carry an
      // address: the message stays generic.
      throw const CastMediaRelayException(
        CastMediaRelayException.unavailableMessage,
      );
    }
    server
      ..autoCompress = false
      ..serverHeader = null
      ..idleTimeout = const Duration(seconds: 30);
    _server = server;
    _client = _httpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15);
    _base = Uri(scheme: 'http', host: address.address, port: server.port);
    server.listen(_handle, onError: (Object _) {}, cancelOnError: false);
    _armIdleTimer();
  }

  @override
  CastMedia publish(CastMedia media) {
    final Uri? base = _base;
    if (_server == null || base == null) {
      throw const CastMediaRelayException(
        CastMediaRelayException.unavailableMessage,
      );
    }
    // One live item: the receiver only ever needs the one it was just given.
    _items.clear();
    final String token = newToken();
    _items[token] = _PublishedItem(
      upstream: media.url,
      contentType: media.contentType,
      issuedAt: _clock(),
    );
    _armIdleTimer();
    return CastMedia(
      url: base.replace(pathSegments: <String>[pathPrefix, token]),
      contentType: media.contentType,
      title: media.title,
      artist: media.artist,
      album: media.album,
      duration: media.duration,
      artworkUrl: media.artworkUrl,
      access: CastMediaAccess.localRelay,
    );
  }

  @override
  void touch() => _armIdleTimer();

  @override
  Future<void> stop() async {
    // Let a start in progress settle first, so it cannot bring a server up
    // after this stop has returned.
    final Future<void>? starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // A failed start leaves nothing to stop.
      }
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    _items.clear();
    final HttpServer? server = _server;
    final HttpClient? client = _client;
    _server = null;
    _client = null;
    _base = null;
    client?.close(force: true);
    if (server != null) await server.close(force: true);
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_server == null || _inFlight > 0) return;
    _idleTimer = Timer(idleTimeout, () {
      if (_inFlight == 0) unawaited(stop());
    });
  }

  Future<void> _handle(HttpRequest request) async {
    _inFlight++;
    _idleTimer?.cancel();
    // A receiver that hangs up mid-stream fails this future; nothing to do.
    unawaited(request.response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _serve(request);
    } catch (_) {
      try {
        // Throws once headers are out, in which case the receiver just sees
        // the transfer end early.
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {
        // The connection is already gone.
      }
    } finally {
      _inFlight--;
      _armIdleTimer();
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse response = request.response;
    final String method = request.method;
    if (method != 'GET' && method != 'HEAD') {
      response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }

    final _PublishedItem? item = _lookup(request.uri);
    final HttpClient? client = _client;
    if (item == null || client == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final HttpClientRequest upstreamRequest =
        await client.openUrl(method, item.upstream);
    upstreamRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final String? range =
        request.headers.value(HttpHeaders.rangeHeader)?.trim();
    if (range != null && _rangePattern.hasMatch(range)) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
    }
    final HttpClientResponse upstream = await upstreamRequest.close();

    final int status = upstream.statusCode;
    if (status != HttpStatus.ok &&
        status != HttpStatus.partialContent &&
        status != HttpStatus.requestedRangeNotSatisfiable) {
      // The server said no (expired session, missing item, outage). The
      // receiver learns only that the relay could not get it.
      await upstream.listen(null).cancel();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    response.statusCode = status;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      upstream.headers.contentType?.toString() ?? item.contentType,
    );
    for (final String name in _relayedHeaders) {
      final List<String>? values = upstream.headers[name];
      if (values != null && values.isNotEmpty) {
        response.headers.set(name, values.first);
      }
    }
    if (status == HttpStatus.partialContent &&
        upstream.headers[HttpHeaders.acceptRangesHeader] == null) {
      // The server just served a range, so it supports them even if it did
      // not say so.
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (upstream.contentLength >= 0) {
      response.contentLength = upstream.contentLength;
    }

    if (method == 'HEAD') {
      await upstream.listen(null).cancel();
      await response.close();
      return;
    }
    await response.addStream(upstream);
    await response.close();
  }

  _PublishedItem? _lookup(Uri uri) {
    final List<String> segments = uri.pathSegments;
    if (segments.length != 2 || segments[0] != pathPrefix) return null;
    final String token = segments[1];
    final _PublishedItem? item = _items[token];
    if (item == null) return null;
    if (_clock().difference(item.issuedAt) >= tokenLifetime) {
      _items.remove(token);
      return null;
    }
    return item;
  }

  static Future<HttpServer> _bindEphemeral(InternetAddress address) =>
      HttpServer.bind(address, 0);

  /// The phone's address on the local network, the one a receiver on the same
  /// Wi-Fi can reach. Throws [CastMediaRelayException] when there is none.
  static Future<InternetAddress> findLanAddress() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final InternetAddress? address = pickLanAddress(
      <({String interface, InternetAddress address})>[
        for (final NetworkInterface interface in interfaces)
          for (final InternetAddress address in interface.addresses)
            (interface: interface.name, address: address),
      ],
    );
    if (address == null) {
      throw const CastMediaRelayException(
        CastMediaRelayException.unavailableMessage,
      );
    }
    return address;
  }

  /// Picks the address a receiver on the same LAN can reach: a private IPv4
  /// address (10/8, 172.16/12, 192.168/16) on a Wi-Fi, Ethernet or hotspot
  /// interface, preferring Wi-Fi. Tunnels, mobile data and container bridges
  /// are never picked, even with a private address.
  @visibleForTesting
  static InternetAddress? pickLanAddress(
    List<({String interface, InternetAddress address})> candidates,
  ) {
    InternetAddress? best;
    int bestRank = 1 << 30;
    for (final ({String interface, InternetAddress address}) c in candidates) {
      if (c.address.type != InternetAddressType.IPv4) continue;
      if (!_isPrivateIPv4(c.address)) continue;
      final int? rank = _interfaceRank(c.interface.toLowerCase());
      if (rank == null || rank >= bestRank) continue;
      best = c.address;
      bestRank = rank;
    }
    return best;
  }

  static const List<String> _excludedInterfaces = <String>[
    'tun',
    'tap',
    'ppp',
    'wg',
    'tailscale',
    'ipsec',
    'rmnet',
    'ccmni',
    'clat',
    'v4-',
    'dummy',
    'docker',
    'veth',
    'br-',
    'virbr',
    'lo',
  ];

  /// Lower is better; null means never use this interface.
  static int? _interfaceRank(String name) {
    for (final String prefix in _excludedInterfaces) {
      if (name.startsWith(prefix)) return null;
    }
    if (name.startsWith('wlan') || name.startsWith('wl')) return 0;
    if (name.startsWith('eth') || name.startsWith('en')) return 1;
    if (name.startsWith('ap') || name.startsWith('swlan')) return 2;
    return 3;
  }

  static bool _isPrivateIPv4(InternetAddress address) {
    final List<int> b = address.rawAddress;
    if (b.length != 4) return false;
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    return b[0] == 192 && b[1] == 168;
  }
}

class _PublishedItem {
  const _PublishedItem({
    required this.upstream,
    required this.contentType,
    required this.issuedAt,
  });

  /// The server's own URL, credential and all. Never leaves this object except
  /// as the target of the proxy's own request.
  final Uri upstream;
  final String contentType;
  final DateTime issuedAt;
}
