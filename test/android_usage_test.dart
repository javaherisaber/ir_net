// The Android collector against a mocked `ir_net/net_usage` channel, and the
// usage bloc's "needs usage access" flow.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/usage_bloc.dart';
import 'package:ir_net/utils/ip_enricher.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const channel = MethodChannel('ir_net/net_usage');

/// Fake NetworkStatsManager: cumulative bytes per uid, plus a daily history.
class FakeStats {
  bool access = true;
  final totals = <int, (String, int, int)>{};
  final calls = <MethodCall>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'hasUsageAccess':
        return access;
      case 'openUsageAccessSettings':
        return null;
      case 'querySummary':
        if (!access) throw PlatformException(code: 'NO_ACCESS', message: 'denied');
        final args = call.arguments as Map;
        final start = DateTime.fromMillisecondsSinceEpoch(args['start'] as int);
        final end = DateTime.fromMillisecondsSinceEpoch(args['end'] as int);
        // History queries (a day or less, in the past): 1 MB per app per day,
        // spread evenly over the period.
        if (end.difference(start) <= const Duration(days: 1) && !end.isAfter(DateTime.now())) {
          final share = end.difference(start).inMinutes / const Duration(days: 1).inMinutes;
          return [
            for (final e in totals.entries)
              {
                'uid': e.key,
                'package': 'pkg.${e.key}',
                'name': e.value.$1,
                'rx': (1000000 * share).round(),
                'tx': (100000 * share).round(),
              },
          ];
        }
        return [
          for (final e in totals.entries)
            {'uid': e.key, 'package': 'pkg.${e.key}', 'name': e.value.$1, 'rx': e.value.$2, 'tx': e.value.$3},
        ];
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeStats stats;

  setUp(() {
    stats = FakeStats();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, stats.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('AndroidUsageCollector', () {
    test('first poll is a baseline; later polls give per-app deltas', () async {
      stats.totals[10123] = ('Telegram', 5000, 500);
      stats.totals[1000] = ('Android system', 100, 10);
      final collector = AndroidUsageCollector(interval: const Duration(milliseconds: 30));
      final batches = <List<FlowDelta>>[];
      final sub = collector.start().listen(batches.add);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      stats.totals[10123] = ('Telegram', 9000, 700);
      stats.totals[10200] = ('Instagram', 300, 30); // new app since baseline
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();
      await collector.stop();
      final deltas = batches.expand((b) => b).toList();
      expect({for (final d in deltas) d.app: (d.rx, d.tx)}, {'Telegram': (4000, 200), 'Instagram': (300, 30)});
      expect(deltas.every((d) => d.remoteIp.isEmpty && d.iface == InterfaceKind.other), isTrue);
      expect(collector.hasDestinations, isFalse);

      final query = stats.calls.firstWhere((c) => c.method == 'querySummary');
      final start = (query.arguments as Map)['start'] as int;
      expect(start % const Duration(hours: 2).inMilliseconds, 0, reason: 'aligned to a stats bucket');
    });

    test('counters that go backwards (expired history) are not negative usage', () async {
      stats.totals[10123] = ('Telegram', 5000, 500);
      final collector = AndroidUsageCollector(interval: const Duration(milliseconds: 20));
      final batches = <List<FlowDelta>>[];
      final sub = collector.start().listen(batches.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      stats.totals[10123] = ('Telegram', 10, 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      await collector.stop();
      expect(batches, isEmpty);
    });

    test('setup asks for usage access until it is granted', () async {
      final collector = AndroidUsageCollector();
      stats.access = false;
      final setup = await collector.checkSetup();
      expect(setup?.actionLabel, 'Open settings');
      await collector.requestSetup();
      expect(stats.calls.map((c) => c.method), contains('openUsageAccessSettings'));
      stats.access = true;
      expect(await collector.checkSetup(), isNull);
    });

    test('revoking access stops the stream with an error', () async {
      stats.totals[1] = ('x', 1, 1);
      final collector = AndroidUsageCollector(interval: const Duration(milliseconds: 20));
      final errors = <Object>[];
      final done = Completer<void>();
      collector.start().listen((_) {}, onError: errors.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      stats.access = false;
      await done.future.timeout(const Duration(seconds: 2));
      expect('${errors.single}', contains('Usage access was turned off'));
    });

    test('past usage: daily totals, then hourly for the last two days', () async {
      stats.totals[10123] = ('Telegram', 0, 0);
      final now = DateTime(2026, 10, 26, 15, 30);
      final past = await AndroidUsageCollector().pastUsage(until: now, days: 5);
      final ms = now.millisecondsSinceEpoch;
      final recentFrom = DateTime.fromMillisecondsSinceEpoch(ms - ms % 7200000 - 46 * 3600000);
      final daily = past.where((p) => p.start.isBefore(recentFrom)).toList();
      final hourly = past.where((p) => !p.start.isBefore(recentFrom)).toList();
      expect(daily.first.start, DateTime(2026, 10, 22));
      expect(daily.first.rx, 1000000, reason: 'a whole day');
      expect(hourly.length, greaterThanOrEqualTo(46));
      for (var i = 1; i < hourly.length; i++) {
        expect(hourly[i].start.difference(hourly[i - 1].start), const Duration(hours: 1));
      }
      final total = past.fold<int>(0, (s, p) => s + p.rx);
      expect(total, closeTo(1000000 * (4 + 15.5 / 24), 2000), reason: 'nothing counted twice or lost');
    });
  });

  group('UsageBloc on Android', () {
    late Database db;

    setUpAll(sqfliteFfiInit);
    setUp(() async {
      AppSharedPreferences.resetCache();
      SharedPreferences.setMockInitialValues({});
      db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
    });
    tearDown(() => db.close());

    UsageBloc bloc(AndroidUsageCollector collector) => UsageBloc(
          httpClient: () => throw UnimplementedError(),
          collectorFactory: () => collector,
          database: () async => db,
          lookup: (_) async => const IpBatchResult([]),
          reverse: null,
        );

    test('waits for usage access, then imports history once and starts', () async {
      stats.access = false;
      stats.totals[10123] = ('Telegram', 5000, 500);
      final usage = bloc(AndroidUsageCollector(interval: const Duration(milliseconds: 30)));
      await usage.initialize();
      var status = await usage.status.first;
      expect(status.state, UsageCollectorState.needsSetup);
      expect(status.hasDestinations, isFalse);
      expect(status.setup?.message, contains('Usage access'));

      stats.access = true; // granted in system settings
      await usage.reload();
      status = await usage.status.first;
      expect(status.state, UsageCollectorState.running);
      expect((await SharedPreferences.getInstance()).getBool('usageImported'), isTrue);

      usage.setRange(UsageRange.last7d);
      await usage.reload();
      final view = await usage.view.first;
      expect(view.entries[UsageDimension.app]!.single.key, 'Telegram');
      // A rolling 7-day window starts mid-day, so it holds 6–7 imported days.
      expect(view.total, inInclusiveRange(6 * 1100000, 7 * 1100000), reason: 'a week of imported history');
      await usage.dispose();
    });
  });
}
