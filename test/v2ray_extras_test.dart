import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ir_net/utils/notifier.dart';
import 'package:ir_net/v2ray/app_list.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/subscription.dart';
import 'package:ir_net/v2ray/v2ray_store.dart';
import 'package:ir_net/v2ray/vpn_engine.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:ir_net/v2ray/xray_runner.dart';
import 'package:ir_net/v2ray_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/v2ray_fakes.dart';

const _uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';

V2rayProfile _trojan(String host) => ShareLinkParser.parse('trojan://pw@$host:443?security=tls#$host');

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

Uint8List _geoip(Map<String, List<int>> codes) => Uint8List.fromList([
      for (final e in codes.entries)
        ..._field(1, [
          ..._field(1, utf8.encode(e.key)),
          ..._field(2, [..._field(1, e.value), 0x10, 8]),
        ]),
    ]);

Uint8List _geosite(Map<String, String> codes) => Uint8List.fromList([
      for (final e in codes.entries)
        ..._field(1, [
          ..._field(1, utf8.encode(e.key)),
          ..._field(2, [0x08, 2, ..._field(2, utf8.encode(e.value))]),
        ]),
    ]);

List<Map<String, dynamic>> _rulesOf(Map<String, dynamic> config) =>
    ((config['routing'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

void main() {
  group('Auto, fragment and app rules in the Xray config', () {
    test('Auto puts several configs behind a least-ping balancer with health probes', () {
      final a = _trojan('a.example.com'), b = _trojan('b.example.com');
      final c = XrayConfigBuilder.connection(a, socksPort: 1080, httpPort: 1081, balanced: [a, b]);

      final outbounds = (c['outbounds'] as List).cast<Map>();
      expect(outbounds.map((o) => o['tag']), ['proxy-0', 'proxy-1', 'direct', 'block']);
      final balancer = ((c['routing'] as Map)['balancers'] as List).single as Map;
      expect(balancer['selector'], ['proxy-']);
      expect(balancer['strategy'], {'type': 'leastPing'});
      expect(balancer['fallbackTag'], 'proxy-0');
      expect((c['observatory'] as Map)['subjectSelector'], ['proxy-']);
      expect((c['observatory'] as Map)['probeURL'], XrayConfigBuilder.probeUrl);

      final rules = _rulesOf(c);
      expect(rules.first, {'inboundTag': ['dns-internal'], 'balancerTag': 'auto'},
          reason: 'Xray\'s own DNS goes through the balancer too');
      expect(rules.last, {'network': 'tcp,udp', 'balancerTag': 'auto'});
      expect((c['dns'] as Map)['tag'], 'dns-internal');
      expect(c['log'], isNot(contains('access')), reason: 'the access log names the config in use');
    });

    test('a single config keeps the plain "proxy" outbound and no access log', () {
      final a = _trojan('a.example.com');
      final c = XrayConfigBuilder.connection(a, socksPort: 1080, httpPort: 1081, balanced: [a]);
      expect((c['outbounds'] as List).map((o) => o['tag']), ['proxy', 'direct', 'block']);
      expect(c, isNot(contains('observatory')));
      expect(c['routing'] as Map, isNot(contains('balancers')));
      expect(c['log'], {'loglevel': 'warning', 'access': 'none'});
    });

    test('Auto in Tunnel mode keeps DNS capture first and pins every server', () {
      final a = _trojan('a.example.com'), b = _trojan('b.example.com');
      final c = XrayConfigBuilder.tunnel(a,
          httpPort: 1081,
          os: 'macos',
          balanced: [a, b],
          hosts: {
            'a.example.com': ['203.0.113.1'],
            'b.example.com': ['203.0.113.2'],
          });
      final rules = _rulesOf(c);
      expect(rules.first['outboundTag'], 'dns-out');
      expect(rules[1], {'inboundTag': ['dns-internal'], 'balancerTag': 'auto'});
      for (final o in (c['outbounds'] as List).cast<Map>().where((o) => '${o['tag']}'.startsWith('proxy-'))) {
        expect((o['streamSettings'] as Map)['sockopt'], {'domainStrategy': 'UseIP'});
      }
      expect(c['log'], {'loglevel': 'warning'}, reason: 'the privileged helpers refuse any "access" key');
    });

    test('fragment splits the TLS handshake of TLS and REALITY configs only', () {
      const f = FragmentOptions(length: '50-80', delay: '5-9');
      final tls = _trojan('a.example.com');
      final reality = ShareLinkParser.parse(
          'vless://$_uuid@r.example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2#R');
      final plain = ShareLinkParser.parse('vless://$_uuid@p.example.com:80?type=ws&path=%2F#P');
      expect(XrayConfigBuilder.fragmentApplies(tls), isTrue);
      expect(XrayConfigBuilder.fragmentApplies(reality), isTrue);
      expect(XrayConfigBuilder.fragmentApplies(plain), isFalse);

      final c = XrayConfigBuilder.connection(tls, socksPort: 1080, httpPort: 1081, fragment: f);
      final stream = ((c['outbounds'] as List).first as Map)['streamSettings'] as Map;
      expect(stream['finalmask'], {
        'tcp': [
          {
            'type': 'fragment',
            'settings': {'packets': 'tlshello', 'length': '50-80', 'delay': '5-9'},
          }
        ],
      });
      final off = XrayConfigBuilder.connection(tls, socksPort: 1080, httpPort: 1081);
      expect(((off['outbounds'] as List).first as Map)['streamSettings'] as Map, isNot(contains('finalmask')));
    });

    test('apps that skip the VPN become a process rule ahead of everything else', () {
      final c = XrayConfigBuilder.connection(_trojan('a.example.com'),
          socksPort: 1080, httpPort: 1081, bypassApps: ['Telegram', '/Applications/Bank.app/']);
      expect(_rulesOf(c).first, {
        'process': ['Telegram', '/Applications/Bank.app/'],
        'outboundTag': 'direct',
      });
      final none = XrayConfigBuilder.connection(_trojan('a.example.com'), socksPort: 1080, httpPort: 1081);
      expect(_rulesOf(none).where((r) => r.containsKey('process')), isEmpty);
    });

    test('settings round-trip through JSON', () {
      const s = V2raySettings(
        fragment: true,
        fragmentOptions: FragmentOptions(length: '10-20', delay: '1-2'),
        iranDirect: true,
        bypassApps: ['org.telegram.messenger'],
        connectOnLaunch: true,
        autoReconnect: false,
        notify: false,
      );
      final back = V2raySettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.fragment, isTrue);
      expect(back.fragmentOptions.length, '10-20');
      expect(back.fragmentOptions.delay, '1-2');
      expect(back.iranDirect, isTrue);
      expect(back.bypassApps, ['org.telegram.messenger']);
      expect(back.connectOnLaunch, isTrue);
      expect(back.autoReconnect, isFalse);
      expect(back.notify, isFalse);
      // Older saved settings: reconnect and notifications default on.
      final old = V2raySettings.fromJson(const {});
      expect(old.autoReconnect, isTrue);
      expect(old.notify, isTrue);
      expect(old.fragment, isFalse);
    });
  });

  group('the config in use', () {
    test('is read from Xray access log lines', () {
      expect(outboundTagIn('2026/11/24 from 127.0.0.1:5000 accepted tcp:x.com:443 [socks -> proxy-3]'), 'proxy-3');
      expect(outboundTagIn('from 10.0.0.2:5 accepted udp:1.1.1.1:53 [tun >> proxy-0] email: a'), 'proxy-0');
      expect(outboundTagIn('from 1.2.3.4:5 accepted tcp:y.ir:443 [http -> direct]'), isNull);
      expect(outboundTagIn('Xray 26.11.9 started'), isNull);
    });
  });

  group('sharing', () {
    test('a WireGuard config exports to a .conf that imports back the same', () {
      const conf = '''
[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 172.16.0.2/32, 2606:4700:110:8a36::1/128
MTU = 1280
# Reserved = 1,2,3

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.example.com:2408
PersistentKeepalive = 25
''';
      final first = ShareLinkParser.parseText(conf, nameHint: 'warp').profiles.single;
      expect(first.wireguard!.reserved, [1, 2, 3]);
      final exported = ShareLinkParser.wireGuardConf(first);
      expect(exported, contains('# Reserved = 1,2,3'));
      expect(exported, contains('Endpoint = engage.example.com:2408'));

      final again = ShareLinkParser.parseText(exported, nameHint: 'warp').profiles.single;
      expect(again.credential, first.credential);
      expect(again.address, first.address);
      expect(again.port, first.port);
      expect(again.wireguard!.publicKey, first.wireguard!.publicKey);
      expect(again.wireguard!.addresses, first.wireguard!.addresses);
      expect(again.wireguard!.reserved, [1, 2, 3]);
      expect(again.wireguard!.mtu, 1280);
      expect(again.wireguard!.keepAlive, 25);
      expect(ShareLinkParser.wireGuardConf(again), exported);

      // The share link (what the QR code holds) imports back too.
      expect(ShareLinkParser.parse(first.link).wireguard!.reserved, [1, 2, 3]);
    });

    test('chosen apps read as names', () {
      expect(AppLister.labelFor('/Applications/Mellat Bank.app/'), 'Mellat Bank');
      expect(AppLister.labelFor('org.telegram.messenger', const [AppChoice('Telegram', 'org.telegram.messenger')]),
          'Telegram');
      expect(AppLister.labelFor('Telegram'), 'Telegram');
    });
  });

  group('V2rayBloc', () {
    late Directory tmp;
    late FakeEngine engine;
    late V2rayBloc bloc;
    late List<({String title, String body})> notes;
    late http.Client Function() httpClient;
    final reconnectDelays = V2rayBloc.reconnectDelays;
    final launchDelay = V2rayBloc.launchConnectDelay;
    var expire = 0;

    V2rayBloc newBloc(FakeEngine e) => V2rayBloc(
          engine: e,
          httpClient: () => httpClient(),
          subscriptionClient: SubscriptionClient(
            httpClient: () => MockClient((req) async => http.Response(
                  base64.encode(utf8.encode('trojan://pw@s1.example.com:443?security=tls#S1\n'
                      'trojan://pw@s2.example.com:443?security=tls#S2\n'
                      'trojan://pw@s3.example.com:443?security=tls#S3')),
                  200,
                  headers: {
                    'subscription-userinfo': 'upload=1; download=2; total=100; expire=$expire',
                    'profile-title': 'Work',
                  },
                )),
          ),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('irnet_v2ray_extras');
      engine = FakeEngine(tmp);
      notes = [];
      expire = 0;
      httpClient = () => MockClient((_) async => http.Response('nope', 404));
      AppNotifier.override = (title, body, id) async => notes.add((title: title, body: body));
      bloc = newBloc(engine);
      await bloc.initialize();
    });

    tearDown(() async {
      AppNotifier.override = null;
      V2rayBloc.reconnectDelays = reconnectDelays;
      V2rayBloc.launchConnectDelay = launchDelay;
      await bloc.dispose();
      await tmp.delete(recursive: true);
    });

    Future<String> addSubscription() async {
      await bloc.importText('https://sub.example.com/x');
      return bloc.value.subscriptions.single.id;
    }

    test('Auto connects to a group\'s working configs, fastest first, and names the one in use', () async {
      final group = await addSubscription();
      final ids = bloc.value.profilesOf(group).map((p) => p.id).toList();
      expect(bloc.autoCandidates(group).map((p) => p.id), ids);

      await bloc.select(AutoSelect.idFor(group));
      await bloc.connect();
      final c = bloc.value.connection;
      expect(c.isConnected, isTrue);
      expect(c.profileId, AutoSelect.idFor(group));
      expect(c.profileName, 'Auto · Work');
      expect(engine.connects.single.ids, ids);

      engine.activeOutboundTag = 'proxy-2';
      bloc.refreshActive();
      expect(bloc.value.connection.activeProfileId, ids[2]);

      // Removing the subscription drops the Auto selection with it.
      await bloc.disconnect();
      await bloc.removeSubscription(group);
      expect(bloc.value.selectedId, isNull);
    });

    test('fragment, apps and Iran direct reach the engine and reconnect a live VPN', () async {
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
      await bloc.connect();
      expect(engine.connects.last.options.fragment, isNull);

      await bloc.setFragment(true);
      expect(engine.connects, hasLength(2));
      expect(engine.connects.last.options.fragment!.packets, 'tlshello');

      await bloc.setFragmentOptions(const FragmentOptions(length: '20-40', delay: '3-6'));
      expect(engine.connects, hasLength(3));
      expect(engine.connects.last.options.fragment!.length, '20-40');

      await bloc.setBypassApps(['org.telegram.messenger']);
      expect(engine.connects, hasLength(4));
      expect(engine.connects.last.options.bypassApps, ['org.telegram.messenger']);

      // Settings that don't change the connection don't reconnect.
      await bloc.setConnectOnLaunch(true);
      await bloc.setNotify(false);
      expect(engine.connects, hasLength(4));
    });

    test('a VPN that stops answering is reconnected after two failed checks', () async {
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
      await bloc.connect();

      await bloc.checkHealth();
      expect(engine.probes, 1);
      expect(engine.connects, hasLength(1));

      engine.probeResult = () => false;
      await bloc.checkHealth();
      expect(engine.connects, hasLength(1), reason: 'one failure can be a blip');
      await bloc.checkHealth();
      expect(engine.connects, hasLength(2));
      expect(notes.single.title, 'VPN not responding');

      // After a network change the first failure is enough.
      bloc.onNetworkChanged();
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(engine.connects, hasLength(3));
    });

    test('a dropped VPN reconnects by itself and says so', () async {
      V2rayBloc.reconnectDelays = [const Duration(milliseconds: 20)];
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
      await bloc.connect();

      engine.events$.add(const EngineStopped('core crashed'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(bloc.value.connection.isConnected, isTrue);
      expect(engine.connects, hasLength(2));
      expect(notes.map((n) => n.title), ['VPN disconnected', 'VPN reconnected']);
    });

    test('without auto-reconnect a drop is only reported; without notifications nothing is shown', () async {
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
      await bloc.setAutoReconnect(false);
      await bloc.connect();
      engine.events$.add(const EngineStopped('core crashed'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.value.connection.phase, ConnectionPhase.failed);
      expect(engine.connects, hasLength(1));
      expect(notes.single.body, contains('core crashed'));

      await bloc.setNotify(false);
      await bloc.connect();
      engine.events$.add(const EngineStopped('again'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notes, hasLength(1));
    });

    test('subscriptions about to expire or low on data warn once a day', () async {
      expire = DateTime.now().add(const Duration(hours: 30)).millisecondsSinceEpoch ~/ 1000;
      await addSubscription();
      await bloc.checkSubscriptionAlerts();
      expect(notes.map((n) => n.title), unorderedEquals(['Subscription expiring', 'Subscription data low']));
      expect(notes.firstWhere((n) => n.title == 'Subscription expiring').body, 'Work expires in 2 days.');

      await bloc.checkSubscriptionAlerts();
      expect(notes, hasLength(2), reason: 'already warned today');
    });

    test('the Quick Settings tile forgets a connection whose config was removed', () async {
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T\ntrojan://pw@u.example.com:443?security=tls#U');
      final ids = bloc.value.profiles.map((p) => p.id).toList();
      final store = V2rayStore();
      Future<String?> saved() async => (await SharedPreferences.getInstance()).getString('v2ray.quickConnect');

      await store.saveQuickConnect({'profileId': ids[0], 'config': '{}'});
      await bloc.removeProfile(ids[1]);
      expect(await saved(), isNotNull, reason: 'another config was removed');
      await bloc.removeProfile(ids[0]);
      expect(await saved(), isNull);
    });

    test('removes the VPN plugin\'s geo copies but keeps imported ones', () async {
      final dir = await Directory('${tmp.path}/geo').create();
      for (final name in ['geoip.dat', 'geosite.dat', 'geoip-only-cn-private.dat', 'iran-geoip.dat']) {
        await File('${dir.path}/$name').writeAsString('x');
      }
      final removed = await V2rayBloc.removeUntrackedGeoFiles(dir, ['geosite.dat', 'iran-geoip.dat']);
      expect(removed, ['geoip.dat', 'geoip-only-cn-private.dat']);
      final left = dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
      expect(left, ['geosite.dat', 'iran-geoip.dat'], reason: 'imported files stay');
    });

    test('connects at launch when asked to', () async {
      await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
      await bloc.setConnectOnLaunch(true);
      V2rayBloc.launchConnectDelay = Duration.zero;
      final other = FakeEngine(tmp);
      final relaunched = newBloc(other);
      await relaunched.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(other.connects, hasLength(1));
      expect(relaunched.value.connection.isConnected, isTrue);
      await relaunched.dispose();
    });

    group('Iranian sites go direct', () {
      final geoip = _geoip({'IR': [5, 0, 0, 0], 'PRIVATE': [10, 0, 0, 0]});
      final geosite = _geosite({'IR': 'digikala.com', 'CATEGORY-IR': 'snapp.ir'});
      final requested = <String>[];

      http.Client server({bool badSum = false, bool githubDown = false}) => MockClient((req) async {
            requested.add(req.url.toString());
            if (githubDown && req.url.host == 'github.com') return http.Response('down', 503);
            final name = req.url.pathSegments.last;
            final file = name.startsWith('geoip-lite.dat') ? geoip : geosite;
            if (name.endsWith('.sha256sum')) {
              final sum = badSum ? '0' * 64 : sha256.convert(file).toString();
              return http.Response('$sum  ${name.replaceAll('.sha256sum', '')}\n', 200);
            }
            return http.Response.bytes(file, 200);
          });

      setUp(requested.clear);

      test('downloads and checks the lists, then routes Iranian sites direct', () async {
        httpClient = () => server(githubDown: true);
        await bloc.importText('trojan://pw@t.example.com:443?security=tls#T');
        await bloc.connect();
        await bloc.setIranDirect(true);

        expect(bloc.value.settings.iranDirect, isTrue);
        expect(bloc.iranRulesPresent, isTrue);
        expect(bloc.value.iranRules.updatedAt, isNotNull);
        expect(bloc.value.iranRules.error, isNull);
        expect(requested.any((u) => u.startsWith('https://cdn.jsdelivr.net/')), isTrue,
            reason: 'falls back to jsDelivr when GitHub is unreachable');
        expect(File('${tmp.path}/iran-geoip.dat').existsSync(), isTrue);

        final rules = engine.connects.last.rules;
        expect(rules.domains, contains('ext:iran-geosite.dat:ir'));
        expect(rules.ips, contains('ext:iran-geoip.dat:ir'));

        await bloc.setIranDirect(false);
        expect(engine.connects.last.rules.domains, isNot(contains('ext:iran-geosite.dat:ir')));
      });

      test('a list that fails its checksum is refused and the switch flips back', () async {
        httpClient = () => server(badSum: true);
        await bloc.setIranDirect(true);
        expect(bloc.value.settings.iranDirect, isFalse);
        expect(bloc.iranRulesPresent, isFalse);
        expect(bloc.value.iranRules.error, contains('checksum mismatch'));
      });
    });
  });
}
