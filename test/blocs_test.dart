// End-to-end through the controllers: probes / collector deltas in, stored
// in an in-memory database, dashboard data out.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/call_quality.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/quality_bloc.dart';
import 'package:ir_net/usage_bloc.dart';
import 'package:ir_net/utils/call_tester.dart';
import 'package:ir_net/utils/ip_enricher.dart';
import 'package:ir_net/utils/quality_monitor.dart';
import 'package:ir_net/utils/quality_probes.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ScriptedProber implements RttProber {
  ScriptedProber(this.script);
  final List<double?> script;
  int calls = 0;

  @override
  Future<double?> probe() async => script[calls++ % script.length];

  @override
  void reset() {}

  @override
  void close() {}
}

class FakeCallTester extends CallTester {
  FakeCallTester({this.error});
  final Exception? error;

  @override
  Future<CallTestResult> run({required String server, void Function(CallTestProgress)? onProgress}) async {
    onProgress?.call(const CallTestProgress(CallTestPhase.voice, 0.3));
    if (error != null) throw error!;
    return CallTestResult(
      at: DateTime.now(),
      server: server,
      sent: 400,
      received: 398,
      late: 1,
      maxBurst: 2,
      burstRatio: 1.5,
      rttMedian: 104,
      rttP95: 140,
      jitter: 4,
      voice: CallQuality.estimate(kind: CallKind.voice, rttMs: 104, jitterMs: 4, lossPercent: 0.75),
      video: CallQuality.estimate(kind: CallKind.video, rttMs: 104, jitterMs: 4, lossPercent: 0.75),
      downMbps: 40,
      upMbps: 12,
    );
  }
}

class FakeCollector extends UsageCollector {
  final controller = StreamController<List<FlowDelta>>();
  bool stopped = false;

  @override
  String get source => 'fake';

  @override
  Stream<List<FlowDelta>> start() => controller.stream;

  @override
  Future<void> stop() async {
    stopped = true;
    await controller.close();
  }
}

void main() {
  late Database db;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    AppSharedPreferences.resetCache();
    db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
  });
  tearDown(() => db.close());

  group('QualityBloc', () {
    test('attributes probes to the exit IP and serves live + history data', () async {
      // Monitoring "off" so no timer ticks; the test drives the ticks.
      SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
      final monitor = QualityMonitor(
        udp: ScriptedProber([100, 110, null, 105]),
        http: ScriptedProber([150]),
      );
      final quality = QualityBloc(monitor: monitor, database: () async => db);
      await quality.initialize();

      quality.onIpLookup({
        'query': '203.0.113.9',
        'country': 'Germany',
        'countryCode': 'DE',
        'regionName': 'Hesse',
        'city': 'Frankfurt am Main',
        'isp': 'Hetzner Online GmbH',
      });
      for (var i = 0; i < 4; i++) {
        await monitor.runTick();
      }
      await pumpEventQueue(); // live state follows the monitor's change events

      final live = await quality.live.first;
      expect(live.server!.city, 'Frankfurt am Main');
      expect(live.running, isFalse);
      expect(live.recent.udp.sent, 4);
      expect(live.recent.udp.received, 3);
      expect(live.samples, hasLength(5), reason: '4 UDP + 1 HTTPS');

      await quality.reload();
      final dashboard = await quality.dashboard.first;
      final row = dashboard.rows.single;
      expect(row.info.isp, 'Hetzner Online GmbH');
      expect(dashboard.isCurrent(row), isTrue);
      expect(row.stats.lossPercent, 25);
      expect(dashboard.bins, isNotEmpty);

      quality.toggleSelected(row.key);
      await quality.reload();
      expect((await quality.dashboard.first).selectedRow?.key, row.key);

      await quality.rename(row.key, 'Hetzner #2');
      expect((await quality.dashboard.first).rows.single.info.label, 'Hetzner #2');

      await quality.clearHistory();
      expect((await quality.dashboard.first).rows, isEmpty);
      await quality.dispose();
    });

    test('runs a call test, stores it and lists it with its server', () async {
      SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
      final quality = QualityBloc(
        monitor: QualityMonitor(udp: ScriptedProber([50]), http: ScriptedProber([60])),
        database: () async => db,
        callTester: FakeCallTester(),
      );
      await quality.initialize();
      quality.onIpLookup({'query': '203.0.113.9', 'country': 'Germany', 'countryCode': 'DE', 'city': 'Berlin'});
      final states = <CallTestStatus>[];
      final sub = quality.callTest.listen((s) => states.add(s.status));
      await quality.runCallTest();
      await pumpEventQueue();
      expect(states, containsAllInOrder([CallTestStatus.running, CallTestStatus.done]));
      final tests = await quality.callTests.first;
      expect(tests.single.result.server, '203.0.113.9');
      expect(tests.single.server?.city, 'Berlin');
      expect(tests.single.result.tier, VideoTier.fullHd);
      await quality.clearHistory();
      expect(await quality.callTests.first, isEmpty);
      await sub.cancel();
      await quality.dispose();
    });

    test('a call test without UDP reports why', () async {
      SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
      final quality = QualityBloc(
        monitor: QualityMonitor(udp: ScriptedProber([50]), http: ScriptedProber([60])),
        database: () async => db,
        callTester: FakeCallTester(error: const ProbeUnavailable('UDP socket unavailable: denied')),
      );
      await quality.initialize();
      await quality.runCallTest();
      final state = await quality.callTest.first;
      expect(state.status, CallTestStatus.failed);
      expect(state.error, contains('UDP socket unavailable'));
      await quality.dispose();
    });

    test('pausing and resuming the monitor persists the setting', () async {
      SharedPreferences.setMockInitialValues({'flutter.qualityMonitoring': false});
      final quality = QualityBloc(
        monitor: QualityMonitor(udp: ScriptedProber([50]), http: ScriptedProber([60])),
        database: () async => db,
      );
      await quality.initialize();
      await quality.setEnabled(true);
      await pumpEventQueue();
      expect((await quality.live.first).running, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('qualityMonitoring'), isTrue);
      await quality.setEnabled(false);
      expect((await quality.live.first).running, isFalse);
      await quality.dispose();
    });
  });

  group('UsageBloc', () {
    test('records deltas, skips local traffic, enriches and filters', () async {
      SharedPreferences.setMockInitialValues({});
      final collector = FakeCollector();
      final lookups = <List<String>>[];
      final usage = UsageBloc(
        httpClient: () => throw UnimplementedError('no network in tests'),
        collectorFactory: () => collector,
        database: () async => db,
        reverse: null,
        lookup: (ips) async {
          lookups.add(ips);
          return IpBatchResult([
            for (final ip in ips)
              IpDetails.fromGeoJs(
                  {'ip': ip, 'country': 'Germany', 'country_code': 'DE', 'organization_name': 'Example GmbH'},
                  DateTime.now()),
          ]);
        },
      );
      await usage.initialize();
      expect((await usage.status.first).state, UsageCollectorState.running);

      collector.controller.add(const [
        FlowDelta(app: 'Firefox', remoteIp: '203.0.113.5', remotePort: 443, iface: InterfaceKind.tunnel, rx: 1000, tx: 100),
        FlowDelta(app: 'Firefox', remoteIp: '198.18.0.7', remotePort: 443, iface: InterfaceKind.tunnel, rx: 50, tx: 5),
        FlowDelta(app: 'macOS DNS', remoteIp: '', localPort: 5353, iface: InterfaceKind.physical, rx: 900, tx: 0),
        FlowDelta(app: 'Printer', remoteIp: '192.168.1.20', remotePort: 9100, iface: InterfaceKind.physical, rx: 700, tx: 700),
        FlowDelta(app: 'V2Box', remoteIp: '198.51.100.16', remotePort: 21019, iface: InterfaceKind.physical, rx: 1200, tx: 150),
      ]);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50)); // enricher batch timer

      await usage.reload();
      var view = await usage.view.first;
      expect(view.total, 1155, reason: 'LAN + mDNS skipped, VPN transport hidden');
      expect(view.hiddenVpnBytes, 1350);
      expect(lookups.single, ['203.0.113.5'],
          reason: 'fake IPs, LAN addresses and the VPN server (V2Box) are never sent out');
      final countries = view.entries[UsageDimension.country]!.map((e) => e.key).toList();
      expect(countries, ['DE', '']);
      expect(view.entries[UsageDimension.domain]!.first.key, '@Example GmbH');
      expect(view.timeline.single.total, 1155);

      usage.setIncludeVpnTransport(true);
      await usage.reload();
      view = await usage.view.first;
      expect(view.total, 1155 + 1350);
      expect(view.timeline.single.total, 1155 + 1350);

      usage.setDimensionFilter(UsageDimension.app, 'Firefox');
      await usage.reload();
      view = await usage.view.first;
      expect(view.entries[UsageDimension.app]!.single.key, 'Firefox');

      usage.setRange(UsageRange.yesterday);
      await usage.reload();
      expect((await usage.view.first).total, 0);

      await usage.setTracking(false);
      expect(collector.stopped, isTrue);
      expect((await usage.status.first).state, UsageCollectorState.paused);
      await usage.dispose();
    });

    test('a failing collector reports its error', () async {
      SharedPreferences.setMockInitialValues({});
      final collector = FakeCollector();
      final usage = UsageBloc(
        httpClient: () => throw UnimplementedError(),
        collectorFactory: () => collector,
        database: () async => db,
        lookup: (_) async => const IpBatchResult([]),
        reverse: null,
      );
      await usage.initialize();
      collector.controller.addError(Exception('nettop exited with code 1'));
      await pumpEventQueue();
      final status = await usage.status.first;
      expect(status.state, UsageCollectorState.failed);
      expect(status.message, 'nettop exited with code 1');
      await usage.dispose();
    });
  });
}
