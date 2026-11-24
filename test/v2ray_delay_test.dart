import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/delay_tester.dart';
import 'package:ir_net/v2ray/models.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/xray_runner.dart';

/// Stands in for Xray: for each inbound of the tester config it serves an
/// HTTP proxy on that port that behaves like the outbound's server would.
/// Servers named "dead…" drop the request, "slow…" never answer, and a
/// config containing "reject…" makes the whole core fail to start.
class FakeCore implements XrayRunner {
  final starts = <int>[];

  @override
  Future<XrayInstance> start(String config, {String label = 'core'}) async {
    final json = jsonDecode(config) as Map<String, dynamic>;
    final inbounds = (json['inbounds'] as List).cast<Map<String, dynamic>>();
    final outbounds = (json['outbounds'] as List).cast<Map<String, dynamic>>();
    starts.add(inbounds.length);
    if (config.contains('reject.example.com')) {
      throw const XrayStartException('infra/conf: failed to build outbound: unsupported thing');
    }
    final servers = <HttpServer>[];
    for (var i = 0; i < inbounds.length; i++) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, inbounds[i]['port'] as int);
      final address = (outbounds[i]['settings']['servers'] ?? outbounds[i]['settings']['vnext'])[0]['address'] as String;
      server.listen((request) async {
        if (address.startsWith('dead')) {
          await request.response.detachSocket().then((s) => s.destroy());
        } else if (address.startsWith('slow')) {
          await Future<void>.delayed(const Duration(seconds: 5));
        } else {
          await Future<void>.delayed(Duration(milliseconds: address.startsWith('far') ? 120 : 10));
          request.response.statusCode = 204;
          await request.response.close();
        }
      });
      servers.add(server);
    }
    return _FakeInstance(servers);
  }
}

class _FakeInstance implements XrayInstance {
  _FakeInstance(this.servers);
  final List<HttpServer> servers;
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
      await s.close(force: true);
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
