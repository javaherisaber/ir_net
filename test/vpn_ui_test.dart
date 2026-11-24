// Renders the VPN screens with seeded configs, subscriptions, delays, rules
// and geo files at desktop and phone widths, and fails on layout overflow.
//
// Set IRNET_SCREENSHOTS=/some/dir to also save PNGs of each state:
//   IRNET_SCREENSHOTS=/tmp/shots flutter test test/vpn_ui_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/ui/theme.dart';
import 'package:ir_net/ui/vpn_widgets.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/vpn_engine.dart';
import 'package:ir_net/v2ray_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/v2ray_fakes.dart';

const _uuid = '2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60';
const _pbk = 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw';
const _gb = 1024 * 1024 * 1024;

String _vmess(Map<String, dynamic> json) => 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';

final _work = [
  'vless://$_uuid@de1.example.com:443?security=reality&sni=www.speedtest.net&fp=chrome&pbk=$_pbk&sid=6ba8&type=tcp&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Germany%201',
  'vless://$_uuid@nl.example.com:443?type=xhttp&security=tls&sni=nl.example.com&path=%2Fx#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20XHTTP',
  'trojan://pw@fi.example.com:443?sni=fi.example.com#%F0%9F%87%AB%F0%9F%87%AE%20Finland',
  _vmess({'ps': '🇺🇸 United States (VMess WS)', 'add': 'us.example.com', 'port': 443, 'id': _uuid, 'net': 'ws', 'tls': 'tls'}),
  'vless://$_uuid@203.0.113.7:80?type=ws#%F0%9F%87%B9%F0%9F%87%B7%20Turkey%20plain',
  'vless://$_uuid@0.0.0.0:1#%F0%9F%94%8B%2038%20GB%20left',
];
final _family = [
  'trojan://pw@fam1.example.com:443#Family%201',
  'trojan://pw@fam2.example.com:443#Family%202',
];
final _manual = [
  'vless://$_uuid@my.example.com:8443?type=grpc&serviceName=g&security=tls&sni=my.example.com#My%20server',
  'trojan://pw@backup.example.com:443?allowInsecure=1#Backup%20(self-signed)',
  'wireguard://yAnz5TF%2BlXXJte14tji3zlMNq%2Bhd2rYUIgJBgB3fBmk%3D@engage.cloudflareclient.com:2408'
      '?publickey=xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg%3D&address=172.16.0.2%2F32&reserved=1,2,3'
      '#Cloudflare%20WARP%20(WireGuard)',
];

String _id(String link, String? sub) => ShareLinkParser.profileId(link, sub);

Map<String, Object> _seed() {
  final now = DateTime.now();
  final at = now.millisecondsSinceEpoch;
  return {
    'flutter.v2ray.v1': jsonEncode({
      'profiles': [
        for (final l in _work) {'l': l, 's': 'work'},
        for (final l in _family) {'l': l, 's': 'fam'},
        for (final l in _manual) {'l': l},
      ],
      'subscriptions': [
        {
          'id': 'work',
          'url': 'https://panel.example.com/sub/abc',
          'name': 'Fast VPN · Premium',
          'usage': {
            'upload': 3 * _gb,
            'download': 9 * _gb,
            'total': 50 * _gb,
            'expire': now.add(const Duration(days: 23, hours: 5)).millisecondsSinceEpoch ~/ 1000,
          },
          'lastUpdated': at - 2 * 3600 * 1000,
          'announce': 'New Finland servers added. Renew before the 1st for 10% off.',
        },
        {
          'id': 'fam',
          'url': 'https://family.example.org/s/1',
          'name': 'Family plan',
          'usage': {
            'upload': 1 * _gb,
            'download': 19 * _gb,
            'total': 20 * _gb,
            'expire': now.subtract(const Duration(days: 2)).millisecondsSinceEpoch ~/ 1000,
          },
          'lastUpdated': at - 26 * 3600 * 1000,
          'lastError': 'The subscription server answered HTTP 403',
        },
      ],
      'selected': _id(_work[0], 'work'),
      'delays': {
        _id(_work[0], 'work'): {'ms': 412, 'at': at},
        _id(_work[1], 'work'): {'ms': 1180, 'at': at},
        _id(_work[2], 'work'): {'error': 'Timeout', 'at': at},
        _id(_work[3], 'work'): {'ms': 2300, 'at': at},
        _id(_manual[0], null): {'ms': 96, 'at': at},
      },
      'settings': {
        'bypassLan': true,
        'rules': ['geosite:category-ir', 'geoip:ir', 'geoip:cn', 'example.com', '# banks', 'keyword:shaparak'],
      },
      'assets': [
        {'file': 'geoip.dat', 'kind': 'ip', 'size': 19 * 1024 * 1024, 'tags': ['ir', 'private', 'us'], 'at': at},
        {
          'file': 'geosite.dat',
          'kind': 'site',
          'size': 9 * 1024 * 1024,
          'tags': ['category-ads-all', 'category-ir', 'google', 'telegram'],
          'at': at
        },
        {'file': 'iran.dat', 'kind': 'site', 'size': 2 * 1024 * 1024, 'tags': ['ir', 'ads', 'malware'], 'at': at},
      ],
    }),
  };
}

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await (FontLoader(AppFonts.ui)..addFont(file('assets/fonts/SpaceGrotesk.ttf'))).load();
  await (FontLoader(AppFonts.mono)..addFont(file('assets/fonts/JetBrainsMono.ttf'))).load();
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await (FontLoader('MaterialIcons')..addFont(file(icons.path))).load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['IRNET_SCREENSHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  late FakeEngine engine;
  late Directory tmp;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/system_tray/app_window'), (call) async => null);
  });

  Future<void> setUpVpn(WidgetTester tester, {bool seeded = true}) async {
    await tester.runAsync(() async {
      await _loadFonts();
      SharedPreferences.setMockInitialValues(seeded ? _seed() : {});
      tmp = await Directory.systemTemp.createTemp('irnet_vpn_ui');
      engine = FakeEngine(tmp);
      bloc.v2ray = V2rayBloc(engine: engine);
      await bloc.v2ray.initialize();
    });
  }

  Future<void> tearDownVpn(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await bloc.v2ray.dispose();
      await tmp.delete(recursive: true);
    });
  }

  /// [child] inside a scrolling page like the app's shells.
  Future<void> pumpPage(WidgetTester tester, Size size, Widget child, {double padding = 20}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: SingleChildScrollView(padding: EdgeInsets.all(padding), child: child)),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  // The desktop content area: 1000 px window minus the 240 px sidebar.
  const desktop = Size(760, 2300);
  const phone = Size(375, 2600);

  testWidgets('desktop: connected, grouped configs with usage and delays', (tester) async {
    await setUpVpn(tester);
    await tester.runAsync(() => bloc.v2ray.connect());
    await pumpPage(tester, desktop, const VpnSection());

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('🇩🇪 Germany 1'), findsWidgets);
    expect(find.text('Fast VPN · Premium'), findsWidgets);
    expect(find.text('38.0 GB left'), findsOneWidget);
    expect(find.text('23 days left'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
    expect(find.textContaining('HTTP 403'), findsOneWidget);
    expect(find.text('412 ms'), findsWidgets);
    expect(find.text('Timeout'), findsOneWidget);
    expect(find.text('Info from your provider'), findsOneWidget);
    expect(find.textContaining('Has no TLS'), findsOneWidget);
    expect(find.textContaining('HTTP 127.0.0.1:10809'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_connected');

    // Focus one subscription.
    await tester.tap(find.text('Family plan · 2'));
    await tester.pump();
    expect(find.text('Fast VPN · Premium'), findsNothing, reason: 'its group card is hidden');
    expect(find.text('Fast VPN · Premium · 6'), findsOneWidget, reason: 'its chip stays');
    await _shot(tester, 'vpn_desktop_focused');

    // Fastest first.
    await tester.tap(find.text('All · 11'));
    await tester.pump();
    await tester.tap(find.byTooltip('Sort fastest first'));
    await tester.pump();
    await _shot(tester, 'vpn_desktop_sorted');
    await tearDownVpn(tester);
  });

  testWidgets('desktop: routing tab with rules, issues and geo files', (tester) async {
    await setUpVpn(tester);
    await pumpPage(tester, desktop, const VpnSection());
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Connection mode'), findsOneWidget);
    expect(find.text('Kill switch'), findsOneWidget);
    expect(find.text('Bypass LAN'), findsOneWidget);
    expect(find.textContaining('"cn" is not in geoip.dat', findRichText: true), findsOneWidget);
    expect(find.text('iran.dat'), findsOneWidget);
    expect(find.text('GeoIP · 3 tags · 19.0 MB'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_routing');

    // Browse a file's tags and add one.
    await tester.tap(find.text('iran.dat'));
    await tester.pump();
    await tester.pump();
    expect(find.text('ext:iran.dat:malware'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_tags');
    await tester.tap(find.text('malware'));
    await tester.pump();
    await tester.tap(find.text('Done · save rules to apply'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Save rules'), findsOneWidget);
    await tester.tap(find.text('Save rules'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(bloc.v2ray.value.settings.rules, contains('ext:iran.dat:malware'));
    await tearDownVpn(tester);
  });

  testWidgets('phone: configs, routing and the empty state', (tester) async {
    await setUpVpn(tester);
    await tester.runAsync(() => bloc.v2ray.connect());
    await pumpPage(tester, phone, const VpnSection(compact: true), padding: 16);
    expect(find.text('Connected'), findsOneWidget);
    await _shot(tester, 'vpn_phone_connected');

    await tester.tap(find.text('Settings'));
    await tester.pump();
    await _shot(tester, 'vpn_phone_routing');
    await tearDownVpn(tester);

    await setUpVpn(tester, seeded: false);
    await pumpPage(tester, phone, const VpnSection(compact: true), padding: 16);
    expect(find.text('No configs yet'), findsOneWidget);
    await _shot(tester, 'vpn_phone_empty');
    await tearDownVpn(tester);
  });

  testWidgets('tunnel mode, kill switch on and the network cut', (tester) async {
    await setUpVpn(tester);
    final ks = FakeKillSwitch();
    await tester.runAsync(() async {
      bloc.v2ray = V2rayBloc(engine: engine, killSwitch: () => ks, waitForNetwork: () async {});
      await bloc.v2ray.initialize();
      await bloc.v2ray.setMode(VpnMode.tunnel);
      await bloc.v2ray.setKillSwitch(true);
    });
    await pumpPage(tester, desktop, const VpnSection());
    expect(find.textContaining('TUNNEL MODE'), findsOneWidget);
    expect(find.text('Kill switch: Wi-Fi and Ethernet are off until the VPN connects.'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_killswitch_cut');
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await _shot(tester, 'vpn_desktop_settings_tunnel');

    await pumpPage(tester, const Size(760, 200), const VpnSummaryCard());
    expect(find.text('Network off'), findsOneWidget);

    await tester.runAsync(() => bloc.v2ray.connect());
    await pumpPage(tester, desktop, const VpnSection());
    expect(ks.log, ['cut', 'restore Wi-Fi,Ethernet']);
    expect(find.text('All traffic tunnelled'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_tunnel_connected');
    await tearDownVpn(tester);
  });

  testWidgets('Auto, sharing and the new settings cards', (tester) async {
    await setUpVpn(tester);
    await tester.runAsync(() async {
      await bloc.v2ray.select(AutoSelect.idFor('work'));
      await bloc.v2ray.connect();
    });
    engine.activeOutboundTag = 'proxy-0'; // fastest first: Germany 1
    bloc.v2ray.refreshActive();
    await pumpPage(tester, desktop, const VpnSection());
    expect(find.text('Fastest server'), findsNWidgets(3), reason: 'one per group with two or more usable configs');
    expect(find.text('Auto · Fast VPN · Premium'), findsOneWidget);
    expect(find.text('Using 🇩🇪 Germany 1'), findsNWidgets(2), reason: 'in the hero and on the Auto row');
    expect(find.text('IN USE'), findsOneWidget);
    expect(engine.connects.last.ids, hasLength(4), reason: 'the work group\'s usable configs');
    await _shot(tester, 'vpn_desktop_auto');

    // Share a WireGuard config: link or .conf for the WireGuard apps.
    final warp = bloc.v2ray.value.profiles.firstWhere((p) => p.protocol == V2rayProtocol.wireguard);
    unawaited(showShareDialog(tester.element(find.byType(VpnSection)), warp));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // past the fade-in
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.byType(QrCodeView), findsOneWidget);
    await tester.tap(find.text('WireGuard app'));
    await tester.pump();
    expect(find.text('Copy config'), findsOneWidget);
    expect(find.textContaining('# Reserved = 1,2,3'), findsOneWidget);
    expect(find.text('Save .conf'), findsOneWidget);
    await _shot(tester, 'vpn_share_wireguard');
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump();
    for (final title in [
      'Connect when IRNet starts',
      'Reconnect automatically',
      'Notifications',
      'Iranian sites go direct',
      'Apps that skip the VPN',
      'Fragment (anti-filtering)',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    await tester.tap(find.textContaining('Piece size 100-200 bytes'));
    await tester.pump();
    expect(find.text('Piece size (bytes)'), findsOneWidget);
    await _shot(tester, 'vpn_desktop_settings_new');

    await pumpPage(tester, phone, const VpnSection(compact: true), padding: 16);
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Apps that skip the VPN'), findsOneWidget);
    await _shot(tester, 'vpn_phone_settings_new');

    await tester.runAsync(() => bloc.v2ray.disconnect());
    await pumpPage(tester, const Size(760, 200), const VpnSummaryCard());
    expect(find.text('Auto · Fast VPN · Premium'), findsOneWidget, reason: 'the tile names the Auto entry when off');
    await tearDownVpn(tester);
  });

  testWidgets('overview tile: connected, failed and off', (tester) async {
    await setUpVpn(tester);
    Widget tiles() => const Column(children: [
          VpnSummaryCard(),
          SizedBox(height: 12),
          SizedBox(width: 343, child: VpnSummaryCard(compact: true)),
        ]);

    await pumpPage(tester, const Size(760, 320), tiles());
    expect(find.text('Off'), findsNWidgets(2));
    expect(find.text('38.0 GB left · 23 days left'), findsNWidgets(2));
    await _shot(tester, 'vpn_tile_off');

    await tester.runAsync(() => bloc.v2ray.connect());
    await tester.pump();
    expect(find.text('Connected'), findsNWidgets(2));
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.byTooltip('Disconnect'), findsOneWidget, reason: 'the phone tile has a power button');
    await _shot(tester, 'vpn_tile_connected');

    engine.failWith = const VpnException('Xray: failed to dial: connection refused');
    await tester.runAsync(() => bloc.v2ray.connect());
    await tester.pump();
    expect(find.text('Failed'), findsNWidgets(2));
    await _shot(tester, 'vpn_tile_failed');
    await tearDownVpn(tester);
  });
}
