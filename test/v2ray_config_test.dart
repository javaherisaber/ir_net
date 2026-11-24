import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/models.dart';
import 'package:ir_net/v2ray/routing_rules.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/xray_config.dart';

const _uuid = '2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60';
const _pbk = 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw';

String _vmess(Map<String, dynamic> json) => 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';

void main() {
  group('ShareLinkParser', () {
    test('reads a VLESS REALITY link with vision flow', () {
      final p = ShareLinkParser.parse(
          'vless://$_uuid@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality'
          '&sni=www.speedtest.net&fp=firefox&pbk=$_pbk&sid=6ba85179e30d4fc2&spx=%2Fsearch&type=tcp'
          '#%F0%9F%87%A9%F0%9F%87%AA%20Germany%201');
      expect(p.protocol, V2rayProtocol.vless);
      expect(p.name, '🇩🇪 Germany 1');
      expect(p.address, '203.0.113.10');
      expect(p.port, 443);
      expect(p.credential, _uuid);
      expect(p.flow, 'xtls-rprx-vision');
      expect(p.stream.network, 'raw');
      expect(p.stream.security, 'reality');
      expect(p.stream.publicKey, _pbk);
      expect(p.stream.shortId, '6ba85179e30d4fc2');
      expect(p.stream.spiderX, '/search');
      expect(p.problem, isNull);

      final out = XrayConfigBuilder.outbound(p);
      final user = out['settings']['vnext'][0]['users'][0];
      expect(user['id'], _uuid);
      expect(user['encryption'], 'none');
      expect(user['flow'], 'xtls-rprx-vision');
      final rs = out['streamSettings']['realitySettings'];
      expect(rs, {
        'serverName': 'www.speedtest.net',
        'fingerprint': 'firefox',
        'publicKey': _pbk,
        'shortId': '6ba85179e30d4fc2',
        'spiderX': '/search',
      });
    });

    test('reads VLESS over WebSocket + TLS with SNI falling back to host', () {
      final p = ShareLinkParser.parse(
          'vless://$_uuid@cdn.example.com:2083?type=ws&security=tls&host=edge.example.org'
          '&path=%2Fws%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&fp=chrome#WS%20TLS');
      expect(p.stream.network, 'ws');
      expect(p.stream.path, '/ws?ed=2048');
      final ss = XrayConfigBuilder.streamSettings(p);
      expect(ss['wsSettings'], {'path': '/ws?ed=2048', 'host': 'edge.example.org'});
      expect(ss['tlsSettings'], {
        'serverName': 'edge.example.org',
        'alpn': ['h2', 'http/1.1'],
        'fingerprint': 'chrome',
      });
    });

    test('reads XHTTP with mode and extra JSON', () {
      final extra = Uri.encodeComponent('{"xPaddingBytes":"100-1000","xmux":{"maxConcurrency":"16-32"}}');
      final p = ShareLinkParser.parse('vless://$_uuid@example.com:443?type=xhttp&security=tls&sni=example.com'
          '&path=%2Fxh&mode=packet-up&extra=$extra#xh');
      final xs = XrayConfigBuilder.streamSettings(p)['xhttpSettings'];
      expect(xs['path'], '/xh');
      expect(xs['mode'], 'packet-up');
      expect(xs['extra'], {
        'xPaddingBytes': '100-1000',
        'xmux': {'maxConcurrency': '16-32'},
      });
    });

    test('reads gRPC multi mode', () {
      final p = ShareLinkParser.parse(
          'vless://$_uuid@example.com:443?type=grpc&serviceName=svc&mode=multi&security=reality&pbk=$_pbk&sid=ab#g');
      expect(XrayConfigBuilder.streamSettings(p)['grpcSettings'], {'serviceName': 'svc', 'multiMode': true});
    });

    test('reads a base64 VMess link (v2rayN JSON)', () {
      final p = ShareLinkParser.parse(_vmess({
        'v': '2',
        'ps': 'NL vmess',
        'add': 'nl.example.com',
        'port': '8443',
        'id': _uuid,
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'type': 'none',
        'host': 'nl.example.com',
        'path': '/vm',
        'tls': 'tls',
        'sni': '',
        'fp': 'chrome',
      }));
      expect(p.protocol, V2rayProtocol.vmess);
      expect(p.name, 'NL vmess');
      expect(p.port, 8443);
      expect(p.problem, isNull);
      final out = XrayConfigBuilder.outbound(p);
      expect(out['protocol'], 'vmess');
      expect(out['settings']['vnext'][0]['users'][0], {'id': _uuid, 'security': 'auto', 'level': 8});
      expect(out['streamSettings']['tlsSettings']['serverName'], 'nl.example.com');
    });

    test('reads VMess gRPC: serviceName is carried in path, mode in type', () {
      final p = ShareLinkParser.parse(_vmess({
        'add': '198.51.100.7',
        'port': 443,
        'id': _uuid,
        'net': 'grpc',
        'type': 'multi',
        'path': 'grpcsvc',
        'tls': 'tls',
        'sni': 'g.example.com',
      }));
      expect(p.stream.serviceName, 'grpcsvc');
      expect(p.stream.mode, 'multi');
    });

    test('accepts URL-safe base64 without padding', () {
      final json = jsonEncode({'add': 'a.example.com', 'port': '443', 'id': _uuid, 'net': 'tcp', 'tls': 'tls'});
      final b64 = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
      expect(ShareLinkParser.parse('vmess://$b64').address, 'a.example.com');
    });

    test('Trojan defaults to TLS and keeps an encoded password', () {
      final p = ShareLinkParser.parse('trojan://p%40ss%3Aword@tr.example.com:443?sni=tr.example.com#Trojan');
      expect(p.protocol, V2rayProtocol.trojan);
      expect(p.credential, 'p@ss:word');
      expect(p.stream.security, 'tls');
      final out = XrayConfigBuilder.outbound(p);
      expect(out['settings']['servers'][0]['password'], 'p@ss:word');
    });

    test('reads IPv6 hosts in brackets', () {
      final p = ShareLinkParser.parse('vless://$_uuid@[2001:db8::1]:443?security=tls&sni=v6.example.com');
      expect(p.address, '2001:db8::1');
      expect(p.endpoint, '[2001:db8::1]:443');
      expect(p.name, '[2001:db8::1]:443');
    });

    test('flags configs the core refuses instead of failing', () {
      final plain = ShareLinkParser.parse('vless://$_uuid@203.0.113.5:80?type=ws&security=none#plain');
      expect(plain.problem, contains('no TLS'));
      expect(() => XrayConfigBuilder.outbound(plain), throwsStateError);

      final lan = ShareLinkParser.parse('vless://$_uuid@192.168.1.10:80?type=ws#lan');
      expect(lan.problem, isNull);

      final h2 = ShareLinkParser.parse('vless://$_uuid@example.com:443?type=h2&security=tls');
      expect(h2.problem, contains('HTTP/2'));

      final ws = ShareLinkParser.parse('vless://$_uuid@example.com:443?type=ws&security=reality&pbk=$_pbk');
      expect(ws.problem, contains('REALITY'));

      // VMess has its own encryption, so plain transport is allowed.
      final vm = ShareLinkParser.parse(_vmess({'add': 'example.com', 'port': 80, 'id': _uuid, 'net': 'ws'}));
      expect(vm.problem, isNull);
    });

    test('drops allowInsecure but remembers it was asked for', () {
      final p = ShareLinkParser.parse('trojan://pw@example.com:443?security=tls&allowInsecure=1');
      expect(p.stream.insecure, isTrue);
      expect(XrayConfigBuilder.streamSettings(p)['tlsSettings'].containsKey('allowInsecure'), isFalse);
    });

    test('rejects links it cannot read', () {
      expect(() => ShareLinkParser.parse('vless://example.com:443'), throwsA(isA<ShareLinkException>()));
      expect(() => ShareLinkParser.parse('vless://$_uuid@example.com:99999'), throwsA(isA<ShareLinkException>()));
      expect(() => ShareLinkParser.parse('vmess://not-json!'), throwsA(isA<ShareLinkException>()));
      expect(() => ShareLinkParser.parse('ss://abc@host:1'), throwsA(isA<ShareLinkException>()));
    });

    test('ids are stable per link and subscription', () {
      const link = 'trojan://pw@example.com:443';
      expect(ShareLinkParser.parse(link).id, ShareLinkParser.parse(link).id);
      expect(ShareLinkParser.parse(link).id, isNot(ShareLinkParser.parse(link, subscriptionId: 's1').id));
    });

    test('parseText handles base64 blobs, mixed protocols and duplicates', () {
      final links = [
        'vless://$_uuid@a.example.com:443?security=tls#A',
        'ss://YWVzLTI1Ni1nY206cGFzcw@b.example.com:8388#SS',
        'trojan://pw@c.example.com:443#C',
        'trojan://pw@c.example.com:443#C',
        'vless://broken',
      ].join('\n');
      final result = ShareLinkParser.parseText(base64.encode(utf8.encode(links)));
      expect(result.profiles.map((p) => p.name), ['A', 'C']);
      expect(result.unsupported, 1);
      expect(result.errors, hasLength(1));
    });

    test('normalises query keys and HTML-escaped ampersands', () {
      final p = ShareLinkParser.parse('trojan://pw@example.com:443?security=tls&amp;allow_insecure=1&amp;service-name=x');
      expect(p.stream.insecure, isTrue);
    });

    test('marks provider info entries instead of listing them as servers', () {
      final p = ShareLinkParser.parse('vless://$_uuid@0.0.0.0:1?security=none#%F0%9F%94%8B%20Remaining%2012%20GB');
      expect(p.name, '🔋 Remaining 12 GB');
      expect(p.problem, ShareLinkParser.infoEntryProblem);
    });

    test('ignores zero-width characters messengers insert', () {
      final p = ShareLinkParser.parse('​trojan://pw@example.com:443#Z​');
      expect(p.name, 'Z');
    });
  });

  group('XrayConfigBuilder', () {
    final profile = ShareLinkParser.parse('trojan://pw@example.com:443?sni=example.com#T');

    test('connection config has SOCKS + HTTP inbounds and LAN bypass', () {
      final compiled = PassThroughRules.compile(['*.ir', '1.2.3.4', '5.6.0.0/16', 'https://bank.example/x'], const []);
      final c = XrayConfigBuilder.connection(profile, socksPort: 10808, httpPort: 10809, rules: compiled);
      final inbounds = c['inbounds'] as List;
      expect(inbounds.map((i) => (i['protocol'], i['port'], i['listen'])),
          [('socks', 10808, '127.0.0.1'), ('http', 10809, '127.0.0.1')]);
      expect((c['outbounds'] as List).map((o) => o['tag']), ['proxy', 'direct', 'block']);
      final rules = c['routing']['rules'] as List;
      expect(rules[0]['ip'], contains('192.168.0.0/16'));
      expect(rules[1]['domain'], contains('domain:local'));
      expect(rules[2]['domain'], ['domain:ir', 'domain:bank.example']);
      expect(rules[3]['ip'], ['1.2.3.4', '5.6.0.0/16']);
      expect(c['routing']['domainStrategy'], 'IPIfNonMatch');
      expect(c['dns']['servers'], everyElement(isA<String>()));
      jsonEncode(c); // serialisable
    });

    test('without LAN bypass there are no direct rules', () {
      final c = XrayConfigBuilder.connection(profile, socksPort: 1, httpPort: 2, bypassLan: false);
      expect(c['routing']['rules'], isEmpty);
      expect(c['routing']['domainStrategy'], 'AsIs');
    });

    test('HTTP inbound gets credentials when asked', () {
      final c = XrayConfigBuilder.connection(profile,
          socksPort: 1, httpPort: 2, httpAuth: (user: 'u', pass: 'p'));
      expect(c['inbounds'][1]['settings'], {
        'accounts': [
          {'user': 'u', 'pass': 'p'}
        ]
      });
    });

    test('tester routes each inbound to its own outbound', () {
      final other = ShareLinkParser.parse('trojan://pw@other.example.com:443#O');
      final c = XrayConfigBuilder.tester([(profile: profile, port: 20001), (profile: other, port: 20002)]);
      expect((c['inbounds'] as List).map((i) => i['port']), [20001, 20002]);
      expect((c['outbounds'] as List).map((o) => o['tag']), ['out0', 'out1', 'direct']);
      expect(c['routing']['rules'][1], {
        'inboundTag': ['in1'],
        'outboundTag': 'out1'
      });
    });


    test('ipv4RoutesExcluding covers everything except the LAN', () {
      final routes = XrayConfigBuilder.ipv4RoutesExcluding(
          ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16']);
      expect(routes, contains('0.0.0.0/5'));
      expect(routes, contains('11.0.0.0/8'));
      expect(routes, contains('172.32.0.0/11'));
      expect(routes, isNot(contains('10.0.0.0/8')));
      // Address count adds up to 2^32 minus the excluded ranges.
      var covered = 0;
      for (final r in routes) {
        final bits = int.parse(r.split('/')[1]);
        covered += 1 << (32 - bits);
      }
      const excluded = (1 << 24) + (1 << 20) + (1 << 16) + (1 << 24) + (1 << 16);
      expect(covered, (1 << 32) - excluded);
      expect(XrayConfigBuilder.ipv4RoutesExcluding(const []), ['0.0.0.0/0']);
    });
  });
}
