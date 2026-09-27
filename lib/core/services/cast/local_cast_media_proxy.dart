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
///    [Random.secure] per item; the receiver's first request for it forgets
///    every earlier one (and [revoke] drops it instead if the handoff failed,
///    so the item still playing keeps working). A token also
///    expires after [tokenLifetime] even if the session is still up. Unknown
///    and expired tokens get the same bare 404.
///  - **Seeking works.** A `Range` request is forwarded upstream and the answer
///    relayed as is: `206 Partial Content`, `Content-Range`, `Accept-Ranges`,
///    `Content-Length`. Without that the receiver cannot scrub or buffer.
///  - **Nothing leaks back.** An upstream failure becomes an empty `502`, with
///    none of the server's body or headers, and so does a success that is a
///    page rather than audio (a login screen, a Subsonic error document). A
///    `416` keeps its status and `Content-Range` but loses its body. Redirects
///    are followed here, same host only, never by `HttpClient`. An upstream
///    that sends no headers in [upstreamHeaderTimeout] is a `502` too. Only a
///    fixed list of media headers is copied. Nothing here logs.
///  - **Only real use renews it.** The idle timer counts requests carrying a
///    live token (and [touch]); a scanner knocking with a guessed path does not
///    keep an orphaned relay alive.
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
    this.upstreamHeaderTimeout = const Duration(seconds: 20),
    this.upstreamBodyIdleTimeout = const Duration(seconds: 30),
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

  /// How long the upstream server gets to send response headers once
  /// connected. `HttpClient.connectionTimeout` only covers connecting; a server
  /// or reverse proxy that accepts and then says nothing would otherwise hold
  /// the request, and the relay's idle shutdown, forever.
  final Duration upstreamHeaderTimeout;

  /// How long the upstream body may go without delivering a byte. A server
  /// that sends headers and then stalls without closing would otherwise hold
  /// the transfer, and the idle shutdown, forever. The countdown pauses while
  /// the receiver is not reading (backpressure), so only a stalled server
  /// trips it.
  final Duration upstreamBodyIdleTimeout;

  /// Redirects followed per request, same host only.
  static const int _maxRedirects = 3;

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
  int _nextSerial = 0;

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
    // Earlier items stay live: the receiver keeps playing the previous one
    // until it has taken this one, and the proof of that is its first request
    // for this item (see [_lookup]).
    final String token = newToken();
    _items[token] = _PublishedItem(
      upstream: media.url,
      contentType: media.contentType,
      issuedAt: _clock(),
      serial: _nextSerial++,
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
  void revoke(CastMedia relayed) {
    final String? token = _tokenOf(relayed);
    if (token != null) _items.remove(token);
  }

  /// The token behind a URL this relay issued, or null for anything else.
  String? _tokenOf(CastMedia relayed) {
    final List<String> segments = relayed.url.pathSegments;
    if (segments.length != 2 || segments[0] != pathPrefix) return null;
    return segments[1];
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

    // Only a request carrying a live token counts as activity. Anything else on
    // the LAN (a scanner, a guessed path) must not be able to keep an orphaned
    // relay alive.
    _inFlight++;
    _idleTimer?.cancel();
    try {
      await _relay(request, item, client);
    } finally {
      _inFlight--;
      _armIdleTimer();
    }
  }

  Future<void> _relay(
    HttpRequest request,
    _PublishedItem item,
    HttpClient client,
  ) async {
    final HttpResponse response = request.response;
    final String method = request.method;
    final String? range =
        request.headers.value(HttpHeaders.rangeHeader)?.trim();
    final HttpClientResponse? upstream = await _fetchUpstream(
      client,
      method,
      item.upstream,
      range != null && _rangePattern.hasMatch(range) ? range : null,
    );
    if (upstream == null) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    final int status = upstream.statusCode;
    final bool media =
        status == HttpStatus.ok || status == HttpStatus.partialContent;
    if ((!media && status != HttpStatus.requestedRangeNotSatisfiable) ||
        (media && !_looksLikeMedia(upstream.headers.contentType))) {
      // The server said no (expired session, missing item, outage), or said
      // yes with a page instead of audio (a login screen, a Subsonic error
      // document). The receiver learns only that the relay could not get it.
      await upstream.listen(null).cancel();
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    if (!media) {
      // 416: keep the status and Content-Range so the receiver can recover,
      // but never the body, which a server or proxy may fill with diagnostics
      // that include the requested URL and its credential.
      await upstream.listen(null).cancel();
      response.statusCode = status;
      final List<String>? contentRange =
          upstream.headers[HttpHeaders.contentRangeHeader];
      if (contentRange != null && contentRange.isNotEmpty) {
        response.headers
            .set(HttpHeaders.contentRangeHeader, contentRange.first);
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = 0;
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
    // A stall surfaces as a TimeoutException out of addStream: the upstream
    // subscription is cancelled (closing that connection) and the receiver's
    // transfer is cut, via the error path in [_handle].
    await response.addStream(upstream.timeout(upstreamBodyIdleTimeout));
    await response.close();
  }

  /// Fetches [url] with redirects handled here rather than by `HttpClient`, so
  /// every hop is checked: only the same host is followed (an http to https
  /// upgrade is allowed, a downgrade is not), at most [_maxRedirects] times.
  /// Returns null when the upstream cannot be used: no headers in time, a
  /// redirect elsewhere, or too many hops.
  Future<HttpClientResponse?> _fetchUpstream(
    HttpClient client,
    String method,
    Uri url,
    String? range,
  ) async {
    Uri target = url;
    for (int hop = 0; hop <= _maxRedirects; hop++) {
      final HttpClientRequest request = await client.openUrl(method, target);
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final Future<HttpClientResponse> pending = request.close();
      final HttpClientResponse response;
      try {
        response = await pending.timeout(upstreamHeaderTimeout);
      } on TimeoutException {
        request.abort();
        // The aborted request still settles; make sure it goes nowhere.
        unawaited(pending.then<void>(
          (HttpClientResponse late) => late.listen(null).cancel(),
          onError: (Object _) {},
        ));
        return null;
      }
      if (!response.isRedirect) return response;

      final String? location =
          response.headers.value(HttpHeaders.locationHeader);
      await response.listen(null).cancel();
      if (location == null) return null;
      final Uri next = target.resolve(location);
      if (!isAllowedRedirect(url, target, next)) return null;
      target = next;
    }
    return null;
  }

  /// Whether a redirect from [current] to [next] may be followed: the host
  /// stays the one of the [original] URL, and the scheme never downgrades
  /// relative to the hop it comes from, so http, then https, then http again
  /// is refused.
  @visibleForTesting
  static bool isAllowedRedirect(Uri original, Uri current, Uri next) {
    if (next.host.toLowerCase() != original.host.toLowerCase()) return false;
    if (next.scheme == current.scheme) return true;
    return current.scheme == 'http' && next.scheme == 'https';
  }

  /// Whether a successful upstream answer can be audio. A missing type is
  /// allowed (the resolver's hint is used); a document type is not.
  static bool _looksLikeMedia(ContentType? type) {
    if (type == null) return true;
    final String primary = type.primaryType.toLowerCase();
    final String sub = type.subType.toLowerCase();
    if (primary == 'text') return false;
    if (primary == 'application' &&
        (sub == 'json' ||
            sub == 'xml' ||
            sub.endsWith('+xml') ||
            sub.endsWith('+json'))) {
      return false;
    }
    return true;
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
    // The receiver asking for this item is the acknowledgement that it took
    // it: every item published before it is dropped. Asking for an older item
    // (still finishing the previous track) drops nothing.
    _items.removeWhere((_, _PublishedItem other) => other.serial < item.serial);
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
    required this.serial,
  });

  /// The server's own URL, credential and all. Never leaves this object except
  /// as the target of the proxy's own request.
  final Uri upstream;
  final String contentType;
  final DateTime issuedAt;

  /// Publication order, so a request for an item can retire older ones.
  final int serial;
}
