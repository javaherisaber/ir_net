import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/delay_tester.dart';
import 'package:ir_net/v2ray/models.dart';
import 'package:ir_net/v2ray/physical_interface.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:ir_net/v2ray/xray_runner.dart';

/// Stands in for Xray: for each inbound of the tester config it serves an
/// HTTP proxy on that port that takes a CONNECT and then answers requests in
/// the tunnel the way the outbound's server would. Servers named "dead…"
/// drop the tunnel, "slow…" never answer, "warm…" take 400 ms for the first
/// request in a tunnel (the connection setup) and 15 ms after, and a config
/// containing "reject…" makes the whole core fail to start.
class FakeCore implements XrayRunner {
  final starts = <int>[];
  final configs = <Map<String, dynamic>>[];
  var tunnels = 0;

  @override
  Future<XrayInstance> start(String config, {String label = 'core'}) async {
    final json = jsonDecode(config) as Map<String, dynamic>;
    configs.add(json);
    final inbounds = (json['inbounds'] as List).cast<Map<String, dynamic>>();
    final outbounds = (json['outbounds'] as List).cast<Map<String, dynamic>>();
    starts.add(inbounds.length);
    if (config.contains('reject.example.com')) {
      throw const XrayStartException('infra/conf: failed to build outbound: unsupported thing');
    }
    final servers = <ServerSocket>[];
    for (var i = 0; i < inbounds.length; i++) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, inbounds[i]['port'] as int);
      final address = (outbounds[i]['settings']['servers'] ?? outbounds[i]['settings']['vnext'])[0]['address'] as String;
      server.listen((socket) => _serve(socket, address));
      servers.add(server);
    }
    return _FakeInstance(servers);
  }

  Future<void> _serve(Socket socket, String address) async {
    final buffer = <int>[];
    var requests = 0;
    var tunnel = false;
    socket.listen((data) async {
      buffer.addAll(data);
      while (true) {
        final text = String.fromCharCodes(buffer);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        final head = text.substring(0, end);
        buffer.removeRange(0, end + 4);
        if (!tunnel) {
          if (!head.startsWith('CONNECT ')) {
            socket.destroy();
            return;
          }
          tunnel = true;
          tunnels++;
          // Like Xray: the tunnel is "established" before the server is tried.
          socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
          continue;
        }
        requests++;
        if (address.startsWith('dead')) {
          socket.destroy();
          return;
        }
        if (address.startsWith('slow')) return;
        final ms = address.startsWith('warm')
            ? (requests == 1 ? 400 : 15)
            : (address.startsWith('far') ? 120 : 10);
        await Future<void>.delayed(Duration(milliseconds: ms));
        socket.write('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n');
      }
    }, onError: (_) {});
  }
}

class _FakeInstance implements XrayInstance {
  _FakeInstance(this.servers);
  final List<ServerSocket> servers;
  final _exited = Completer<void>();

  @override
  Future<void> get exited => _exited.future;
  @override
  bool get hasExited => _exited.isCompleted;
  @override
  String get logTail => '';
  @override
  int? get pid => null;
  @override
  String? get lastOutboundTag => null;

  @override
  Future<void> stop() async {
    for (final s in servers) {
      await s.close();
    }
    if (!_exited.isCompleted) _exited.complete();
  }
}

V2rayProfile _p(String host) => ShareLinkParser.parse('trojan://pw@$host:443#$host');

void main() {
  late HttpServer target;
  setUp(() async => target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  tearDown(() async => target.close(force: true));

  test('batches configs into one core and measures each through its own port', () async {
    final core = FakeCore();
    final tester = DelayTester(
      runner: core,
      url: 'http://127.0.0.1:${target.port}/generate_204',
      timeout: const Duration(seconds: 2),
      batchSize: 3,
    );
    final profiles = [_p('near.example.com'), _p('far.example.com'), _p('dead.example.com'), _p('slow.example.com')];
    final results = <String, DelayResult>{};
    await tester.run(
      [...profiles, ShareLinkParser.parse('vless://2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60@203.0.113.1:80#plain')],
      (id, r) => results[id] = r,
    );
    expect(core.starts, [3, 1], reason: 'four usable configs in batches of three');
    final near = results[profiles[0].id]!, far = results[profiles[1].id]!;
    expect(near.ms, isNotNull);
    expect(far.ms, greaterThanOrEqualTo(120));
    expect(near.ms, lessThan(far.ms!));
    expect(results[profiles[2].id]!.ok, isFalse);
    expect(results[profiles[2].id]!.error, isNot('Timeout'), reason: 'a dropped connection is a failure, not a timeout');
    expect(results[profiles[3].id]!.error, 'Timeout');
    expect(results.values.where((r) => r.error == 'Not supported'), hasLength(1), reason: 'the plain VLESS one');
  });

  test('a config the core rejects fails alone; the rest of its batch still runs', () async {
    final core = FakeCore();
    final tester = DelayTester(
      runner: core,
      url: 'http://127.0.0.1:${target.port}/generate_204',
      timeout: const Duration(seconds: 2),
    );
    final good = _p('near.example.com'), bad = _p('reject.example.com');
    final results = <String, DelayResult>{};
    await tester.run([good, bad], (id, r) => results[id] = r);
    expect(core.starts, [2, 1, 1], reason: 'the batch, then each on its own');
    expect(results[good.id]!.ms, isNotNull);
    expect(results[bad.id]!.error, 'infra/conf: failed to build outbound: unsupported thing');
  });

  test('reports the round trip over an open connection, not the connection setup', () async {
    final core = FakeCore();
    final tester = DelayTester(
      runner: core,
      url: 'http://127.0.0.1:${target.port}/generate_204',
      timeout: const Duration(seconds: 3),
    );
    final p = _p('warm.example.com');
    final results = <String, DelayResult>{};
    await tester.run([p], (id, r) => results[id] = r);
    expect(results[p.id]!.ms, lessThan(200), reason: 'the 400 ms opening is not the ping');
    expect(core.tunnels, 1, reason: 'both requests share one tunnel');
  });

  test('in Tunnel mode each test leaves by the physical interface, not through the VPN', () async {
    final core = FakeCore();
    final wg = ShareLinkParser.parse('wireguard://yAnz5TF%2BlXXJte14tji3zlMNq%2Bhd2rYUIgJBgB3fBmk%3D@'
        'engage.example.com:2408?publickey=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg%3D&address=172.16.0.2%2F32#wg');
    final config = XrayConfigBuilder.tester([
      (profile: ShareLinkParser.parse('vless://2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60@a.example.com:443?type=ws&security=tls&path=%2Fx#a'), port: 1),
      (profile: wg, port: 2),
    ], bindInterface: 'en0');
    final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
    expect(outbounds[0]['streamSettings']['network'], 'ws', reason: 'the transport is kept');
    expect(outbounds[0]['streamSettings']['sockopt'], {'interface': 'en0'});
    expect(outbounds[1]['streamSettings'], {'sockopt': {'interface': 'en0'}});
    expect(outbounds.last, {'tag': 'direct', 'protocol': 'freedom'});

    final plain = XrayConfigBuilder.tester([(profile: _p('near.example.com'), port: 1)]);
    expect(((plain['outbounds'] as List).first as Map)['streamSettings'], isNot(contains('sockopt')));

    await DelayTester(runner: core, url: 'http://127.0.0.1:${target.port}/', bindInterface: 'Wi-Fi')
        .run([_p('near.example.com')], (_, __) {});
    expect(((core.configs.single['outbounds'] as List).first as Map)['streamSettings']['sockopt'],
        {'interface': 'Wi-Fi'});
  });

  test('finds the physical interface behind a VPN tunnel', () {
    const netstat = '''
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            link#24            UCSIg               utun4
default            192.168.1.1        UGScg                 en0
127                127.0.0.1          UCS                   lo0
''';
    expect(PhysicalInterface.parseNetstat(netstat), 'en0');
    expect(PhysicalInterface.parseNetstat('default  link#24  UCSIg  utun4\n'), isNull);
    expect(
      PhysicalInterface.parseIpRoute('default dev irnet0 scope link\n'
          'default via 192.168.1.1 dev wlp2s0 proto dhcp src 192.168.1.5 metric 600\n'),
      'wlp2s0',
    );
  });

  test('without a core it falls back to a TCP connect', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    listener.listen((s) => s.destroy());
    // (127.0.0.1 itself reads as a provider's info entry, so use the name.)
    final p = ShareLinkParser.parse('trojan://pw@localhost:${listener.port}#local');
    final results = <String, DelayResult>{};
    await DelayTester(runner: null).run([p], (id, r) => results[id] = r);
    expect(results[p.id]!.ok, isTrue);
    await listener.close();
  });
}
