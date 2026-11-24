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
  });

  final XrayRunner? runner;
  final String url;
  final Duration timeout;
  final int batchSize;
  final int concurrency;

  static const defaultUrl = 'https://www.gstatic.com/generate_204';

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
      instance = await runner!.start(XrayConfigBuilder.encode(XrayConfigBuilder.tester(entries)), label: 'test');
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

  /// One GET through the local inbound on [port].
  Future<DelayResult> _measure(int port) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = timeout
      ..userAgent = 'IRNet';
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      watch.stop();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return DelayResult(ms: watch.elapsedMilliseconds, at: _now());
      }
      return _fail('HTTP ${response.statusCode}');
    } on TimeoutException {
      return _fail('Timeout');
    } on HttpException catch (e) {
      return _fail(e.message.contains('503') || e.message.contains('tunnel') ? 'Failed' : _shortError(e.message));
    } on SocketException {
      return _fail('Failed');
    } on HandshakeException {
      return _fail('TLS error');
    } catch (e) {
      return _fail('Failed');
    } finally {
      client.close(force: true);
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
