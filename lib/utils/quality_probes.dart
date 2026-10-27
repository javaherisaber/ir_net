import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The probe could not be sent at all (a local problem such as a socket the
/// sandbox refuses), which is not packet loss.
class ProbeUnavailable implements Exception {
  const ProbeUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Something that measures one round trip at a time.
abstract class RttProber {
  /// Completes with the round-trip time in milliseconds, or null when no reply
  /// arrived in time (a lost probe). Throws only [ProbeUnavailable].
  Future<double?> probe();

  /// Forgets sockets / connections / resolved addresses, e.g. after the
  /// network or VPN changed.
  void reset();

  void close();
}

// ───────────────────────────── STUN (UDP) ─────────────────────────────

const _stunMagicCookie = 0x2112A442;

/// Builds a 20-byte STUN Binding Request (RFC 5389) with no attributes.
Uint8List buildStunBindingRequest(Uint8List transactionId) {
  assert(transactionId.length == 12);
  final bytes = Uint8List(20);
  final view = ByteData.sublistView(bytes);
  view.setUint16(0, 0x0001); // Binding Request
  view.setUint16(2, 0); // no attributes
  view.setUint32(4, _stunMagicCookie);
  bytes.setRange(8, 20, transactionId);
  return bytes;
}

/// Transaction id of a STUN Binding success/error response, or null when
/// [data] is anything else.
Uint8List? stunResponseTransactionId(Uint8List data) {
  if (data.length < 20) return null;
  final view = ByteData.sublistView(data);
  final type = view.getUint16(0);
  if (type != 0x0101 && type != 0x0111) return null;
  if (view.getUint32(4) != _stunMagicCookie) return null;
  if (view.getUint16(2) + 20 > data.length) return null;
  return Uint8List.sublistView(data, 8, 20);
}

class StunTarget {
  const StunTarget(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Public STUN servers on anycast networks, so the measured path is "VPN exit
/// → nearest edge" wherever the exit is.
const defaultStunTargets = <StunTarget>[
  StunTarget('stun.cloudflare.com', 3478),
  StunTarget('stun.l.google.com', 19302),
  StunTarget('global.stun.twilio.com', 3478),
];

typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Measures packet loss and latency with STUN Binding requests over one
/// long-lived UDP socket (a stable source port, like a call or game would use,
/// so the VPN keeps one UDP session instead of setting up a new one per probe).
class StunProber implements RttProber {
  StunProber({
    this.targets = defaultStunTargets,
    this.timeout = const Duration(seconds: 2),
    HostLookup? lookup,
    Random? random,
  })  : _lookup = lookup ?? _lookupIPv4,
        _random = random ?? Random.secure();

  final List<StunTarget> targets;
  final Duration timeout;
  final HostLookup _lookup;
  final Random _random;

  /// After this many lost probes in a row, try the next server in case the
  /// current one (rather than the connection) is unreachable.
  static const rotateAfterLosses = 8;
  static const _readdressEvery = Duration(minutes: 10);

  RawDatagramSocket? _socket;
  InternetAddress? _address;
  DateTime? _resolvedAt;
  int _targetIndex = 0;
  int _consecutiveLosses = 0;
  final _pending = <String, ({Stopwatch watch, Completer<double?> done})>{};

  StunTarget get currentTarget => targets[_targetIndex % targets.length];

  static Future<List<InternetAddress>> _lookupIPv4(String host) =>
      InternetAddress.lookup(host, type: InternetAddressType.IPv4);

  @override
  Future<double?> probe() async {
    final rtt = await _probe(); // ProbeUnavailable propagates: not a loss
    if (rtt == null) {
      _consecutiveLosses++;
      if (_consecutiveLosses % rotateAfterLosses == 0) {
        _targetIndex++;
        _address = null;
      }
    } else {
      _consecutiveLosses = 0;
    }
    return rtt;
  }

  Future<double?> _probe() async {
    final address = await _resolve();
    if (address == null) return null;
    final socket = await _ensureSocket(address);

    final id = Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256)));
    final key = _key(id);
    final entry = (watch: Stopwatch(), done: Completer<double?>());
    _pending[key] = entry;
    try {
      entry.watch.start();
      final written = socket.send(buildStunBindingRequest(id), address, currentTarget.port);
      if (written == 0) return null;
      return await entry.done.future.timeout(timeout, onTimeout: () => null);
    } on SocketException {
      _dropSocket();
      return null;
    } finally {
      _pending.remove(key);
    }
  }

  Future<InternetAddress?> _resolve() async {
    final fresh = _resolvedAt != null && DateTime.now().difference(_resolvedAt!) < _readdressEvery;
    if (_address != null && fresh) return _address;
    try {
      final found = await _lookup(currentTarget.host).timeout(timeout);
      _address = found.isEmpty ? null : found.first;
      _resolvedAt = DateTime.now();
    } catch (_) {
      _address = null;
    }
    return _address;
  }

  Future<RawDatagramSocket> _ensureSocket(InternetAddress target) async {
    final existing = _socket;
    if (existing != null && existing.address.type == target.type) return existing;
    _dropSocket();
    try {
      final any = target.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4;
      final socket = await RawDatagramSocket.bind(any, 0);
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          Datagram? datagram;
          while ((datagram = socket.receive()) != null) {
            _onDatagram(datagram!.data);
          }
        },
        onError: (_) => _dropSocket(),
        cancelOnError: true,
      );
      return _socket = socket;
    } on SocketException catch (e) {
      throw ProbeUnavailable('UDP socket unavailable: ${e.osError?.message ?? e.message}');
    }
  }

  void _onDatagram(Uint8List data) {
    final id = stunResponseTransactionId(data);
    if (id == null) return;
    final entry = _pending[_key(id)];
    if (entry == null || entry.done.isCompleted) return;
    entry.done.complete(entry.watch.elapsedMicroseconds / 1000);
  }

  static String _key(Uint8List id) => id.join(',');

  void _dropSocket() {
    _socket?.close();
    _socket = null;
  }

  @override
  void reset() {
    _dropSocket();
    _address = null;
    _consecutiveLosses = 0;
  }

  @override
  void close() => reset();
}

// ───────────────────────────── HTTPS ─────────────────────────────

/// Endpoints that answer `204 No Content` with a tiny response, built for
/// connectivity checks.
const defaultProbeUrls = <String>[
  'https://www.gstatic.com/generate_204',
  'https://cp.cloudflare.com/generate_204',
];

/// Measures the "real delay": a HEAD request on an already-open HTTPS
/// connection, i.e. one round trip through the VPN (and through the system
/// proxy when one is configured), without the TCP/TLS handshake.
class HttpsProber implements RttProber {
  HttpsProber({
    this.urls = defaultProbeUrls,
    this.timeout = const Duration(seconds: 5),
    this.proxy,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final List<String> urls;
  final Duration timeout;

  /// Current `host:port` HTTP proxy, if any (read before each probe).
  final String? Function()? proxy;
  final HttpClient Function() _clientFactory;

  static const rotateAfterFailures = 3;

  HttpClient? _client;
  String? _clientProxy;
  int? _lastLocalPort;
  int _urlIndex = 0;
  int _consecutiveFailures = 0;

  String get currentUrl => urls[_urlIndex % urls.length];

  @override
  Future<double?> probe() async {
    var result = await _request();
    // A fresh connection pays for the TCP + TLS handshake; repeat on the now
    // warm connection to time a single round trip.
    if (result != null && !result.reused) result = await _request();
    if (result == null) {
      _consecutiveFailures++;
      if (_consecutiveFailures % rotateAfterFailures == 0) _urlIndex++;
      return null;
    }
    _consecutiveFailures = 0;
    return result.ms;
  }

  Future<({double ms, bool reused})?> _request() async {
    final client = _ensureClient();
    final watch = Stopwatch()..start();
    try {
      final request = await client.openUrl('HEAD', Uri.parse(currentUrl)).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout - watch.elapsed);
      final ms = watch.elapsedMicroseconds / 1000;
      await response.drain<void>().timeout(timeout);
      final port = response.connectionInfo?.localPort;
      final reused = port != null && port == _lastLocalPort;
      _lastLocalPort = port;
      if (response.statusCode != 204 && response.statusCode != 200) return null;
      return (ms: ms, reused: reused);
    } catch (_) {
      // Timed out or failed: the connection may be wedged, start over.
      _dropClient();
      return null;
    }
  }

  HttpClient _ensureClient() {
    final currentProxy = proxy?.call();
    if (_client != null && currentProxy == _clientProxy) return _client!;
    _dropClient();
    final client = _clientFactory()
      ..idleTimeout = const Duration(seconds: 60)
      ..connectionTimeout = timeout
      ..maxConnectionsPerHost = 1;
    if (currentProxy != null) {
      client.findProxy = (_) => 'PROXY $currentProxy';
    }
    _clientProxy = currentProxy;
    return _client = client;
  }

  void _dropClient() {
    _client?.close(force: true);
    _client = null;
    _lastLocalPort = null;
  }

  @override
  void reset() => _dropClient();

  @override
  void close() => _dropClient();
}
