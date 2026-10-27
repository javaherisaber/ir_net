// Renders the Network quality and Data usage sections in the real app shell
// with seeded data, interacts with them, and fails on any layout overflow.
//
// Set IRNET_SCREENSHOTS=/some/dir to also save PNGs of each state:
//   IRNET_SCREENSHOTS=/tmp/shots flutter test test/ui_sections_test.dart

import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/quality_store.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/data/usage_store.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/quality_bloc.dart';
import 'package:ir_net/ui/call_widgets.dart';
import 'package:ir_net/ui/charts.dart';
import 'package:ir_net/ui/export_widgets.dart';
import 'package:ir_net/ui/nav_shell.dart';
import 'package:ir_net/ui/quality_widgets.dart';
import 'package:ir_net/ui/sections.dart';
import 'package:ir_net/ui/theme.dart';
import 'package:ir_net/usage_bloc.dart';
import 'package:ir_net/utils/ip_enricher.dart';
import 'package:ir_net/utils/file_delivery.dart';
import 'package:ir_net/utils/ip_tools.dart';
import 'package:ir_net/utils/quality_monitor.dart';
import 'package:ir_net/utils/quality_report_pdf.dart';
import 'package:ir_net/utils/time_utils.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/quality_seed.dart';

/// Keeps exported files in memory instead of writing to Downloads.
class RecordingDelivery extends FileDelivery {
  RecordingDelivery({this.share = false});
  final bool share;
  final files = <String, Uint8List>{};
  final opened = <String>[];
  final revealed = <String>[];

  @override
  bool get sharesFiles => share;

  @override
  Future<DeliveredFile> deliver(String name, Uint8List bytes, {required String mimeType, String? subject}) async {
    files[name] = bytes;
    return DeliveredFile('/Users/test/Downloads/$name', shared: share);
  }

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  Future<void> reveal(String path) async => revealed.add(path);
}

class IdleCollector extends UsageCollector {
  @override
  String get source => 'nettop';

  @override
  Stream<List<FlowDelta>> start() => const Stream.empty();

  @override
  Future<void> stop() async {}
}

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await (FontLoader(AppFonts.ui)..addFont(file('assets/fonts/SpaceGrotesk.ttf'))).load();
  await (FontLoader(AppFonts.mono)..addFont(file('assets/fonts/JetBrainsMono.ttf'))).load();
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(file(icons.path))).load();
  }
}

Future<void> _seedUsage(UsageStore store, DateTime now) async {
  final rnd = Random(3);
  final ips = <(String, IpKind, String?, String?, String?, String?)>[
    ('142.250.27.190', IpKind.public, 'ra-in-f190.1e100.net', 'US', 'United States', 'Google LLC'),
    ('149.154.167.91', IpKind.public, null, 'NL', 'The Netherlands', 'Telegram Messenger Inc'),
    ('52.112.124.211', IpKind.public, null, 'NL', 'The Netherlands', 'Microsoft Azure Cloud (westeurope)'),
    ('104.18.32.47', IpKind.public, null, 'US', 'United States', 'Cloudflare, Inc.'),
    ('35.186.224.25', IpKind.public, '25.224.186.35.bc.googleusercontent.com', 'US', 'United States', 'Google LLC'),
    ('17.57.146.20', IpKind.public, null, 'US', 'United States', 'Apple Inc.'),
    ('194.32.214.16', IpKind.public, 'hosted-by.webdade.cloud', 'IR', 'Iran', 'Web Dadeh Paydar Co (Ltd)'),
    ('151.101.1.140', IpKind.public, null, 'DE', 'Germany', 'Fastly, Inc.'),
    ('198.18.0.22', IpKind.fakeIp, null, null, null, null),
  ];
  await store.saveIpDetails([
    for (final (ip, kind, host, cc, country, org) in ips)
      IpDetails(ip: ip, kind: kind, host: host, countryCode: cc, country: country, org: org, updatedAt: now),
  ]);
  final flows = <(String, String, InterfaceKind, int)>[
    ('Google Chrome', '142.250.27.190', InterfaceKind.tunnel, 900000),
    ('Google Chrome', '104.18.32.47', InterfaceKind.tunnel, 420000),
    ('Google Chrome', '151.101.1.140', InterfaceKind.tunnel, 160000),
    ('Telegram', '149.154.167.91', InterfaceKind.tunnel, 380000),
    ('Microsoft Teams', '52.112.124.211', InterfaceKind.tunnel, 260000),
    ('Spotify', '35.186.224.25', InterfaceKind.tunnel, 520000),
    ('ChatGPT', '198.18.0.22', InterfaceKind.tunnel, 120000),
    ('Apple Push Notifications', '17.57.146.20', InterfaceKind.tunnel, 9000),
    ('IRNet', '142.250.27.190', InterfaceKind.tunnel, 7000),
    ('V2Box', '194.32.214.16', InterfaceKind.physical, 3000000),
  ];
  final counts = <UsageKey, (int, int)>{};
  final midnight = DateTime(now.year, now.month, now.day);
  final start = minuteStart(midnight.subtract(const Duration(hours: 20)));
  for (var ts = start; ts < minuteStart(now); ts += 60) {
    final hour = DateTime.fromMillisecondsSinceEpoch(ts * 1000).hour;
    final activity = (hour >= 9 && hour <= 23) ? 1.0 : 0.15;
    for (final (app, ip, iface, scale) in flows) {
      if (rnd.nextDouble() > 0.35) continue;
      final rx = (scale * activity * (0.2 + rnd.nextDouble())).round();
      counts[UsageKey(ts, app, ip, iface)] = (rx, (rx * (0.05 + rnd.nextDouble() * 0.2)).round());
    }
  }
  await store.add(counts);
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
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    // The global AppBloc creates a system-tray window handle on construction.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter/system_tray/app_window'), (call) async => null);
  });

  Future<void> setUpBlocs(WidgetTester tester) async {
    await tester.runAsync(() async {
      await _loadFonts();
      AppSharedPreferences.resetCache();
      SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
      db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
      final now = DateTime.now();
      await seedQuality(QualityStore(db), now);
      await _seedUsage(UsageStore(db), now);

      // Live probes over the last two minutes, with a few losses and a spike.
      var clock = now.subtract(const Duration(seconds: 118));
      final monitor = QualityMonitor(
        udp: ScriptedProber((i) => i % 17 == 5 ? null : (i % 23 == 0 ? 260 : 98 + (i * 37 % 19))),
        http: ScriptedProber((i) => i == 3 ? null : 118 + (i * 13 % 9)),
        clock: () => clock,
      );
      bloc.quality = QualityBloc(monitor: monitor, database: () async => db, callTester: InstantCallTester());
      bloc.usage = UsageBloc(
        httpClient: () => throw UnimplementedError(),
        collectorFactory: IdleCollector.new,
        database: () async => db,
        lookup: (_) async => const IpBatchResult([]),
        reverse: null,
      );
      await bloc.quality.initialize();
      await bloc.usage.initialize();
      bloc.quality.onIpLookup({
        'query': '172.233.41.190',
        'country': 'The Netherlands',
        'countryCode': 'NL',
        'regionName': 'North Holland',
        'city': 'Amsterdam',
        'isp': 'Akamai Technologies, Inc.',
      });
      for (var i = 0; i < 60; i++) {
        await monitor.runTick();
        clock = clock.add(const Duration(seconds: 2));
      }
      await bloc.quality.reload();
      await bloc.usage.reload();
    });
  }

  Future<void> tearDownBlocs(WidgetTester tester) async {
    await tester.runAsync(() async {
      await bloc.quality.dispose();
      await bloc.usage.dispose();
      await db.close();
    });
  }

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(theme: buildAppTheme(), debugShowCheckedModeBanner: false, home: const AppShell()),
    ));
    await tester.pump();
  }

  /// Lets real async work (database reloads triggered by navigation) finish,
  /// then renders twice: newly mounted StreamBuilders get their replayed value
  /// one frame after they subscribe.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Network quality section: live card, comparison, history, hover', (tester) async {
    await setUpBlocs(tester);
    // The app's default window width (main.dart opens 1000 × 780).
    await pumpShell(tester, const Size(1000, 2000));
    await tester.tap(find.text('Network quality').first);
    await settle(tester);

    expect(find.byType(QualitySection), findsOneWidget);
    expect(find.text('Amsterdam, The Netherlands'), findsWidgets);
    expect(find.text('COMPARE SERVERS'), findsOneWidget);
    expect(find.text('Hetzner DE #2'), findsOneWidget, reason: 'user label replaces the place');
    expect(find.text('Istanbul, Turkey'), findsOneWidget);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('LIVE'), findsNothing, reason: 'monitor is paused in this test');
    expect(find.text('ONLINE CALLS'), findsOneWidget);
    expect(find.text('Run a call test to check bandwidth for video'), findsOneWidget,
        reason: 'no test on the current server yet');
    await _shot(tester, 'quality_desktop');

    // Simulated call on the current server.
    await tester.tap(find.text('Test a call'));
    await settle(tester);
    expect(find.text('LAST CALL TEST'), findsOneWidget);
    expect(find.textContaining('Full HD 1080p'), findsWidgets);
    await _shot(tester, 'quality_calltest');

    // Hover the history chart: the tooltip lists every series at that time.
    final chart = find.byType(QualityHistoryChart);
    final box = tester.getRect(chart);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.center);
    await mouse.moveTo(Offset(box.left + box.width * 0.42, box.top + 60));
    await tester.pump();
    expect(find.byType(ChartTooltip), findsOneWidget);
    expect(find.text('Packet loss'), findsWidgets);
    await _shot(tester, 'quality_hover');
    await mouse.removePointer();

    // Group by location, select a row → history scoped to it.
    await tester.tap(find.text('By location'));
    await settle(tester);
    expect(find.text('COMPARE LOCATIONS'), findsOneWidget);
    await tester.tap(find.text('Istanbul, Turkey'));
    await settle(tester);
    expect(find.text('HISTORY · ISTANBUL, TURKEY'), findsOneWidget);

    // Table twin of the chart.
    await tester.tap(find.text('Table'));
    await tester.pump();
    expect(find.text('SCORE'), findsWidgets);
    await _shot(tester, 'quality_table');

    // A maximised window gets the full comparison table.
    tester.view.physicalSize = const Size(1500, 2000);
    await tester.tap(find.text('By IP'));
    await settle(tester);
    expect(find.text('MEASURED'), findsOneWidget, reason: 'column header of the wide table');
    await _shot(tester, 'quality_wide');

    await tearDownBlocs(tester);
  });

  testWidgets('Data usage section: totals, timeline, breakdown drill-down', (tester) async {
    await setUpBlocs(tester);
    await pumpShell(tester, const Size(1180, 1600));
    await tester.tap(find.text('Data usage').first);
    await settle(tester);

    expect(find.byType(UsageSection), findsOneWidget);
    expect(find.text('Google Chrome'), findsOneWidget);
    expect(find.textContaining('V2Box carried'), findsOneWidget, reason: 'VPN transport explained, hidden');
    expect(find.text('V2Box'), findsNothing);
    await _shot(tester, 'usage_desktop');

    // Ranges.
    await tester.tap(find.text('60 min'));
    await settle(tester);
    expect(find.textContaining('Internet usage · 60 min'), findsOneWidget);
    await tester.tap(find.text('Today'));
    await settle(tester);

    // Domains and countries tabs.
    await tester.tap(find.textContaining('Domains'));
    await tester.pump();
    expect(find.text('1e100.net'), findsOneWidget);
    expect(find.text('Hidden by VPN (fake IP)'), findsOneWidget);
    expect(find.text('Cloudflare, Inc.'), findsOneWidget);
    await _shot(tester, 'usage_domains');
    await tester.tap(find.textContaining('Countries'));
    await tester.pump();
    expect(find.text('United States'), findsOneWidget);

    // Drill down: Chrome → its domains.
    await tester.tap(find.textContaining('Apps'));
    await tester.pump();
    await tester.tap(find.text('Google Chrome'));
    await settle(tester);
    expect(find.text('App: Google Chrome'), findsOneWidget);
    expect(find.text('1e100.net'), findsOneWidget, reason: 'switched to the domains of Chrome');
    expect(find.text('Hidden by VPN (fake IP)'), findsNothing);
    await _shot(tester, 'usage_drilldown');

    // Show the VPN transport.
    await tester.tap(find.text('App: Google Chrome'));
    await settle(tester);
    await tester.tap(find.text('Show'));
    await settle(tester);
    await tester.tap(find.textContaining('Apps'));
    await tester.pump();
    expect(find.text('V2Box'), findsOneWidget);

    await tearDownBlocs(tester);
  });

  testWidgets('Export dialog: text summary, PDF report and CSV data', (tester) async {
    await setUpBlocs(tester);
    final fonts = (await tester.runAsync(
        () => ReportFonts.load((path) async => ByteData.sublistView(await File(path).readAsBytes()))))!;
    final delivery = RecordingDelivery();
    QualityExporter.create = () => QualityExporter(delivery: delivery, fonts: () async => fonts);
    addTearDown(() => QualityExporter.create = QualityExporter.new);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    /// Real async work (database, PDF) finishes between frames.
    Future<void> until(Finder finder) async {
      for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(finder, findsWidgets);
    }

    await pumpShell(tester, const Size(1000, 1400));
    await tester.tap(find.text('Network quality').first);
    await settle(tester);
    await tester.tap(find.widgetWithText(QualityExportButton, 'Export'));
    await until(find.text('Save PDF'));
    await tester.pump(const Duration(milliseconds: 300)); // dialog fade-in
    expect(find.text('Export network quality'), findsOneWidget);
    expect(find.text('Last 24 hours · All servers, compared by IP'), findsOneWidget);
    expect(find.textContaining('3 servers · '), findsOneWidget);
    await _shot(tester, 'quality_export_dialog');

    await tester.tap(find.text('Copy text summary'));
    await tester.pump();
    expect(clipboard, startsWith('IRNet network quality report\nPeriod: Last 24 hours'));
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copy text summary'), findsOneWidget);

    await tester.tap(find.text('Save PDF'));
    await until(find.textContaining('Saved IRNet-network-quality-'));
    final pdf = delivery.files.entries.single;
    expect(pdf.key, endsWith('.pdf'));
    expect(String.fromCharCodes(pdf.value.take(5)), '%PDF-');
    expect(find.text('/Users/test/Downloads'), findsOneWidget);
    await _shot(tester, 'quality_export_saved');
    await tester.tap(find.text('Open'));
    await tester.tap(find.text('Show in folder'));
    await tester.pump();
    expect(delivery.opened, ['/Users/test/Downloads/${pdf.key}']);
    expect(delivery.revealed, delivery.opened);

    await tester.tap(find.text('Save ZIP'));
    await until(find.textContaining('.zip'));
    expect(delivery.files.keys.last, endsWith('.zip'));

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Export network quality'), findsNothing);

    // On a phone the dialog shares instead of saving, and fits the width.
    delivery.files.clear();
    QualityExporter.create = () => QualityExporter(delivery: RecordingDelivery(share: true), fonts: () async => fonts);
    tester.view.physicalSize = const Size(360, 780);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Center(child: IntrinsicWidth(child: QualityExportButton()))),
      ),
    ));
    await tester.tap(find.text('Export'));
    await until(find.text('Share PDF'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Share ZIP'), findsOneWidget);
    await _shot(tester, 'quality_export_phone');
    await tester.tap(find.text('Share PDF'));
    await until(find.byType(QualityExportButton));
    for (var i = 0; i < 40 && find.text('Export network quality').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100)); // lets the close animation run
    }
    expect(find.text('Export network quality'), findsNothing, reason: 'closes once the share sheet opens');

    await tearDownBlocs(tester);
  });

  testWidgets('Overview shows the new summary cards; narrow layouts fit', (tester) async {
    await setUpBlocs(tester);
    await pumpShell(tester, const Size(1180, 1100));
    await settle(tester);
    expect(find.byType(QualitySummaryCard), findsOneWidget);
    expect(find.textContaining('Top app: Google Chrome'), findsOneWidget);
    await _shot(tester, 'overview_desktop');

    // Phone-width quality section (mobile tab) and a narrow usage section.
    tester.view.physicalSize = const Size(390, 2300);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(children: [QualitySection(compact: true), SizedBox(height: 24), UsageSection(compact: true)]),
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(find.text('COMPARE SERVERS'), findsOneWidget);
    expect(find.byType(CallQualityCard), findsOneWidget);
    await _shot(tester, 'mobile_sections');

    await tearDownBlocs(tester);
  });
}
