import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ir_net/v2ray/geo_assets.dart';
import 'package:ir_net/v2ray/routing_rules.dart';
import 'package:ir_net/v2ray/subscription.dart';
import 'package:ir_net/v2ray/system_proxy.dart';
import 'package:ir_net/v2ray/vpn_engine.dart';
import 'package:ir_net/v2ray_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/v2ray_fakes.dart';

// ───────────────────── tiny protobuf writer for .dat fixtures ─────────────────────

List<int> _varint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _field(int number, List<int> payload) => [..._varint(number << 3 | 2), ..._varint(payload.length), ...payload];

/// GeoIPList { GeoIP { code, CIDR { ip, prefix } } }
Uint8List _geoip(Map<String, List<int>> codes) => Uint8List.fromList([
      for (final e in codes.entries)
        ..._field(1, [
          ..._field(1, utf8.encode(e.key)),
          ..._field(2, [..._field(1, e.value), 0x10, 8]),
        ]),
    ]);

/// GeoSiteList { GeoSite { code, Domain { type, value } } }
Uint8List _geosite(Map<String, String> codes, {bool plainType = false}) => Uint8List.fromList([
      for (final e in codes.entries)
        ..._field(1, [
          ..._field(1, utf8.encode(e.key)),
          ..._field(2, [if (!plainType) ...[0x08, 2], ..._field(2, utf8.encode(e.value))]),
        ]),
    ]);

GeoAsset _asset(String file, GeoKind kind, List<String> tags) =>
    GeoAsset(fileName: file, kind: kind, size: 1, tags: tags, importedAt: 0);

// ───────────────────────────── fakes ─────────────────────────────

class FakeCommands {
  final calls = <List<String>>[];
  final Map<String, String> outputs = {};
  bool Function(List<String>)? deny;

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    if (deny != null && deny!([exe, ...args])) {
      return ProcessResult(0, 0, '** Error: Command requires admin privileges.', '');
    }
    return ProcessResult(0, 0, outputs[args.join(' ')] ?? '', '');
  }
}

const _uuid = '2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60';

void main() {
  group('geo .dat files', () {
    test('tells GeoIP from GeoSite and lists tags', () {
      final ip = inspectGeoFile(_geoip({'IR': [5, 0, 0, 0], 'CN': [1, 0, 0, 0]}))!;
      expect(ip.kind, GeoKind.ip);
      expect(ip.tags, ['cn', 'ir']);

      final site = inspectGeoFile(_geosite({'CATEGORY-IR': 'digikala.com', 'GOOGLE': 'google.com'}))!;
      expect(site.kind, GeoKind.site);
      expect(site.tags, ['category-ir', 'google']);

      // Plain-type domains omit the type field and start with the value.
      expect(inspectGeoFile(_geosite({'X': 'x.com'}, plainType: true))!.kind, GeoKind.site);
    });

    test('rejects files that are not geo lists', () {
      expect(inspectGeoFile(Uint8List.fromList(utf8.encode('hello world'))), isNull);
      expect(inspectGeoFile(Uint8List(0)), isNull);
      expect(inspectGeoFile(Uint8List.fromList([0x0a, 0x50, 1, 2])), isNull); // truncated
    });

    test('file names are made safe for ext: rules', () {
      expect(sanitizeGeoFileName('/tmp/Iran Rules.DAT'), 'iran_rules.dat');
      expect(sanitizeGeoFileName(r'C:\x\geoip'), 'geoip.dat');
    });

    test('rule for a tag uses the right prefix', () {
      expect(_asset('geoip.dat', GeoKind.ip, ['ir']).ruleFor('IR'), 'geoip:ir');
      expect(_asset('geosite.dat', GeoKind.site, ['x']).ruleFor('x'), 'geosite:x');
      expect(_asset('iran.dat', GeoKind.site, ['ir']).ruleFor('ir'), 'ext:iran.dat:ir');
    });
  });

  group('pass-through rules', () {
    final assets = [
      _asset('geoip.dat', GeoKind.ip, ['ir', 'private']),
      _asset('geosite.dat', GeoKind.site, ['category-ir', 'google']),
      _asset('iran.dat', GeoKind.site, ['ir', 'ads']),
      _asset('ipiran.dat', GeoKind.ip, ['ir']),
    ];

    test('compiles each kind of rule', () {
      final r = PassThroughRules.compile([
        '# comment',
        'geosite:category-ir',
        'GeoIP:IR',
        'ext:iran.dat:ir',
        'ext:ipiran.dat:ir',
        'example.com',
        '*.bank.ir',
        'full:www.exact.com',
        'keyword:shaparak',
        r'regexp:\.ir$',
        '192.168.50.0/24',
        '1.2.3.4',
        'geosite:google@cn',
      ], assets);
      expect(r.issues, isEmpty);
      expect(r.domains, [
        'geosite:category-ir',
        'ext:iran.dat:ir',
        'domain:example.com',
        'domain:bank.ir',
        'full:www.exact.com',
        'keyword:shaparak',
        r'regexp:\.ir$',
        'geosite:google@cn',
      ]);
      expect(r.ips, ['geoip:ir', 'ext:ipiran.dat:ir', '192.168.50.0/24', '1.2.3.4']);
      expect(r.osDomains, ['example.com', 'bank.ir']);
      expect(r.osIps, ['192.168.50.0/24', '1.2.3.4']);
    });

    test('reports rules it has to leave out', () {
      final r = PassThroughRules.compile([
        'geosite:nope',
        'geoip:',
        'ext:missing.dat:ir',
        'ext:iran.dat',
        'regexp:(',
        'not a rule!',
      ], assets);
      expect(r.domains, isEmpty);
      expect(r.ips, isEmpty);
      expect(r.issues.map((i) => i.message), [
        '"nope" is not in geosite.dat',
        'Missing a tag after "geoip:"',
        'Import missing.dat to use this rule',
        'Write it as ext:<file>.dat:<tag>',
        'Not a valid regular expression',
        'Not a domain, IP range or geo rule',
      ]);
      expect(PassThroughRules.compile(['geoip:ir'], const []).issues.single.message, 'Import geoip.dat to use this rule');
    });
  });

  group('subscriptions', () {
    test('reads userinfo, title and directives in the body', () {
      final body = base64.encode(utf8.encode([
        '#profile-title: base64:${base64.encode(utf8.encode('My VPN 🚀'))}',
        '//profile-update-interval: 6',
        '#announce: Renew before Friday',
        'vless://$_uuid@a.example.com:443?security=tls#A',
        'trojan://pw@b.example.com:443#B',
      ].join('\n')));
      final r = SubscriptionClient.parse(body, {
        'subscription-userinfo': 'upload=1073741824; download=2147483648; total=10737418240; expire=1767225600',
        'support-url': 'https://t.me/support',
      }, url: 'https://sub.example.com/abc', subscriptionId: 's1');
      expect(r.links.profiles.map((p) => p.name), ['A', 'B']);
      expect(r.links.profiles.every((p) => p.subscriptionId == 's1'), isTrue);
      expect(r.meta.title, 'My VPN 🚀');
      expect(r.meta.updateIntervalHours, 6);
      expect(r.meta.announce, 'Renew before Friday');
      expect(r.meta.supportUrl, 'https://t.me/support');
      final u = r.meta.usage!;
      expect(u.used, 3 * 1024 * 1024 * 1024);
      expect(u.remaining, 7 * 1024 * 1024 * 1024);
      expect(u.remainingFraction, closeTo(0.7, 1e-9));
      expect(u.expiresAt, DateTime.fromMillisecondsSinceEpoch(1767225600 * 1000));
    });

    test('total=0 is unlimited and expire=0 never expires', () {
      final u = SubscriptionClient.parseUserInfo('upload=5;download=6;total=0;expire=0')!;
      expect(u.isUnlimited, isTrue);
      expect(u.expire, isNull);
      expect(u.timeLeft(DateTime.now()), isNull);
    });

    test('headers win over body directives; filename* names it', () {
      final meta = SubscriptionClient.parseMeta(
        {'content-disposition': "attachment; filename*=UTF-8''%D8%B3%D8%B1%D9%88%DB%8C%D8%B3"},
        '#profile-title: body title',
      );
      expect(meta.title, 'body title');
      final meta2 = SubscriptionClient.parseMeta(
        {'profile-title': 'Header', 'content-disposition': 'attachment; filename="x"'},
        '#profile-title: body title',
      );
      expect(meta2.title, 'Header');
      expect(SubscriptionClient.parseMeta(
        {'content-disposition': "attachment; filename*=UTF-8''%D8%B3%D8%B1%D9%88%DB%8C%D8%B3"},
        '',
      ).title, 'سرویس');
    });

    test('explains bodies it cannot use', () {
      expect(() => SubscriptionClient.parse('<!DOCTYPE html><html></html>', {}, url: 'u', subscriptionId: 's'),
          throwsA(isA<SubscriptionException>().having((e) => e.message, 'message', contains('web page'))));
      expect(() => SubscriptionClient.parse('{"outbounds":[]}', {}, url: 'u', subscriptionId: 's'),
          throwsA(isA<SubscriptionException>().having((e) => e.message, 'message', contains('JSON'))));
      expect(() => SubscriptionClient.parse('ss://abc@h:1#x', {}, url: 'u', subscriptionId: 's'),
          throwsA(isA<SubscriptionException>().having((e) => e.message, 'message', contains('no VLESS'))));
    });

    test('fetch sends a links-format User-Agent and reports HTTP errors', () async {
      String? agent;
      final ok = SubscriptionClient(httpClient: () => MockClient((req) async {
            agent = req.headers['User-Agent'];
            return http.Response('trojan://pw@b.example.com:443#B', 200);
          }));
      final r = await ok.fetch('https://sub.example.com/x', subscriptionId: 's');
      expect(r.links.profiles, hasLength(1));
      expect(agent, startsWith('v2rayN/'));

      final bad = SubscriptionClient(httpClient: () => MockClient((_) async => http.Response('no', 403)));
      expect(bad.fetch('https://sub.example.com/x', subscriptionId: 's'),
          throwsA(isA<SubscriptionException>().having((e) => e.message, 'message', contains('403'))));
      expect(bad.fetch('ftp://x', subscriptionId: 's'), throwsA(isA<SubscriptionException>()));
    });
  });

  group('import deep links', () {
    test('recognises other clients\' subscription links', () {
      expect(V2rayBloc.subscriptionLinkOf('https://sub.example.com/a?b=1'),
          (url: 'https://sub.example.com/a?b=1', name: null));
      expect(V2rayBloc.subscriptionLinkOf('hiddify://import/https://sub.example.com/a#My%20Sub'),
          (url: 'https://sub.example.com/a', name: 'My Sub'));
      expect(V2rayBloc.subscriptionLinkOf('v2box://install-sub?url=https%3A%2F%2Fsub.example.com%2Fa&name=Work'),
          (url: 'https://sub.example.com/a', name: 'Work'));
      expect(V2rayBloc.subscriptionLinkOf('happ://add/https://sub.example.com/a'),
          (url: 'https://sub.example.com/a', name: null));
      expect(V2rayBloc.subscriptionLinkOf('vless://$_uuid@a.example.com:443'), isNull);
      expect(V2rayBloc.subscriptionLinkOf('just text'), isNull);
    });
  });

  group('system proxy commands', () {
    const order = '''
An asterisk (*) denotes that a network service is disabled.
(1) USB 10/100/1000 LAN
(Hardware Port: USB 10/100/1000 LAN, Device: en7)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(3) V2BOX
(Hardware Port: com.v2box, Device: )

(*) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)
''';

    test('macOS picks enabled hardware services only', () {
      expect(MacSystemProxy.parseServices(order), ['USB 10/100/1000 LAN', 'Wi-Fi']);
    });

    test('macOS sets web, secure web and SOCKS proxies plus the bypass list', () async {
      final cmds = FakeCommands()..outputs['-listnetworkserviceorder'] = order;
      final proxy = MacSystemProxy(run: cmds.call);
      await proxy.apply(
          httpPort: 10809,
          socksPort: 10808,
          bypassLan: true,
          rules: PassThroughRules.compile(['bank.ir'], const []));
      final wifi = cmds.calls.where((c) => c.contains('Wi-Fi')).toList();
      expect(wifi[0], ['/usr/sbin/networksetup', '-setwebproxy', 'Wi-Fi', '127.0.0.1', '10809']);
      expect(wifi[1], ['/usr/sbin/networksetup', '-setsecurewebproxy', 'Wi-Fi', '127.0.0.1', '10809']);
      expect(wifi[2], ['/usr/sbin/networksetup', '-setsocksfirewallproxy', 'Wi-Fi', '127.0.0.1', '10808']);
      expect(wifi[3], containsAll(['-setproxybypassdomains', '192.168.0.0/16', '*.local', 'bank.ir', '*.bank.ir']));
      expect(cmds.calls.where((c) => c.contains('V2BOX')), isEmpty);
    });

    test('macOS falls back to one admin prompt when refused', () async {
      final cmds = FakeCommands()
        ..outputs['-listnetworkserviceorder'] = order
        ..deny = (c) => c.first.endsWith('networksetup') && c[1].startsWith('-set');
      await MacSystemProxy(run: cmds.call, useHelper: false).apply(httpPort: 1, socksPort: 2, bypassLan: false);
      final osa = cmds.calls.where((c) => c.first == '/usr/bin/osascript').single;
      expect(osa[2], startsWith('do shell script "'));
      expect(osa[2], endsWith('with administrator privileges'));
      expect(osa[2], contains("'/usr/sbin/networksetup' '-setwebproxy' 'Wi-Fi' '127.0.0.1' '1'"));
    });

    test('macOS restores what was there before', () async {
      final cmds = FakeCommands();
      await MacSystemProxy(run: cmds.call).restore({
        'Wi-Fi': {
          'webproxy': {'enabled': true, 'server': 'corp.proxy', 'port': 8080},
          'securewebproxy': {'enabled': false, 'server': '', 'port': 0},
          'socksfirewallproxy': {'enabled': false, 'server': '', 'port': 0},
          'bypass': <String>[],
        },
      });
      expect(cmds.calls.map((c) => c.sublist(1)), [
        ['-setwebproxy', 'Wi-Fi', 'corp.proxy', '8080'],
        ['-setsecurewebproxystate', 'Wi-Fi', 'off'],
        ['-setsocksfirewallproxystate', 'Wi-Fi', 'off'],
        ['-setproxybypassdomains', 'Wi-Fi', 'Empty'],
      ]);
    });

    test('Windows reads and writes the Internet Settings values', () async {
      final parsed = WindowsSystemProxy.parseRegQuery('''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x0
    ProxyServer    REG_SZ    10.0.0.1:3128
    IE5_UNSAFE    REG_SZ    x
''');
      expect(parsed, {
        'ProxyEnable': {'type': 'REG_DWORD', 'data': '0x0'},
        'ProxyServer': {'type': 'REG_SZ', 'data': '10.0.0.1:3128'},
      });
      final list = WindowsSystemProxy.overrideList(
          bypassLan: true, rules: PassThroughRules.compile(['bank.ir', '5.6.0.0/16', '1.2.0.0/15'], const []));
      expect(list.split(';'), containsAll(['192.168.*', '10.*', 'bank.ir', '*.bank.ir', '5.6.*', '<local>']));
      expect(list, isNot(contains('1.2.')));

      final cmds = FakeCommands();
      await WindowsSystemProxy(run: cmds.call, notify: () {}).restore(parsed);
      expect(cmds.calls.where((c) => c[1] == 'add').map((c) => [c[4], c[6], c[8]]), [
        ['ProxyEnable', 'REG_DWORD', '0'],
        ['ProxyServer', 'REG_SZ', '10.0.0.1:3128'],
      ]);
      expect(cmds.calls.where((c) => c[1] == 'delete').map((c) => c[4]), ['ProxyOverride', 'AutoConfigURL']);
    });
  });

  group('V2rayBloc', () {
    late Directory tmp;
    late FakeEngine engine;
    late V2rayBloc bloc;
    var changes = 0;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('irnet_v2ray');
      engine = FakeEngine(tmp);
      changes = 0;
      bloc = V2rayBloc(
        engine: engine,
        onConnectionChanged: () => changes++,
        subscriptionClient: SubscriptionClient(
          httpClient: () => MockClient((req) async => http.Response(
                base64.encode(utf8.encode('vless://$_uuid@s1.example.com:443?security=tls#S1\n'
                    'vless://$_uuid@s2.example.com:443?security=tls#S2')),
                200,
                headers: {'subscription-userinfo': 'upload=1; download=2; total=100; expire=0', 'profile-title': 'Work'},
              )),
        ),
      );
      await bloc.initialize();
    });

    tearDown(() async {
      await bloc.dispose();
      await tmp.delete(recursive: true);
    });

    test('imports links and a subscription from one paste', () async {
      final r = await bloc.importText('vless://$_uuid@m.example.com:443?security=tls#Mine\n'
          'hiddify://import/https://sub.example.com/x\n'
          'ss://abc@h:1#nope');
      expect(r.added, 1);
      expect(r.unsupported, 1);
      expect(r.subscriptions.single, (name: 'Work', configs: 2));
      expect(r.message, contains('Added subscription “Work” (2 configs)'));

      final s = bloc.value;
      expect(s.profiles.map((p) => p.name), ['Mine', 'S1', 'S2']);
      expect(s.subscriptions.single.usage!.total, 100);
      expect(s.selected!.name, 'Mine');

      final again = await bloc.importText('vless://$_uuid@m.example.com:443?security=tls#Mine');
      expect(again.duplicates, 1);
      expect(again.added, 0);
    });

    test('state survives a restart', () async {
      await bloc.importText('trojan://pw@t.example.com:443#T');
      await bloc.setRules('example.com\ngeoip:ir');
      final reloaded = V2rayBloc(engine: FakeEngine(tmp));
      await reloaded.initialize();
      expect(reloaded.value.profiles.single.name, 'T');
      expect(reloaded.value.settings.rules, ['example.com', 'geoip:ir']);
      await reloaded.dispose();
    });

    test('connects, exposes the local proxy and reconnects on rule changes', () async {
      await bloc.importText('trojan://pw@t.example.com:443#T');
      await bloc.connect();
      expect(bloc.value.connection.isConnected, isTrue);
      expect(bloc.localProxy, '127.0.0.1:10809');
      expect(changes, 1);

      await bloc.setRules('example.com');
      expect(engine.connects, hasLength(2));
      expect(engine.connects.last.rules.domains, ['domain:example.com']);

      await bloc.setBypassLan(false);
      expect(engine.connects.last.bypassLan, isFalse);

      await bloc.disconnect();
      expect(bloc.value.connection.phase, ConnectionPhase.disconnected);
      expect(bloc.localProxy, isNull);
      expect(engine.disconnects, 1);
    });

    test('a config the core refuses fails with its reason', () async {
      await bloc.importText('vless://$_uuid@203.0.113.9:80?type=ws#plain');
      await bloc.connect();
      expect(bloc.value.connection.phase, ConnectionPhase.failed);
      expect(bloc.value.connection.error, contains('no TLS'));
      expect(engine.connects, isEmpty);
    });

    test('engine errors and unexpected stops reach the state', () async {
      await bloc.importText('trojan://pw@t.example.com:443#T');
      engine.failWith = const VpnException('Xray: boom');
      await bloc.connect();
      expect(bloc.value.connection.error, 'Xray: boom');

      engine.failWith = null;
      await bloc.connect();
      engine.events$.add(const EngineStopped('The Xray core stopped'));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.value.connection.phase, ConnectionPhase.failed);
      expect(bloc.localProxy, isNull);
    });

    test('imports geo files and validates rules against them', () async {
      final asset = await bloc.importGeoAsset('GeoIP.dat', _geoip({'IR': [5, 0, 0, 0]}));
      expect(asset.fileName, 'geoip.dat');
      expect(File('${tmp.path}/geoip.dat').existsSync(), isTrue);
      final compiled = await bloc.setRules('geoip:ir\ngeoip:cn');
      expect(compiled.ips, ['geoip:ir']);
      expect(compiled.issues.single.message, '"cn" is not in geoip.dat');

      expect(bloc.importGeoAsset('x.dat', Uint8List.fromList([1, 2, 3])), throwsA(isA<FormatException>()));

      await bloc.removeGeoAsset('geoip.dat');
      expect(File('${tmp.path}/geoip.dat').existsSync(), isFalse);
      expect(bloc.compiledRules.ips, isEmpty);
    });

    test('a geosite file imported as geoip.dat is renamed to geosite.dat', () async {
      final asset = await bloc.importGeoAsset('geoip.dat', _geosite({'CATEGORY-IR': 'x.ir'}));
      expect(asset.fileName, 'geosite.dat');
      expect(asset.ruleFor('category-ir'), 'geosite:category-ir');
    });
  });
}
