import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/data/quality_store.dart';
import 'package:ir_net/utils/quality_monitor.dart';
import 'package:ir_net/utils/quality_probes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Returns scripted round-trip times (null = lost).
class ScriptedProber implements RttProber {
  ScriptedProber(this.script);

  final List<double?> script;
  int calls = 0;
  int resets = 0;

  @override
  Future<double?> probe() async {
    final value = calls < script.length ? script[calls] : script.last;
    calls++;
    return value;
  }

  @override
  void reset() => resets++;

  @override
  void close() {}
}

/// UDP that can't open a socket (e.g. a sandbox without the entitlement).
class UnavailableProber implements RttProber {
  int calls = 0;

  @override
  Future<double?> probe() async {
    calls++;
    throw const ProbeUnavailable('UDP socket unavailable: Operation not permitted');
  }

  @override
  void reset() {}

  @override
  void close() {}
}

/// HTTPS probe that only finishes when the test says so.
class GatedProber implements RttProber {
  final gates = <Completer<double?>>[];

  @override
  Future<double?> probe() {
    final gate = Completer<double?>();
    gates.add(gate);
    return gate.future;
  }

  @override
  void reset() {}

  @override
  void close() {}
}

void main() {
  group('score', () {
    test('E-model R-factor matches the reference formula', () {
      // effective = 100 + 2*5 + 10 = 120 → 93.2 - 3 = 90.2
      expect(QualityScore.rFactor(latencyMs: 100, jitterMs: 5, lossPercent: 0), closeTo(90.2, 1e-9));
      // effective = 200 + 40 + 10 = 250 → 93.2 - 13 = 80.2, minus 2.5 per % loss
      expect(QualityScore.rFactor(latencyMs: 200, jitterMs: 20, lossPercent: 1), closeTo(77.7, 1e-9));
      expect(QualityScore.rFactor(latencyMs: 2000, jitterMs: 500, lossPercent: 50), 0);
    });

    test('grades and scaling', () {
      expect(QualityScore.fromR(93.2).value, 100);
      expect(QualityScore.fromR(90.2).grade, QualityGrade.excellent); // 97
      expect(QualityScore.fromR(77.7).grade, QualityGrade.good); // 83
      expect(QualityScore.fromR(56.7).grade, QualityGrade.fair); // 61
      expect(QualityScore.fromR(40).grade, QualityGrade.poor); // 43
      expect(QualityScore.fromR(9.2).grade, QualityGrade.bad); // 10
    });

    test('loss weighs heavily', () {
      QualityScore score(double loss) => QualityScore.fromR(
          QualityScore.rFactor(latencyMs: 80, jitterMs: 4, lossPercent: loss));
      expect(score(0).grade, QualityGrade.excellent);
      expect(score(5).grade, QualityGrade.good);
      expect(score(15).grade, QualityGrade.poor);
    });
  });

  group('stats', () {
    test('jitter is the mean difference between consecutive replies', () {
      final s = SeriesStats();
      s.addReply(100);
      s.addReply(110, previous: 100);
      s.addLost();
      s.addReply(90, previous: 110);
      expect(s.sent, 4);
      expect(s.received, 3);
      expect(s.avgRtt, 100);
      expect(s.rttMin, 90);
      expect(s.rttMax, 110);
      expect(s.jitter, 15); // (10 + 20) / 2
      expect(s.lossPercent, 25);
    });

    test('merging is exact', () {
      final a = SeriesStats()..addReply(10)..addReply(30, previous: 10);
      final b = SeriesStats()..addLost()..addReply(50);
      final m = SeriesStats()..merge(a)..merge(b);
      expect(m.sent, 4);
      expect(m.received, 3);
      expect(m.avgRtt, 30);
      expect(m.rttMin, 10);
      expect(m.rttMax, 50);
      expect(m.jitter, 20);
    });

    test('falls back to HTTPS when the VPN does not carry UDP', () {
      final s = QualityStats();
      for (var i = 0; i < 5; i++) {
        s.udp.addLost();
      }
      s.http.addReply(150);
      s.http.addReply(160, previous: 150);
      expect(s.udpBlocked, isTrue);
      expect(s.latency, 155);
      expect(s.lossPercent, 0, reason: 'HTTPS loss, not the blocked UDP');
      expect(s.score!.grade, QualityGrade.excellent);
    });

    test('a full outage with only HTTPS probes is "down", not "no data"', () {
      final s = QualityStats()..ticks = 2;
      s.http.addLost();
      s.http.addLost();
      expect(s.score!.grade, QualityGrade.down);
    });

    test('no replies at all is "down"', () {
      final s = QualityStats()..ticks = 3;
      s.udp.addLost();
      s.http.addLost();
      expect(s.score!.grade, QualityGrade.down);
      expect(QualityStats().score, isNull);
    });
  });

  group('QualityMonitor', () {
    late DateTime now;
    setUp(() => now = DateTime.utc(2026, 10, 26, 10, 0, 5));

    QualityMonitor monitor(List<double?> udp, List<double?> http, {VoidCallback? onRecovered}) =>
        QualityMonitor(
          udp: ScriptedProber(udp),
          http: ScriptedProber(http),
          httpEvery: 2,
          clock: () => now,
          onRecovered: onRecovered,
        );

    test('aggregates a minute per server', () async {
      final m = monitor([100, 120, null, 110], [200, 210])..setServer('203.0.113.7');
      for (var i = 0; i < 4; i++) {
        await m.runTick();
        now = now.add(const Duration(seconds: 2));
      }
      final windows = m.takeDirtyWindows();
      expect(windows, hasLength(1));
      final w = windows.single;
      expect(w.server, '203.0.113.7');
      expect(w.start, DateTime.utc(2026, 10, 26, 10).millisecondsSinceEpoch ~/ 1000);
      expect(w.ticks, 4);
      expect(w.udp.sent, 4);
      expect(w.udp.received, 3);
      expect(w.udp.jitter, 15); // |120-100| then |110-120|
      expect(w.http.sent, 2, reason: 'HTTPS every 2nd tick');
      expect(w.downTicks, 0, reason: 'UDP loss alone is not an outage');
      expect(m.takeDirtyWindows(), isEmpty, reason: 'already taken');
    });

    test('an outage is counted when both probes fail; recovery triggers the callback', () async {
      var recovered = 0;
      final m = monitor([null, null, null, 90], [null, null, 100], onRecovered: () => recovered++)
        ..setServer('a');
      for (var i = 0; i < 4; i++) {
        await m.runTick();
      }
      final w = m.takeDirtyWindows().single;
      expect(w.downTicks, 3);
      expect(w.uptimePercent, 25);
      expect(recovered, 1);
    });

    test('switching server starts a new window and resets jitter', () async {
      final m = monitor([100, 140, 300, 310], [null])..setServer('a');
      await m.runTick();
      await m.runTick();
      m.setServer('b');
      await m.runTick();
      await m.runTick();
      final windows = {for (final w in m.takeDirtyWindows()) w.server: w};
      expect(windows.keys, {'a', 'b'});
      expect(windows['a']!.udp.jitter, 40);
      expect(windows['b']!.udp.jitter, 10, reason: 'the 140→300 jump crosses servers');
      expect(m.recentStats(const Duration(minutes: 5)).udp.received, 2,
          reason: 'live stats cover the current server only');
    });

    test('minute boundaries split windows; old ones are evicted once persisted', () async {
      now = DateTime.utc(2026, 10, 26, 10, 0, 58);
      final m = monitor([50], [60])..setServer('a');
      await m.runTick();
      now = now.add(const Duration(seconds: 4));
      await m.runTick();
      expect(m.takeDirtyWindows().map((w) => w.start).toSet(), hasLength(2));
      now = now.add(const Duration(minutes: 10));
      // The gap reads as a wake: counted once the connection has held.
      for (var i = 0; i < 3; i++) {
        await m.runTick();
      }
      expect(m.takeDirtyWindows(), hasLength(1));
      // Rewriting an evicted minute must not happen: only the new one is dirty.
    });

    test('a UDP socket that cannot be opened is not packet loss', () async {
      final http = ScriptedProber([120]);
      final m = QualityMonitor(udp: UnavailableProber(), http: http, httpEvery: 5, clock: () => now)
        ..setServer('a');
      for (var i = 0; i < 4; i++) {
        await m.runTick();
      }
      final w = m.takeDirtyWindows().single;
      expect(w.udp.sent, 0, reason: 'nothing was sent, so nothing was lost');
      expect(w.http.sent, 2, reason: 'HTTPS takes over, every other tick');
      expect(w.downTicks, 0);
      expect(m.udpUnavailable, contains('Operation not permitted'));
      expect(w.score!.grade, QualityGrade.excellent);
    });

    test('a slow HTTPS probe is not overlapped by the next one', () async {
      final http = GatedProber();
      final m = QualityMonitor(udp: ScriptedProber([50]), http: http, httpEvery: 1, clock: () => now)
        ..setServer('a');
      final first = m.runTick(); // HTTPS still pending
      await pumpEventQueue();
      await m.runTick();
      await m.runTick();
      expect(http.gates, hasLength(1), reason: 'skipped while one is in flight');
      http.gates.single.complete(80);
      await first;
      final fourth = m.runTick();
      await pumpEventQueue();
      expect(http.gates, hasLength(2), reason: 'free again once the slow one finished');
      http.gates.last.complete(81);
      await fourth;
      expect(m.takeDirtyWindows().single.http.received, 2);
    });

    test('monitored time is the sum of probe intervals', () async {
      final m = QualityMonitor(
          udp: ScriptedProber([50]), http: ScriptedProber([60]), interval: const Duration(seconds: 5), clock: () => now)
        ..setServer('a');
      await m.runTick();
      await m.runTick();
      expect(m.takeDirtyWindows().single.seconds, 10);
    });

    test('failures while reconnecting after a wake are not counted', () async {
      final m = monitor([50, null, null, null, 60, 61, 62], [null])..setServer('a');
      await m.runTick();
      m
        ..onSleep()
        ..onWake();
      expect(m.settling, isTrue);
      for (var i = 0; i < 5; i++) {
        await m.runTick();
      }
      expect(m.takeDirtyWindows().single.ticks, 1, reason: 'held until the connection holds');
      await m.runTick();
      expect(m.settling, isFalse);
      final w = m.takeDirtyWindows().single;
      expect(w.ticks, 4, reason: 'the tick before sleep and the three after reconnecting');
      expect(w.downTicks, 0);
      expect(w.udp.received, 4);
      expect(m.recentStats(const Duration(minutes: 5)).downTicks, 0);
    });

    test('a connection still failing after the wake grace is a real outage', () async {
      final m = QualityMonitor(
        udp: ScriptedProber([null]),
        http: ScriptedProber([null]),
        wakeGrace: const Duration(seconds: 10),
        clock: () => now,
      )..setServer('a');
      m.onWake();
      for (var i = 0; i < 6; i++) {
        await m.runTick();
        now = now.add(const Duration(seconds: 2));
      }
      expect(m.settling, isFalse);
      expect(m.takeDirtyWindows().single.downTicks, 6, reason: 'held ticks are kept from the wake on');
      await m.runTick();
      expect(m.takeDirtyWindows().single.downTicks, 7);
    });

    test('a gap between ticks is treated as a wake', () async {
      final m = monitor([50, null, 60, 61, 62], [null])..setServer('a');
      await m.runTick();
      m.takeDirtyWindows();
      now = now.add(const Duration(minutes: 5));
      await m.runTick();
      await m.runTick();
      expect(m.settling, isTrue);
      expect(m.takeDirtyWindows(), isEmpty);
      for (var i = 0; i < 3; i++) {
        await m.runTick();
      }
      expect(m.settling, isFalse);
      final w = m.takeDirtyWindows().single;
      expect(w.downTicks, 0);
      expect(w.ticks, 4, reason: 'three that settled it, then one counted directly');
    });

    test('probes in flight when the system sleeps are dropped', () async {
      final udp = GatedProber();
      final m = QualityMonitor(udp: udp, http: ScriptedProber([null]), clock: () => now)..setServer('a');
      final tick = m.runTick();
      await pumpEventQueue();
      m.onSleep();
      udp.gates.single.complete(null);
      await tick;
      await m.runTick();
      expect(udp.gates, hasLength(1), reason: 'no probes while asleep');
      expect(m.takeDirtyWindows(), isEmpty);
    });

    test('a missed wake notification is caught by the next tick', () async {
      final m = monitor([50], [60])..setServer('a');
      m.onSleep();
      now = now.add(const Duration(minutes: 1));
      await m.runTick();
      expect(m.settling, isTrue);
    });

    test('a tick spanning a suspension is dropped', () async {
      final udp = GatedProber();
      final m = QualityMonitor(udp: udp, http: ScriptedProber([null]), clock: () => now)..setServer('a');
      final tick = m.runTick();
      await pumpEventQueue();
      now = now.add(const Duration(minutes: 3));
      udp.gates.single.complete(null);
      await tick;
      expect(m.settling, isTrue);
      expect(m.takeDirtyWindows(), isEmpty);
    });

    test('network change resets the probers', () {
      final udp = ScriptedProber([1]);
      final http = ScriptedProber([1]);
      QualityMonitor(udp: udp, http: http).onNetworkChanged();
      expect(udp.resets, 1);
      expect(http.resets, 1);
    });

    test('timer-driven ticks follow the interval', () {
      fakeAsync((async) {
        final udp = ScriptedProber([10]);
        final m = QualityMonitor(udp: udp, http: ScriptedProber([20]), interval: const Duration(seconds: 2));
        m.start();
        async.elapse(const Duration(seconds: 10));
        expect(udp.calls, 6, reason: 'one immediate tick + one every 2s');
        m.stop();
        async.elapse(const Duration(seconds: 10));
        expect(udp.calls, 6);
        m.dispose();
      });
    });
  });

  test('a version 1 database is migrated in place', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('irnet_db');
    final path = '${dir.path}/irnet.db';
    final v1 = await databaseFactoryFfiNoIsolate.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE quality_minute (ts INTEGER NOT NULL, server TEXT NOT NULL, '
                'ticks INTEGER NOT NULL DEFAULT 0, down_ticks INTEGER NOT NULL DEFAULT 0, '
                'PRIMARY KEY (ts, server))');
            await db.insert('quality_minute', {'ts': 60, 'server': 'a', 'ticks': 30});
          },
        ));
    await v1.close();
    final v2 = await AppDatabase.openAt(path, factory: databaseFactoryFfiNoIsolate);
    final row = (await v2.rawQuery('SELECT ticks, secs FROM quality_minute')).single;
    expect(row, {'ticks': 30, 'secs': 0});
    expect(await v2.rawQuery('SELECT * FROM call_test'), isEmpty);
    expect(await v2.getVersion(), 2);
    await v2.close();
    await dir.delete(recursive: true);
  });

  group('QualityStore', () {
    late Database db;
    late QualityStore store;

    setUpAll(sqfliteFfiInit);
    setUp(() async {
      db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
      store = QualityStore(db);
    });
    tearDown(() => db.close());

    QualityWindow window(int start, String server, {required List<double?> udp, int down = 0}) {
      final w = QualityWindow(start, server)
        ..ticks = udp.length
        ..downTicks = down;
      double? prev;
      for (final r in udp) {
        if (r == null) {
          w.udp.addLost();
        } else {
          w.udp.addReply(r, previous: prev);
          prev = r;
        }
      }
      w.http.addReply(150);
      return w;
    }

    test('compare ranks servers by score and keeps metadata', () async {
      final t = DateTime.utc(2026, 10, 26, 10);
      await store.touchServer(
          const ServerInfo(ip: '203.0.113.1', country: 'Germany', countryCode: 'DE', city: 'Frankfurt'), t);
      await store.touchServer(
          const ServerInfo(ip: '198.51.100.2', country: 'Netherlands', countryCode: 'NL', city: 'Amsterdam'), t);
      final base = t.millisecondsSinceEpoch ~/ 1000;
      await store.saveWindows([
        window(base, '203.0.113.1', udp: [300, 400, null, null]),
        window(base + 60, '203.0.113.1', udp: [350, null, 300, 310]),
        window(base, '198.51.100.2', udp: [80, 82, 81, 79]),
      ]);
      final rows = await store.compare(from: base, to: base + 3600);
      expect(rows.map((r) => r.key), ['198.51.100.2', '203.0.113.1']);
      final bad = rows.last;
      expect(bad.info.city, 'Frankfurt');
      expect(bad.stats.udp.sent, 8);
      expect(bad.stats.udp.received, 5);
      expect(bad.stats.ticks, 8);
      expect(bad.firstTs, base);
      expect(bad.lastTs, base + 60);
      expect(rows.first.stats.score!.grade, QualityGrade.excellent);
    });

    test('probes sent before the public IP was known are not a server', () async {
      await store.saveWindows([window(0, '', udp: [null, null]), window(0, 'a', udp: [100])]);
      final rows = await store.compare(from: 0, to: 3600);
      expect(rows.map((r) => r.key), ['a']);
      final bins = await store.history(from: 0, to: 3600, binSeconds: 3600);
      expect(bins.single.stats.udp.sent, 3, reason: 'history still shows the outage');
    });

    test('saving a window again replaces it (idempotent)', () async {
      final w = window(600, 'a', udp: [10]);
      await store.saveWindows([w]);
      w.udp.addReply(20, previous: 10);
      w.ticks++;
      await store.saveWindows([w]);
      final rows = await store.compare(from: 0, to: 10000);
      expect(rows.single.stats.udp.received, 2);
      expect(rows.single.stats.ticks, 2);
    });

    test('location grouping merges IPs of the same city', () async {
      final t = DateTime.utc(2026, 10, 26);
      for (final ip in ['203.0.113.1', '203.0.113.2']) {
        await store.touchServer(
            ServerInfo(ip: ip, country: 'Germany', countryCode: 'DE', city: 'Frankfurt'), t);
      }
      await store.saveWindows([
        window(0, '203.0.113.1', udp: [100]),
        window(60, '203.0.113.2', udp: [120]),
      ]);
      final rows = await store.compare(from: 0, to: 3600, grouping: QualityGrouping.location);
      expect(rows, hasLength(1));
      expect(rows.single.key, 'DE|Frankfurt');
      expect(rows.single.ips, unorderedEquals(['203.0.113.1', '203.0.113.2']));
      expect(rows.single.stats.udp.avgRtt, 110);
    });

    test('history bins align to local time and filter by server', () async {
      // Iran is UTC+03:30, so local hours start at :30 UTC.
      const offset = Duration(hours: 3, minutes: 30);
      final base = DateTime.utc(2026, 10, 26, 6, 30).millisecondsSinceEpoch ~/ 1000;
      await store.saveWindows([
        window(base - 60, 'a', udp: [100]), // previous local hour
        window(base, 'a', udp: [200]),
        window(base + 1800, 'a', udp: [300]),
        window(base + 1800, 'b', udp: [999]),
      ]);
      final bins = await store.history(
          from: 0, to: base + 7200, binSeconds: 3600, utcOffset: offset, servers: ['a']);
      expect(bins.map((b) => b.start), [base - 3600, base]);
      expect(bins.last.stats.udp.avgRtt, 250);
      final all = await store.history(from: 0, to: base + 7200, binSeconds: 3600, utcOffset: offset);
      expect(all.last.stats.udp.received, 3);
    });

    test('stored durations drive "measured", legacy rows count 2 s a tick', () async {
      final w = window(0, 'a', udp: [10, 11])..seconds = 10; // 2 ticks at 5 s
      await store.saveWindows([w, window(60, 'b', udp: [10, 11, 12])..seconds = 0]);
      final rows = {for (final r in await store.compare(from: 0, to: 3600)) r.key: r};
      expect(rows['a']!.monitored, const Duration(seconds: 10));
      expect(rows['b']!.monitored, const Duration(seconds: 6));
    });

    test('labels, pruning and clearing', () async {
      final now = DateTime.utc(2026, 10, 26);
      await store.touchServer(const ServerInfo(ip: 'a'), now);
      await store.setLabel('a', '  Hetzner #2 ');
      expect((await store.servers())['a']!.label, 'Hetzner #2');
      await store.setLabel('a', '');
      expect((await store.servers())['a']!.label, isNull);

      final old = now.subtract(const Duration(days: 100)).millisecondsSinceEpoch ~/ 1000;
      final recent = now.millisecondsSinceEpoch ~/ 1000;
      await store.saveWindows([window(old, 'a', udp: [1]), window(recent, 'a', udp: [1])]);
      await store.prune(now);
      expect(await store.firstTimestamp(), recent);
      await store.clear();
      expect(await store.firstTimestamp(), isNull);
      expect(await store.servers(), isEmpty);
    });
  });
}
