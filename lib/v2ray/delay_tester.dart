import 'dart:async';
import 'dart:io';

import 'models.dart';
import 'xray_config.dart';
import 'xray_runner.dart';

typedef DelayCallback = void Function(String profileId, DelayResult result);

/// Measures each config's real delay: one core instance serves a batch of
/// configs on separate local ports, and an HTTP request to [url] goes
/// through each. Without a core (iOS) it falls back to a TCP connect to the
/// server, which shows reachability only.
class DelayTester {
  DelayTester({
    required this.runner,
    this.url = defaultUrl,
    this.timeout = const Duration(seconds: 8),
    this.batchSize = 40,
    this.concurrency = 12,
    this.bindInterface,
  });

  final XrayRunner? runner;

  /// Tunnel mode: the physical interface to test from (see
  /// VpnEngine.testInterface), so tests skip the VPN.
  final String? bindInterface;
  final String url;
  final Duration timeout;
  final int batchSize;
  final int concurrency;

  /// Plain HTTP inside the tunnel (the tunnel itself is the config's TLS):
  /// the test speaks HTTP over the CONNECT tunnel itself, see [_measure].
  static const defaultUrl = 'http://www.gstatic.com/generate_204';

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<void> run(List<V2rayProfile> profiles, DelayCallback onResult) async {
    _cancelled = false;
    final usable = <V2rayProfile>[];
    for (final p in profiles) {
      if (p.isUsable) {
        usable.add(p);
      } else {
        onResult(p.id, _fail('Not supported'));
      }
    }
    if (runner == null) {
      await _pool(usable, (p) async => onResult(p.id, await _tcpPing(p)));
      return;
    }
    for (var i = 0; i < usable.length && !_cancelled; i += batchSize) {
      final batch = usable.sublist(i, (i + batchSize).clamp(0, usable.length));
      await _runBatch(batch, onResult, allowSplit: true);
    }
  }

  Future<void> _runBatch(List<V2rayProfile> batch, DelayCallback onResult, {required bool allowSplit}) async {
    final ports = await LocalPorts.free(batch.length);
    final entries = [for (var i = 0; i < batch.length; i++) (profile: batch[i], port: ports[i])];
    XrayInstance? instance;
    String? failure;
    try {
      instance = await runner!.start(
          XrayConfigBuilder.encode(XrayConfigBuilder.tester(entries, bindInterface: bindInterface)),
          label: 'test');
      // All inbounds open together; the last one up means the core is ready.
      if (!await LocalPorts.waitFor(ports.last, instance)) {
        failure = instance.logTail.isEmpty ? 'The core did not start' : instance.logTail;
      }
    } on XrayStartException catch (e) {
      failure = e.message;
    }

    if (failure != null) {
      await instance?.stop();
      if (allowSplit && batch.length > 1) {
        // One config the core rejects sinks the whole batch; test them one
        // by one so the others still get a result.
        await _pool(batch, (p) => _runBatch([p], onResult, allowSplit: false), width: 4);
      } else {
        for (final p in batch) {
          onResult(p.id, _fail(_shortError(failure)));
        }
      }
      return;
    }

    try {
      await _pool(entries, (e) async {
        if (_cancelled) return;
        onResult(e.profile.id, await _measure(e.port));
      });
    } finally {
      await instance!.stop();
    }
  }

  /// The round trip through the server, on the local inbound at [port].
  ///
  /// One tunnel (CONNECT) through the config to [url]'s host carries two
  /// plain HTTP requests. The first pays for opening the way (TCP, TLS and the
  /// transport's own handshake to the server, then the server's connection
  /// onward: several round trips) and shows the config works; the second
  /// goes over the same tunnel, so its time is one round trip through the
  /// server, what a ping or a speed test reports. (dart:io's HttpClient
  /// opens a new tunnel for every HTTPS request through a proxy, so it
  /// can't measure this.) If the second request fails, the first's time
  /// stands.
  Future<DelayResult> _measure(int port) async {
    final uri = Uri.parse(url);
    assert(uri.scheme == 'http', 'the delay test speaks plain HTTP inside the tunnel');
    final targetPort = uri.hasPort ? uri.port : 80;
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : (uri.path.isEmpty ? '/' : uri.path);
    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final d = deadline.difference(DateTime.now());
      if (d <= Duration.zero) throw TimeoutException('delay test');
      return d;
    }

    _Wire? wire;
    try {
      final watch = Stopwatch()..start();
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: left());
      wire = _Wire(socket);
      socket.write('CONNECT ${uri.host}:$targetPort HTTP/1.1\r\nHost: ${uri.host}:$targetPort\r\n\r\n');
      final connect = await wire.readHead().timeout(left());
      if (connect.status != 200) return _fail('Failed');
      Future<void> get() async {
        wire!.socket.write('GET $path HTTP/1.1\r\nHost: ${uri.host}\r\nUser-Agent: IRNet\r\n'
            'Connection: keep-alive\r\n\r\n');
        final head = await wire.readHead().timeout(left());
        if (head.status < 200 || head.status >= 400) throw HttpException('HTTP ${head.status}');
        if (head.contentLength > 0) await wire.readBytes(head.contentLength).timeout(left());
      }

      await get();
      final opening = watch.elapsedMilliseconds;
      try {
        watch.reset();
        await get();
        return DelayResult(ms: watch.elapsedMilliseconds, at: _now());
      } catch (_) {
        return DelayResult(ms: opening, at: _now());
      }
    } on TimeoutException {
      return _fail('Timeout');
    } on HttpException catch (e) {
      return _fail(e.message.contains('503') ? 'Failed' : _shortError(e.message));
    } catch (e) {
      return _fail('Failed');
    } finally {
      wire?.socket.destroy();
    }
  }

  Future<DelayResult> _tcpPing(V2rayProfile p) async {
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(p.address, p.port, timeout: timeout);
      watch.stop();
      socket.destroy();
      return DelayResult(ms: watch.elapsedMilliseconds, at: _now());
    } on SocketException catch (e) {
      return _fail(e.osError == null ? 'Timeout' : 'Failed');
    } catch (_) {
      return _fail('Failed');
    }
  }

  Future<void> _pool<T>(List<T> items, Future<void> Function(T) task, {int? width}) async {
    var next = 0;
    Future<void> worker() async {
      while (next < items.length && !_cancelled) {
        final item = items[next++];
        await task(item);
      }
    }

    await Future.wait(List.generate((width ?? concurrency).clamp(1, items.isEmpty ? 1 : items.length), (_) => worker()));
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static DelayResult _fail(String error) => DelayResult(error: error, at: _now());

  static String _shortError(String message) {
    final line = message.trim().split('\n').last;
    // Xray log lines: "... [Error] infra/conf: <message>"; keep the message.
    final m = RegExp(r'\]\s*(.+)$').firstMatch(line);
    final text = (m?.group(1) ?? line).trim();
    return text.length > 120 ? '${text.substring(0, 117)}…' : text;
  }
}

/// A response head: status and Content-Length.
class _Head {
  const _Head(this.status, this.contentLength);
  final int status;
  final int contentLength;
}

/// Reads HTTP heads and bodies off a socket, keeping what arrives early.
class _Wire {
  _Wire(this.socket) {
    socket.listen((data) {
      _buffer.addAll(data);
      _wake();
    }, onError: (Object e) {
      _closed = true;
      _wake(e);
    }, onDone: () {
      _closed = true;
      _wake();
    }, cancelOnError: true);
  }

  final Socket socket;
  final _buffer = <int>[];
  Completer<void>? _more;
  bool _closed = false;

  void _wake([Object? error]) {
    final c = _more;
    _more = null;
    if (c == null || c.isCompleted) return;
    error == null ? c.complete() : c.completeError(error);
  }

  Future<void> _wait() async {
    if (_closed) throw const SocketException('Connection closed');
    await (_more = Completer<void>()).future;
  }

  Future<_Head> readHead() async {
    while (true) {
      final end = _indexOfBlankLine();
      if (end >= 0) {
        final head = String.fromCharCodes(_buffer.sublist(0, end));
        _buffer.removeRange(0, end + 4);
        final lines = head.split('\r\n');
        final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
        var length = 0;
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0 && l.substring(0, i).trim().toLowerCase() == 'content-length') {
            length = int.tryParse(l.substring(i + 1).trim()) ?? 0;
          }
        }
        return _Head(status, length);
      }
      await _wait();
    }
  }

  Future<void> readBytes(int n) async {
    while (_buffer.length < n) {
      await _wait();
    }
    _buffer.removeRange(0, n);
  }

  int _indexOfBlankLine() {
    for (var i = 0; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10 && _buffer[i + 2] == 13 && _buffer[i + 3] == 10) return i;
    }
    return -1;
  }
}
