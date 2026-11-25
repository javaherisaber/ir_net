import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One HTTPS connection through an HTTP proxy's CONNECT tunnel, kept open
/// for many requests.
///
/// dart:io's HttpClient opens a new tunnel for every HTTPS request through a
/// proxy (it files the tunnel under the site but looks connections up under
/// the proxy), so its timings always include the setup: the tunnel, the
/// server's connection onward and the TLS handshake, several round trips.
/// Over this connection the second request onward is one round trip.
class ProxyHttpsConnection {
  ProxyHttpsConnection._(this._wire, this.host);

  final _RawWire _wire;
  final String host;
  bool _reusable = true;

  /// Whether another request can go over this connection.
  bool get isOpen => _reusable && !_wire.closed;

  /// Opens a tunnel through [proxy] ("[user:pass@]host:port") to
  /// [host]:[port] and starts TLS inside it.
  static Future<ProxyHttpsConnection> open(
    String proxy,
    String host,
    int port, {
    required Duration timeout,
    SecurityContext? context,
  }) async {
    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final d = deadline.difference(DateTime.now());
      if (d <= Duration.zero) throw TimeoutException('proxy tunnel');
      return d;
    }

    final at = proxy.lastIndexOf('@');
    final credentials = at < 0 ? null : proxy.substring(0, at);
    final address = proxy.substring(at + 1);
    final colon = address.lastIndexOf(':');
    final proxyHost = address.substring(0, colon).replaceAll('[', '').replaceAll(']', '');
    final proxyPort = int.parse(address.substring(colon + 1));

    final raw = await RawSocket.connect(proxyHost, proxyPort, timeout: left());
    final wire = _RawWire(raw);
    try {
      raw.setOption(SocketOption.tcpNoDelay, true);
      final auth = credentials == null
          ? ''
          : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode(Uri.decodeComponent(credentials)))}\r\n';
      await wire.write(ascii.encode('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n$auth\r\n')).timeout(left());
      final head = await wire.readHead().timeout(left());
      if (head.status != 200) throw HttpException('The proxy answered ${head.status} to CONNECT');
      // The server speaks only after our TLS hello; anything already here
      // would be lost to the TLS layer.
      if (wire.buffered) throw const HttpException('Unexpected data after CONNECT');
      final secure = await RawSecureSocket.secure(raw, subscription: wire.detach(), host: host, context: context)
          .timeout(left());
      return ProxyHttpsConnection._(_RawWire(secure), host);
    } catch (_) {
      wire.destroy();
      raw.close();
      rethrow;
    }
  }

  /// Sends `HEAD [path]` and returns the status once the response head is in.
  Future<int> head(String path, {required Duration timeout}) async {
    try {
      await _wire
          .write(ascii.encode('HEAD $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: IRNet\r\n'
              'Accept: */*\r\nConnection: keep-alive\r\n\r\n'))
          .timeout(timeout);
      final head = await _wire.readHead().timeout(timeout);
      if (head.close) _reusable = false;
      return head.status;
    } catch (_) {
      _reusable = false;
      rethrow;
    }
  }

  void close() {
    _reusable = false;
    _wire.destroy();
  }
}

/// A response head: status, and whether the server closes afterwards.
class _Head {
  const _Head(this.status, this.close);
  final int status;
  final bool close;
}

/// Buffered reads and complete writes over a [RawSocket] (or the
/// [RawSecureSocket] on top of it).
class _RawWire {
  _RawWire(this.socket) {
    _subscription = socket.listen(_onEvent, onError: (Object e) {
      closed = true;
      _wake(e);
    }, onDone: () {
      closed = true;
      _wake();
    });
  }

  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final _in = <int>[];
  final _out = <int>[];
  Completer<void>? _more;
  Completer<void>? _drained;
  bool closed = false;
  bool _detached = false;

  bool get buffered => _in.isNotEmpty;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = socket.read();
        if (data != null) _in.addAll(data);
        _wake();
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        closed = true;
        _wake();
    }
  }

  void _wake([Object? error]) {
    final c = _more;
    _more = null;
    if (c != null && !c.isCompleted) error == null ? c.complete() : c.completeError(error);
    if (closed) {
      final d = _drained;
      _drained = null;
      if (d != null && !d.isCompleted) d.completeError(const SocketException('Connection closed'));
    }
  }

  Future<void> write(List<int> bytes) {
    if (closed) return Future.error(const SocketException('Connection closed'));
    _out.addAll(bytes);
    _flush();
    if (_out.isEmpty) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  void _flush() {
    while (_out.isNotEmpty) {
      final n = socket.write(_out);
      if (n <= 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _out.removeRange(0, n);
    }
    final d = _drained;
    _drained = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  Future<_Head> readHead() async {
    while (true) {
      final end = _blankLine();
      if (end >= 0) {
        final lines = latin1.decode(_in.sublist(0, end)).split('\r\n');
        _in.removeRange(0, end + 4);
        final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
        var close = false;
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0 &&
              l.substring(0, i).trim().toLowerCase() == 'connection' &&
              l.substring(i + 1).trim().toLowerCase() == 'close') {
            close = true;
          }
        }
        return _Head(status, close);
      }
      if (closed) throw const SocketException('Connection closed');
      await (_more = Completer<void>()).future;
    }
  }

  int _blankLine() {
    for (var i = 0; i + 3 < _in.length; i++) {
      if (_in[i] == 13 && _in[i + 1] == 10 && _in[i + 2] == 13 && _in[i + 3] == 10) return i;
    }
    return -1;
  }

  /// Hands the socket's subscription over (to TLS); this wire stops reading.
  StreamSubscription<RawSocketEvent> detach() {
    _detached = true;
    return _subscription;
  }

  void destroy() {
    closed = true;
    if (!_detached) _subscription.cancel();
    socket.close();
  }
}
