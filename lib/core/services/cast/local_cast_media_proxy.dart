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
///    itself after [idleTimeout] without activity (a request with a live
///    token, bytes actually moving, or a [touch]), as a safety net for a
///    session that ended without telling it. A transfer the receiver stopped
///    reading is not activity, so it cannot hold the relay open forever.
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
    Duration Function()? elapsed,
    DateTime Function()? wallClock,
    this.idleTimeout = const Duration(minutes: 30),
    this.tokenLifetime = const Duration(hours: 6),
    this.upstreamHeaderTimeout = const Duration(seconds: 20),
    this.upstreamBodyIdleTimeout = const Duration(seconds: 30),
  })  : _lanAddress = lanAddress ?? findLanAddress,
        _bind = bind ?? _bindEphemeral,
        _httpClient = httpClient ?? HttpClient.new,
        _elapsed = elapsed ?? tokenClock(),
        _wallClock = wallClock ?? DateTime.now;

  /// The first path segment of every relayed URL.
  static const String pathPrefix = 'cast';

  /// Token size in bytes before encoding: 256 bits, 43 base64url characters.
  static const int tokenBytes = 32;

  /// How long the proxy waits without activity (a request with a live token,
  /// bytes moving, or a [touch]) before it shuts itself down.
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
  static Duration Function() _monotonicClock() {
    final Stopwatch stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  /// The clock tokens are aged on by default: the kernel's boot clock
  /// ([bootClock]) when it can be read, otherwise a [Stopwatch].
  @visibleForTesting
  static Duration Function() tokenClock() => bootClock() ?? _monotonicClock();

  /// Linux's boot clock (`CLOCK_BOOTTIME`), read from `/proc/uptime`, which
  /// Android shares. It cannot be set and keeps counting while the device is
  /// suspended, so neither turning the clock back nor sleeping, in any order,
  /// stretches a token's life. Returns null when it cannot be read (another
  /// platform, or a `/proc` this process may not see).
  ///
  /// A read that fails or goes backwards later on is not trusted: the clock
  /// carries on from the last good reading on a [Stopwatch], so it never
  /// steps back.
  @visibleForTesting
  static Duration Function()? bootClock({String Function()? readUptime}) {
    if (readUptime == null && !Platform.isLinux && !Platform.isAndroid) {
      return null;
    }
    final String Function() read = readUptime ?? _readProcUptime;
    Duration? tryRead() {
      try {
        return parseUptime(read());
      } on Exception {
        return null;
      }
    }

    Duration? last = tryRead();
    if (last == null) return null;
    final Stopwatch sinceLast = Stopwatch()..start();
    return () {
      final Duration? reading = tryRead();
      if (reading == null || reading < last!) return last! + sinceLast.elapsed;
      last = reading;
      sinceLast.reset();
      return reading;
    };
  }

  static String _readProcUptime() => File('/proc/uptime').readAsStringSync();

  static final RegExp _uptimeLine = RegExp(r'^(\d{1,12})\.(\d{1,6})\s');

  /// The first field of `/proc/uptime` (`12345.67 54321.00`), or null when the
  /// text is not in that shape.
  @visibleForTesting
  static Duration? parseUptime(String text) {
    final RegExpMatch? match = _uptimeLine.firstMatch(text);
    if (match == null) return null;
    return Duration(
      seconds: int.parse(match[1]!),
      microseconds: int.parse(match[2]!.padRight(6, '0')),
    );
  }

  /// A reading that cannot be moved back, used to age tokens: the boot clock
  /// by default (see [bootClock]), which also counts time spent suspended.
  /// Where that cannot be read it falls back to a [Stopwatch], which stands
  /// still during suspend; [_wallClock] covers plain sleeping then, but not a
  /// clock turned back and then slept on.
  final Duration Function() _elapsed;

  /// The wall clock, read alongside [_elapsed]. A token expires as soon as
  /// either says its lifetime is up. With the boot clock this only ever ends
  /// a token early (a clock moved forward), which is the safe direction; with
  /// the [Stopwatch] fallback it is what expires a token the device slept
  /// past.
  final DateTime Function() _wallClock;

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

  /// Time since the last activity. Real time on purpose (not the injectable
  /// token clock): this only decides when an abandoned relay closes.
  final Stopwatch _sinceActivity = Stopwatch();
  final Map<String, _PublishedItem> _items = <String, _PublishedItem>{};
  int _nextSerial = 0;

  /// The item the receiver most recently asked for, i.e. the one playing.
  int? _playingSerial;

  /// How many tokens are live. Exposed for tests: it never grows past the
  /// item playing plus the newest one handed over.
  @visibleForTesting
  int get liveItemCount => _items.length;

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
    // The item playing stays live: the receiver keeps playing it until it has
    // taken this one, and the proof of that is its first request for this item
    // (see [_lookup]). Anything else is dropped now: expired items, and earlier
    // handoffs the receiver never asked for, which this one supersedes. So at
    // most two tokens are ever live, and no upstream URL lingers unused.
    final Duration now = _elapsed();
    final DateTime wallNow = _wallClock();
    _items.removeWhere((_, _PublishedItem item) =>
        _expired(item, now, wallNow) || item.serial != _playingSerial);
    final String token = newToken();
    _items[token] = _PublishedItem(
      upstream: media.url,
      contentType: media.contentType,
      issuedAt: now,
      issuedAtWall: wallNow,
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
    _playingSerial = null;
    final HttpServer? server = _server;
    final HttpClient? client = _client;
    _server = null;
    _client = null;
    _base = null;
    client?.close(force: true);
    if (server != null) await server.close(force: true);
  }

  /// Records activity and (re)schedules the idle check.
  void _armIdleTimer() {
    _markActivity();
    _scheduleIdleCheck(idleTimeout);
  }

  /// Records activity without touching the timer, cheap enough to call for
  /// every chunk relayed.
  void _markActivity() => _sinceActivity
    ..reset()
    ..start();

  void _scheduleIdleCheck(Duration after) {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_server == null) return;
    _idleTimer = Timer(after, () {
      final Duration quiet = _sinceActivity.elapsed;
      if (quiet >= idleTimeout) {
        // Nothing moved for the whole window, open transfers included (a
        // receiver that stopped reading holds a transfer without progress).
        unawaited(stop());
      } else {
        _scheduleIdleCheck(idleTimeout - quiet);
      }
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
    // relay alive. During the transfer, activity is bytes actually moving.
    _armIdleTimer();
    try {
      await _relay(request, item, client);
    } finally {
      _markActivity();
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
    final String encoding =
        (upstream.headers.value(HttpHeaders.contentEncodingHeader) ??
                'identity')
            .trim()
            .toLowerCase();
    if ((!media && status != HttpStatus.requestedRangeNotSatisfiable) ||
        (media && !_looksLikeMedia(upstream.headers.contentType)) ||
        (media && encoding != 'identity')) {
      // The server said no (expired session, missing item, outage), said yes
      // with a page instead of audio (a login screen, a Subsonic error
      // document), or sent the audio compressed although identity was asked
      // for: relaying those bytes as the declared audio type would only hand
      // the receiver garbage. The receiver learns only that the relay could
      // not get it.
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
    await response.addStream(
        upstream.timeout(upstreamBodyIdleTimeout).map((List<int> chunk) {
      _markActivity();
      return chunk;
    }));
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

  /// See [_wallClock]: expired when either clock says so.
  bool _expired(_PublishedItem item, Duration now, DateTime wallNow) =>
      now - item.issuedAt >= tokenLifetime ||
      wallNow.difference(item.issuedAtWall) >= tokenLifetime;

  _PublishedItem? _lookup(Uri uri) {
    final List<String> segments = uri.pathSegments;
    if (segments.length != 2 || segments[0] != pathPrefix) return null;
    final String token = segments[1];
    final _PublishedItem? item = _items[token];
    if (item == null) return null;
    if (_expired(item, _elapsed(), _wallClock())) {
      _items.remove(token);
      return null;
    }
    // The receiver asking for this item is the acknowledgement that it took
    // it: every item published before it is dropped. Asking for an older item
    // (still finishing the previous track) drops nothing.
    _items.removeWhere((_, _PublishedItem other) => other.serial < item.serial);
    _playingSerial = item.serial;
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
  /// Lower is better; null means never use this interface. An allowlist: a
  /// name that is not a known Wi-Fi, Ethernet or hotspot interface is refused
  /// even with a private address, because mobile data and VPN interfaces go
  /// by many names (`wwan0`, `pdp_ip0`, `utun0`, ...) and binding to one would
  /// expose the relay where it must not be and hand the receiver an address it
  /// cannot reach.
  static int? _interfaceRank(String name) {
    for (final String prefix in _excludedInterfaces) {
      if (name.startsWith(prefix)) return null;
    }
    if (name.startsWith('wlan') || name.startsWith('wl')) return 0;
    if (name.startsWith('eth') || name.startsWith('en')) return 1;
    if (name.startsWith('ap') || name.startsWith('swlan')) return 2;
    return null;
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
    required this.issuedAtWall,
    required this.serial,
  });

  /// The server's own URL, credential and all. Never leaves this object except
  /// as the target of the proxy's own request.
  final Uri upstream;
  final String contentType;

  /// When it was published, on the relay's token clock (`_elapsed`).
  final Duration issuedAt;

  /// When it was published, on the wall clock (see [LocalCastMediaProxy]'s
  /// `_wallClock` for why both are kept).
  final DateTime issuedAtWall;

  /// Publication order, so a request for an item can retire older ones.
  final int serial;
}
