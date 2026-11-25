import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/utils/quality_probes.dart';
import 'package:ir_net/utils/socks_udp.dart';

/// Probes through the VPN's local proxies (Android, where IRNet is outside
/// its own VPN). Plain `test`s: widget tests replace dart:io's networking.
void main() {
  group('UDP through SOCKS5', () {
    late ServerSocket control;
    late RawDatagramSocket relay;
    final seenTargets = <String>[];
    var refuse = false;

    setUp(() async {
      seenTargets.clear();
      refuse = false;
      relay = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      // The relay answers STUN itself, as the far side would.
      relay.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = relay.receive();
        if (d == null) return;
        final data = d.data;
        expect(data[3], 3, reason: 'names go to the proxy unresolved');
        final length = data[4];
        seenTargets.add('${ascii.decode(data.sublist(5, 5 + length))}:${data[5 + length] << 8 | data[6 + length]}');
        final stun = Uint8List.sublistView(data, 7 + length);
        final reply = Uint8List(20)..setRange(4, 20, stun.sublist(4, 20));
        ByteData.sublistView(reply).setUint16(0, 0x0101);
        relay.send([0, 0, 0, 1, 1, 2, 3, 4, 0x0d, 0x96, ...reply], d.address, d.port);
      });
      control = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      control.listen((socket) {
        final buffer = <int>[];
        var stage = 0;
        socket.listen((data) {
          buffer.addAll(data);
          if (stage == 0 && buffer.length >= 3) {
            expect(buffer.sublist(0, 3), [5, 1, 0]);
            buffer.removeRange(0, 3);
            socket.add([5, 0]);
            stage = 1;
          }
          if (stage == 1 && buffer.length >= 10) {
            expect(buffer.sublist(0, 2), [5, 3], reason: 'UDP ASSOCIATE');
            buffer.clear();
            stage = 2;
            socket.add(refuse
                ? [5, 7, 0, 1, 0, 0, 0, 0, 0, 0]
                : [5, 0, 0, 1, 127, 0, 0, 1, relay.port >> 8, relay.port & 0xff]);
          }
        });
      });
    });
    tearDown(() async {
      relay.close();
      await control.close();
    });

    test('STUN probes round-trip through the association, names resolved remotely', () async {
      final prober = StunProber(
        targets: const [StunTarget('stun.example', 3478)],
        socks: () => '127.0.0.1:${control.port}',
        lookup: (_) => fail('no local DNS through the proxy'),
      );
      addTearDown(prober.close);
      for (var i = 0; i < 3; i++) {
        expect(await prober.probe(), isNotNull);
      }
      expect(seenTargets, List.filled(3, 'stun.example:3478'));
    });

    test('a proxy that refuses UDP makes UDP unavailable, not lost', () async {
      refuse = true;
      final prober = StunProber(socks: () => '127.0.0.1:${control.port}');
      addTearDown(prober.close);
      expect(prober.probe(), throwsA(isA<ProbeUnavailable>()));
    });

    test('SOCKS UDP framing', () {
      final out = buildSocksUdp(Uint8List.fromList([9, 9]), 'a.b', 53);
      expect(out, [0, 0, 0, 3, 3, 97, 46, 98, 0, 53, 9, 9]);
      expect(buildSocksUdp(Uint8List(0), '1.2.3.4', 443), [0, 0, 0, 1, 1, 2, 3, 4, 1, 187]);
      expect(parseSocksUdp(Uint8List.fromList([0, 0, 0, 1, 1, 2, 3, 4, 0, 53, 7])), [7]);
      expect(parseSocksUdp(Uint8List.fromList([0, 0, 1, 1, 1, 2, 3, 4, 0, 53, 7])), isNull, reason: 'fragment');
    });
  });

  group('HTTPS through an HTTP proxy', () {
    late Directory dir;
    late HttpServer site;
    late ServerSocket proxy;
    final connects = <String>[];
    final auth = <String?>[];

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('irnet_tls');
      final result = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', //
        '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
        '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
        // What macOS's verifier wants of a server certificate.
        '-addext', 'basicConstraints=critical,CA:FALSE',
        '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
        '-addext', 'extendedKeyUsage=serverAuth',
      ]);
      if (result.exitCode != 0) fail('openssl: ${result.stderr}');
    });
    tearDownAll(() => dir.delete(recursive: true));

    setUp(() async {
      connects.clear();
      auth.clear();
      final tls = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      site = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
      site.listen((r) {
        r.response.statusCode = r.uri.path == '/generate_204' ? 204 : 404;
        r.response.close();
      });
      // A CONNECT-only proxy that pipes bytes both ways.
      proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((client) async {
        final head = <int>[];
        late StreamSubscription<List<int>> sub;
        Socket? upstream;
        sub = client.listen((data) async {
          if (upstream != null) {
            upstream!.add(data);
            return;
          }
          head.addAll(data);
          final text = latin1.decode(head);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          sub.pause();
          final lines = text.substring(0, end).split('\r\n');
          connects.add(lines.first);
          auth.add(lines
              .where((l) => l.toLowerCase().startsWith('proxy-authorization:'))
              .map((l) => l.substring(l.indexOf(':') + 1).trim())
              .firstOrNull);
          upstream = await Socket.connect(InternetAddress.loopbackIPv4, site.port);
          upstream!.listen(client.add, onDone: client.destroy, onError: (_) => client.destroy());
          client.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
          sub.resume();
        }, onDone: () => upstream?.destroy());
      });
    });
    tearDown(() async {
      await proxy.close();
      await site.close(force: true);
    });

    HttpsProber prober() => HttpsProber(
          urls: ['https://localhost:${site.port}/generate_204'],
          proxy: () => 'irnet:s3cret@127.0.0.1:${proxy.port}',
          tunnelContext: SecurityContext()..setTrustedCertificates('${dir.path}/cert.pem'),
        );

    test('one tunnel carries every probe, so each times one round trip', () async {
      final p = prober();
      addTearDown(p.close);
      for (var i = 0; i < 4; i++) {
        expect(await p.probe(), isNotNull);
      }
      expect(connects, ['CONNECT localhost:${site.port} HTTP/1.1']);
      expect(auth.single, 'Basic ${base64.encode(utf8.encode('irnet:s3cret'))}');
    });

    test('a connection the site closed while idle is reopened, not counted as lost', () async {
      site.idleTimeout = const Duration(milliseconds: 200);
      final p = prober();
      addTearDown(p.close);
      expect(await p.probe(), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await p.probe(), isNotNull);
      expect(connects, hasLength(2));
    });

    test('a proxy that refuses the tunnel is a failed probe', () async {
      final p = HttpsProber(
        urls: ['https://localhost:${site.port}/generate_204'],
        proxy: () => '127.0.0.1:1',
        timeout: const Duration(seconds: 2),
      );
      addTearDown(p.close);
      expect(await p.probe(), isNull);
    });
  });
}
