// Exercises the real probe implementations against local servers: a fake
// STUN responder on a UDP socket and a tiny HTTP server.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/utils/quality_probes.dart';

/// Answers STUN binding requests, except the ones [drop] says to ignore.
class FakeStunServer {
  FakeStunServer._(this.socket);

  final RawDatagramSocket socket;
  int received = 0;
  bool Function(int index) drop = (_) => false;
  Duration delay = Duration.zero;

  static Future<FakeStunServer> start() async {
    final server = FakeStunServer._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    server.socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = server.socket.receive();
      if (d == null) return;
      final index = server.received++;
      if (server.drop(index)) return;
      final response = Uint8List.fromList(d.data);
      response[0] = 0x01; // 0x0101 Binding Success Response
      response[1] = 0x01;
      Future.delayed(server.delay, () => server.socket.send(response, d.address, d.port));
    });
    return server;
  }

  int get port => socket.port;
  void close() => socket.close();
}

void main() {
  group('STUN messages', () {
    test('binding request has the RFC 5389 header', () {
      final id = Uint8List.fromList(List.generate(12, (i) => i + 1));
      final req = buildStunBindingRequest(id);
      expect(req.length, 20);
      expect(req.sublist(0, 4), [0x00, 0x01, 0x00, 0x00]);
      expect(req.sublist(4, 8), [0x21, 0x12, 0xA4, 0x42]);
      expect(req.sublist(8), id);
    });

    test('accepts success and error responses, rejects anything else', () {
      final id = Uint8List.fromList(List.filled(12, 7));
      final ok = buildStunBindingRequest(id)..[0] = 0x01..[1] = 0x01;
      expect(stunResponseTransactionId(ok), id);

      final error = buildStunBindingRequest(id)..[0] = 0x01..[1] = 0x11;
      expect(stunResponseTransactionId(error), id);

      expect(stunResponseTransactionId(buildStunBindingRequest(id)), isNull,
          reason: 'a request is not a response');
      final badCookie = Uint8List.fromList(ok)..[4] = 0;
      expect(stunResponseTransactionId(badCookie), isNull);
      expect(stunResponseTransactionId(Uint8List(10)), isNull);
      final truncated = Uint8List.fromList(ok)..[3] = 12; // claims 12 attribute bytes
      expect(stunResponseTransactionId(truncated), isNull);
    });
  });

  group('StunProber', () {
    late FakeStunServer server;

    setUp(() async => server = await FakeStunServer.start());
    tearDown(() => server.close());

    StunProber prober({List<StunTarget>? targets, Duration timeout = const Duration(milliseconds: 300)}) =>
        StunProber(
          targets: targets ?? [StunTarget('stun.test', server.port)],
          timeout: timeout,
          lookup: (_) async => [InternetAddress.loopbackIPv4],
        );

    test('measures the round trip of a reply', () async {
      server.delay = const Duration(milliseconds: 40);
      final p = prober();
      final rtt = await p.probe();
      expect(rtt, isNotNull);
      expect(rtt!, greaterThanOrEqualTo(35));
      expect(rtt, lessThan(300));
      p.close();
    });

    test('a probe without reply is lost (null) after the timeout', () async {
      server.drop = (i) => i == 1;
      final p = prober();
      expect(await p.probe(), isNotNull);
      final watch = Stopwatch()..start();
      expect(await p.probe(), isNull);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
      expect(await p.probe(), isNotNull);
      p.close();
    });

    test('a late reply does not count for the next probe', () async {
      server.delay = const Duration(milliseconds: 400);
      final p = prober(timeout: const Duration(milliseconds: 200));
      expect(await p.probe(), isNull);
      server.delay = Duration.zero;
      // The first reply arrives while this probe waits; it must be ignored.
      final rtt = await p.probe();
      expect(rtt, isNotNull);
      expect(rtt!, lessThan(150));
      p.close();
    });

    test('keeps one socket (stable source port) across probes', () async {
      final ports = <int>{};
      server.socket.close();
      final echo = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((e) {
        final d = echo.receive();
        if (d == null) return;
        ports.add(d.port);
        echo.send(Uint8List.fromList(d.data)..[0] = 1..[1] = 1, d.address, d.port);
      });
      final p = StunProber(
        targets: [StunTarget('stun.test', echo.port)],
        lookup: (_) async => [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 300),
      );
      for (var i = 0; i < 3; i++) {
        expect(await p.probe(), isNotNull);
      }
      expect(ports, hasLength(1));
      p.reset();
      expect(await p.probe(), isNotNull);
      expect(ports, hasLength(2), reason: 'reset() opens a new socket');
      p.close();
      echo.close();
    });

    test('rotates to the next server after repeated losses', () async {
      final dead = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0); // never answers
      final p = prober(
        targets: [StunTarget('dead.test', dead.port), StunTarget('live.test', server.port)],
        timeout: const Duration(milliseconds: 50),
      );
      for (var i = 0; i < StunProber.rotateAfterLosses; i++) {
        expect(await p.probe(), isNull);
      }
      expect(p.currentTarget.host, 'live.test');
      expect(await p.probe(), isNotNull);
      p.close();
      dead.close();
    });

    test('an unresolvable host is a lost probe, not an exception', () async {
      final p = StunProber(
        targets: const [StunTarget('nowhere.invalid', 3478)],
        lookup: (_) async => throw const SocketException('no such host'),
        timeout: const Duration(milliseconds: 100),
      );
      expect(await p.probe(), isNull);
      p.close();
    });
  });

  group('HttpsProber', () {
    late HttpServer server;
    final ports = <int>[];
    var status = 204;
    var hang = false;

    setUp(() async {
      ports.clear();
      status = 204;
      hang = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        ports.add(req.connectionInfo!.remotePort);
        if (hang) return; // never respond
        req.response.statusCode = status;
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    HttpsProber prober({Duration timeout = const Duration(seconds: 2)}) => HttpsProber(
          urls: ['http://127.0.0.1:${server.port}/generate_204'],
          timeout: timeout,
        );

    test('repeats the request on a fresh connection, then reuses it', () async {
      final p = prober();
      expect(await p.probe(), isNotNull);
      expect(ports, hasLength(2), reason: 'cold request + timed warm request');
      expect(ports.toSet(), hasLength(1), reason: 'same keep-alive connection');
      expect(await p.probe(), isNotNull);
      expect(ports, hasLength(3), reason: 'warm connection: a single request');
      p.close();
    });

    test('non-2xx answers count as failures', () async {
      status = 503;
      final p = prober();
      expect(await p.probe(), isNull);
      p.close();
    });

    test('a request that never completes fails after the timeout', () async {
      hang = true;
      final p = prober(timeout: const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      expect(await p.probe(), isNull);
      expect(watch.elapsedMilliseconds, lessThan(2000));
      hang = false;
      expect(await p.probe(), isNotNull, reason: 'recovers on a new connection');
      p.close();
    });

    test('connection refused is a failure, not an exception', () async {
      final p = HttpsProber(urls: ['http://127.0.0.1:1/generate_204'], timeout: const Duration(seconds: 1));
      expect(await p.probe(), isNull);
      p.close();
    });
  });
}
