import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/utils/leak_checker.dart';

void main() {
  group('failure reasons', () {
    test('network errors read as what they mean', () {
      expect(LeakFailure.from(TimeoutException('x')).kind, LeakFailureKind.timeout);
      expect(LeakFailure.from(const SocketException('Failed host lookup: \'x.example\'')).kind, LeakFailureKind.dns);
      expect(LeakFailure.from(const SocketException('Connection reset by peer', osError: OSError('', 54))).kind,
          LeakFailureKind.reset);
      expect(LeakFailure.from(const SocketException('x', osError: OSError('Connection refused', 111))).kind,
          LeakFailureKind.refused);
      expect(LeakFailure.from(const SocketException('x', osError: OSError('Network is unreachable', 51))).kind,
          LeakFailureKind.network);
      expect(LeakFailure.from(const HandshakeException('CERTIFICATE_VERIFY_FAILED')).kind, LeakFailureKind.tls);
      expect(LeakFailure.from(const SocketException('x', osError: OSError('', 10054))).kind, LeakFailureKind.reset,
          reason: 'Windows codes too');
    });

    test('HTTP answers say whether the site blocks you or is just broken', () {
      final blocked = LeakFailure.http(403, 'Forbidden');
      expect(blocked.kind, LeakFailureKind.blocked);
      expect(blocked.title, 'Blocked for your location (403)');
      expect(blocked.detail, 'HTTP 403 Forbidden');
      expect(LeakFailure.http(451, '').kind, LeakFailureKind.blocked);
      expect(LeakFailure.http(404, 'Not Found').title, 'Not found (404)');
      expect(LeakFailure.http(503, '').title, 'Server error (503)');
      expect(LeakFailure.isFilterPage(Uri.parse('http://10.10.34.35/?type=Invalid')), isTrue);
      expect(LeakFailure.isFilterPage(Uri.parse('https://peyvandha.ir/')), isTrue);
      expect(LeakFailure.isFilterPage(Uri.parse('https://example.com/')), isFalse);
    });
  });

  group('LeakChecker', () {
    late HttpServer server;
    final handlers = <String, Future<void> Function(HttpRequest)>{};
    final seen = <String>[];

    setUp(() async {
      handlers.clear();
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        seen.add('${r.method} ${r.uri.path}');
        final handle = handlers[r.uri.path];
        if (handle != null) {
          await handle(r);
        } else {
          r.response.statusCode = 404;
          await r.response.close();
        }
      });
    });
    tearDown(() => server.close(force: true));

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('a site that answers is reachable, with its time', () async {
      handlers['/ok'] = (r) async => r.response.close();
      final result = await LeakChecker().check(url('/ok'));
      expect(result.ok, isTrue);
      expect(result.ms, isNotNull);
      expect(seen, ['HEAD /ok']);
    });

    test('403 means the site refuses where you appear to be', () async {
      handlers['/sanctioned'] = (r) async {
        r.response.statusCode = 403;
        await r.response.close();
      };
      final result = await LeakChecker().check(url('/sanctioned'));
      expect(result.failure!.kind, LeakFailureKind.blocked);
    });

    test('a redirect to the filtering page is caught without loading it', () async {
      handlers['/filtered'] = (r) async {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'http://10.10.34.34/?type=Invalid Site');
        await r.response.close();
      };
      final watch = Stopwatch()..start();
      final result = await LeakChecker().check(url('/filtered'));
      expect(result.failure!.kind, LeakFailureKind.filtered);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('follows ordinary redirects, and asks for one byte where HEAD is refused', () async {
      handlers['/moved'] = (r) async {
        r.response.statusCode = 301;
        r.response.headers.set('location', '/no-head');
        await r.response.close();
      };
      handlers['/no-head'] = (r) async {
        if (r.method == 'HEAD') {
          r.response.statusCode = 405;
        } else {
          expect(r.headers.value('range'), 'bytes=0-0');
          r.response.statusCode = 206;
          r.response.write('x');
        }
        await r.response.close();
      };
      final result = await LeakChecker().check(url('/moved'));
      expect(result.ok, isTrue);
      expect(seen, ['HEAD /moved', 'HEAD /no-head', 'GET /no-head']);
    });

    test('a closed port is refused; a server that never answers times out', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      expect((await LeakChecker().check('http://127.0.0.1:$port/')).failure!.kind, LeakFailureKind.refused);

      handlers['/hang'] = (r) => Completer<void>().future;
      final result = await LeakChecker(timeout: const Duration(milliseconds: 300)).check(url('/hang'));
      expect(result.failure!.kind, LeakFailureKind.timeout);
    });
  });
}
