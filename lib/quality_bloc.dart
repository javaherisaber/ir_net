import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

import 'data/app_database.dart';
import 'data/call_quality.dart';
import 'data/quality.dart';
import 'data/quality_report.dart';
import 'data/quality_store.dart';
import 'data/shared_preferences.dart';
import 'utils/call_tester.dart';
import 'utils/quality_monitor.dart';
import 'utils/quality_probes.dart';
import 'utils/time_utils.dart';

/// What the live part of the quality dashboard shows.
class QualityLive {
  const QualityLive({
    required this.supported,
    required this.running,
    required this.interval,
    required this.recent,
    required this.samples,
    this.server,
    this.startedAt,
    this.udpSkipped = false,
    this.udpUnavailable,
  });

  final bool supported;
  final bool running;
  final Duration interval;

  /// Exit point probes are currently attributed to.
  final ServerInfo? server;
  final DateTime? startedAt;

  /// Stats over [liveWindow] for the current server.
  final QualityStats recent;

  /// Raw probes for the live chart (current server, last [chartWindow]).
  final List<ProbeSample> samples;

  /// UDP isn't measured because a system proxy is set.
  final bool udpSkipped;

  /// UDP probes can't be sent at all (local error); HTTPS takes over.
  final String? udpUnavailable;

  static const liveWindow = Duration(minutes: 2);
  static const chartWindow = Duration(minutes: 5);
}

class QualityFilter {
  const QualityFilter({
    this.range = QualityRange.hours24,
    this.grouping = QualityGrouping.server,
    this.selected,
  });

  final QualityRange range;
  final QualityGrouping grouping;

  /// Comparison row whose history is charted; null = everything.
  final String? selected;

  QualityFilter copyWith({QualityRange? range, QualityGrouping? grouping, String? Function()? selected}) =>
      QualityFilter(
        range: range ?? this.range,
        grouping: grouping ?? this.grouping,
        selected: selected == null ? this.selected : selected(),
      );
}

/// History + comparison for the current filter.
class QualityDashboard {
  const QualityDashboard({
    required this.filter,
    required this.rows,
    required this.bins,
    required this.binSeconds,
    required this.from,
    required this.to,
    required this.currentServer,
  });

  final QualityFilter filter;
  final List<ServerQuality> rows;
  final List<QualityBin> bins;
  final int binSeconds;
  final int from;
  final int to;
  final String currentServer;

  ServerQuality? get selectedRow {
    for (final r in rows) {
      if (r.key == filter.selected) return r;
    }
    return null;
  }

  /// Whether [row] contains the server probes currently go to.
  bool isCurrent(ServerQuality row) => row.ips.contains(currentServer);
}

enum CallTestStatus { idle, running, done, failed }

class CallTestState {
  const CallTestState(this.status, {this.progress, this.result, this.error});

  final CallTestStatus status;
  final CallTestProgress? progress;
  final CallTestResult? result;
  final String? error;

  bool get running => status == CallTestStatus.running;
}

/// A finished call test with what is known about its exit server.
class CallTestEntry {
  const CallTestEntry(this.result, this.server);
  final CallTestResult result;
  final ServerInfo? server;
}

/// Runs the quality monitor, persists its minutes and serves dashboard data.
class QualityBloc {
  QualityBloc({
    String? Function()? proxy,
    VoidCallback? onRecovered,
    QualityMonitor? monitor,
    Future<Database> Function()? database,
    CallTester? callTester,
  })  : _proxy = proxy,
        _database = database ?? (() => AppDatabase.instance),
        _callTester = callTester ?? CallTester(proxy: proxy),
        monitor = monitor ??
            QualityMonitor(
              udp: StunProber(),
              http: HttpsProber(proxy: proxy),
              onRecovered: onRecovered,
              skipUdp: () => proxy?.call() != null,
            );

  final String? Function()? _proxy;
  final Future<Database> Function() _database;
  final CallTester _callTester;
  final QualityMonitor monitor;

  QualityStore? _store;
  ServerInfo? _server;
  Timer? _flushTimer;
  Timer? _reloadTimer;
  bool _initialized = false;

  final _live = BehaviorSubject<QualityLive>();
  final _dashboard = BehaviorSubject<QualityDashboard>();
  final _filter = BehaviorSubject<QualityFilter>.seeded(const QualityFilter());
  final _callTest = BehaviorSubject<CallTestState>.seeded(const CallTestState(CallTestStatus.idle));
  final _callTests = BehaviorSubject<List<CallTestEntry>>.seeded(const []);

  Stream<QualityLive> get live => _live.stream;
  Stream<CallTestState> get callTest => _callTest.stream;

  /// Recent call tests, newest first.
  Stream<List<CallTestEntry>> get callTests => _callTests.stream;
  Stream<QualityDashboard> get dashboard => _dashboard.stream;
  Stream<QualityFilter> get filter => _filter.stream;
  QualityLive? get currentLive => _live.valueOrNull;

  static bool get isSupported => AppDatabase.isSupported;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!isSupported) {
      _emitLive();
      return;
    }
    monitor.interval = Duration(seconds: await AppSharedPreferences.qualityInterval);
    monitor.changes.listen((_) => _emitLive());
    try {
      final store = QualityStore(await _database());
      await store.prune(DateTime.now());
      _store = store;
    } catch (e) {
      debugPrint('Quality history unavailable: $e');
    }
    if (await AppSharedPreferences.qualityMonitoring) monitor.start();
    _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) => flush());
    _reloadTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_dashboard.hasListener) reload();
    });
    _emitLive();
    await _loadCallTests();
    await reload();
  }

  /// Simulates a call on the current connection (about 15 s and ~4 MB).
  Future<void> runCallTest() async {
    if (_callTest.value.running) return;
    _callTest.value = const CallTestState(CallTestStatus.running,
        progress: CallTestProgress(CallTestPhase.voice, 0));
    try {
      final result = await _callTester.run(
        server: monitor.server,
        onProgress: (p) => _callTest.value = CallTestState(CallTestStatus.running, progress: p),
      );
      await _store?.saveCallTest(result);
      _callTest.value = CallTestState(CallTestStatus.done, result: result);
      await _loadCallTests();
    } on ProbeUnavailable catch (e) {
      _callTest.value = CallTestState(CallTestStatus.failed, error: e.message);
    } catch (e) {
      _callTest.value = CallTestState(CallTestStatus.failed, error: 'The call test failed: $e');
    }
  }

  Future<void> _loadCallTests() async {
    final store = _store;
    if (store == null) return;
    final tests = await store.callTests();
    final servers = await store.servers();
    _callTests.value = [for (final t in tests) CallTestEntry(t, servers[t.server])];
  }

  /// Feeds the public-IP lookup result: probes are attributed to this IP.
  void onIpLookup(dynamic json) {
    final info = ServerInfo.fromLookup(json);
    if (info == null) return;
    _server = info;
    monitor.setServer(info.ip);
    _store?.touchServer(info, DateTime.now());
    _emitLive();
  }

  void onNetworkChanged() => monitor.onNetworkChanged();

  Future<void> setEnabled(bool enabled) async {
    await AppSharedPreferences.setQualityMonitoring(enabled);
    if (enabled) {
      monitor.start();
    } else {
      monitor.stop();
      await flush();
    }
    _emitLive();
  }

  Future<void> setIntervalSeconds(int seconds) async {
    await AppSharedPreferences.setQualityInterval(seconds);
    monitor.setInterval(Duration(seconds: seconds));
    _emitLive();
  }

  void setRange(QualityRange range) => _setFilter(_filter.value.copyWith(range: range));

  void setGrouping(QualityGrouping grouping) =>
      _setFilter(_filter.value.copyWith(grouping: grouping, selected: () => null));

  /// Selects a comparison row (tapping the selected one clears it).
  void toggleSelected(String key) {
    final current = _filter.value.selected;
    _setFilter(_filter.value.copyWith(selected: () => current == key ? null : key));
  }

  void _setFilter(QualityFilter filter) {
    _filter.value = filter;
    reload();
  }

  Future<void> rename(String ip, String? label) async {
    await _store?.setLabel(ip, label);
    await reload();
  }

  Future<void> clearHistory() async {
    monitor.takeDirtyWindows();
    await _store?.clear();
    final server = _server;
    if (server != null) await _store?.touchServer(server, DateTime.now());
    if (!_callTest.value.running) _callTest.value = const CallTestState(CallTestStatus.idle);
    _callTests.value = const [];
    await reload();
  }

  /// Writes finished and in-progress minutes to the database.
  Future<void> flush() async {
    final store = _store;
    final windows = monitor.takeDirtyWindows();
    if (store == null || windows.isEmpty) return;
    try {
      await store.saveWindows(windows);
    } catch (e) {
      debugPrint('Saving quality data failed: $e');
    }
  }

  Future<void> reload() async {
    final store = _store;
    if (store == null) return;
    await flush();
    final filter = _filter.value;
    final now = DateTime.now();
    final to = epochSeconds(now) + 60;
    final span = filter.range.span;
    final first = span == null ? await store.firstTimestamp() : null;
    final from = span == null ? (first ?? to - 3600) : to - span.inSeconds;
    final rows = await store.compare(from: from, to: to, grouping: filter.grouping);
    List<String>? servers;
    for (final r in rows) {
      if (r.key == filter.selected) servers = r.ips;
    }
    final binSeconds = pickBinSeconds(to - from, maxBins: 150);
    final bins = await store.history(
      from: from,
      to: to,
      binSeconds: binSeconds,
      utcOffset: now.timeZoneOffset,
      servers: servers,
    );
    // The filter may have changed while querying; only publish the latest.
    if (!identical(filter, _filter.value)) return;
    _dashboard.value = QualityDashboard(
      filter: filter,
      rows: rows,
      bins: bins,
      binSeconds: binSeconds,
      from: from,
      to: to,
      currentServer: monitor.server,
    );
  }

  /// The dashboard as it is now (range, grouping and selected row) plus the
  /// raw minutes and call tests behind it, for exporting. Null without a
  /// history store.
  Future<QualityReport?> report({String appVersion = '', String platform = ''}) async {
    final store = _store;
    if (store == null) return null;
    await reload();
    final dashboard = _dashboard.valueOrNull;
    if (dashboard == null) return null;
    final servers = await store.servers();
    final server = _server;
    return QualityReport(
      generatedAt: DateTime.now(),
      range: dashboard.filter.range,
      grouping: dashboard.filter.grouping,
      from: dashboard.from,
      to: dashboard.to,
      binSeconds: dashboard.binSeconds,
      rows: dashboard.rows,
      bins: dashboard.bins,
      minutes: await store.minutes(from: dashboard.from, to: dashboard.to),
      servers: servers,
      callTests: await store.callTests(limit: 1000, from: dashboard.from, to: dashboard.to),
      samples: List.of(monitor.samples),
      selected: dashboard.selectedRow,
      current: server == null ? null : (servers[server.ip] ?? server),
      probeInterval: monitor.interval,
      appVersion: appVersion,
      platform: platform,
    );
  }

  void _emitLive() {
    final since = DateTime.now().subtract(QualityLive.chartWindow);
    _live.value = QualityLive(
      supported: isSupported,
      running: monitor.isRunning,
      interval: monitor.interval,
      server: _server,
      startedAt: monitor.startedAt,
      recent: monitor.recentStats(QualityLive.liveWindow),
      samples: [
        for (final s in monitor.samples)
          if (s.server == monitor.server && !s.time.isBefore(since)) s,
      ],
      udpSkipped: _proxy?.call() != null,
      udpUnavailable: monitor.udpUnavailable,
    );
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _reloadTimer?.cancel();
    monitor.stop();
    await flush();
  }
}
