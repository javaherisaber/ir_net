import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

import 'data/app_database.dart';
import 'data/shared_preferences.dart';
import 'data/usage.dart';
import 'data/usage_store.dart';
import 'utils/app_names.dart';
import 'utils/ip_enricher.dart';
import 'utils/ip_tools.dart';
import 'utils/time_utils.dart';
import 'utils/usage_collectors.dart';

enum UsageCollectorState { starting, running, paused, needsSetup, unsupported, failed }

class UsageStatus {
  const UsageStatus(
    this.state, {
    this.source,
    this.message,
    this.since,
    this.lookups = true,
    this.hasDestinations = true,
    this.setup,
  });

  final UsageCollectorState state;

  /// Data source, e.g. "nettop".
  final String? source;
  final String? message;
  final DateTime? since;

  /// Whether destination lookups (country / owner) are enabled.
  final bool lookups;

  /// False where the OS only reports totals per app (Android): no domains or
  /// countries to show.
  final bool hasDestinations;

  /// What the user must do first ([UsageCollectorState.needsSetup]).
  final UsageSetup? setup;

  UsageStatus copyWith({bool? lookups}) => UsageStatus(
        state,
        source: source,
        message: message,
        since: since,
        lookups: lookups ?? this.lookups,
        hasDestinations: hasDestinations,
        setup: setup,
      );
}

class UsageFilter {
  const UsageFilter({
    this.range = UsageRange.today,
    this.filters = const {},
    this.includeVpnTransport = false,
  });

  final UsageRange range;
  final Map<UsageDimension, String> filters;
  final bool includeVpnTransport;

  UsageFilter copyWith({UsageRange? range, Map<UsageDimension, String>? filters, bool? includeVpnTransport}) =>
      UsageFilter(
        range: range ?? this.range,
        filters: filters ?? this.filters,
        includeVpnTransport: includeVpnTransport ?? this.includeVpnTransport,
      );
}

/// Collects per-app traffic, stores it per minute and serves the dashboard.
class UsageBloc {
  UsageBloc({
    required http.Client Function() httpClient,
    UsageCollector? Function()? collectorFactory,
    Future<Database> Function()? database,
    IpBatchLookup? lookup,
    ReverseLookup? reverse = systemReverseLookup,
  })  : _lookup = lookup ?? geoJsBatchLookup(httpClient),
        _reverse = reverse,
        _collectorFactory = collectorFactory ?? createPlatformCollector,
        _database = database ?? (() => AppDatabase.instance);

  final IpBatchLookup _lookup;
  final ReverseLookup? _reverse;
  final UsageCollector? Function() _collectorFactory;
  final Future<Database> Function() _database;

  UsageStore? _store;
  IpEnricher? _enricher;
  UsageCollector? _collector;
  StreamSubscription<List<FlowDelta>>? _subscription;
  final _pending = <UsageKey, (int, int)>{};
  final _timers = <Timer>[];
  bool _initialized = false;

  final _status = BehaviorSubject<UsageStatus>();
  final _view = BehaviorSubject<UsageSummary>();
  final _filter = BehaviorSubject<UsageFilter>.seeded(const UsageFilter());

  Stream<UsageStatus> get status => _status.stream;
  Stream<UsageSummary> get view => _view.stream;
  Stream<UsageFilter> get filter => _filter.stream;

  bool get _lookups => _enricher?.enabled ?? true;

  void _setStatus(UsageCollectorState state, {String? message, DateTime? since, UsageSetup? setup}) {
    final collector = _collector;
    _status.value = UsageStatus(
      state,
      source: collector?.source,
      message: message,
      since: since,
      lookups: _lookups,
      hasDestinations: collector?.hasDestinations ?? true,
      setup: setup,
    );
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final unsupported = usageUnsupportedReason();
    if (unsupported != null) {
      _setStatus(UsageCollectorState.unsupported, message: unsupported);
      return;
    }
    try {
      final store = UsageStore(await _database());
      final enricher = IpEnricher(
        lookup: _lookup,
        reverse: _reverse,
        onResolved: (details) => store.saveIpDetails(details).catchError((_) {}),
      );
      enricher.preload(await store.loadIpDetails());
      enricher.enabled = await AppSharedPreferences.usageLookups;
      await store.compact(DateTime.now());
      _store = store;
      _enricher = enricher;
    } catch (e) {
      _setStatus(UsageCollectorState.failed, message: 'Local storage unavailable: $e');
      return;
    }
    _timers
      ..add(Timer.periodic(const Duration(seconds: 15), (_) => flush()))
      ..add(Timer.periodic(const Duration(seconds: 20), (_) {
        if (_view.hasListener) reload();
      }))
      ..add(Timer.periodic(const Duration(hours: 1), (_) => _store?.compact(DateTime.now())));
    _collector ??= _collectorFactory();
    if (await AppSharedPreferences.usageTracking) {
      await _start();
    } else {
      _setStatus(UsageCollectorState.paused);
    }
    await reload();
  }

  Future<void> _start() async {
    final collector = _collector ??= _collectorFactory();
    if (collector == null || _subscription != null) return;
    UsageSetup? setup;
    try {
      setup = await collector.checkSetup();
    } catch (e) {
      _setStatus(UsageCollectorState.failed, message: '$e');
      return;
    }
    if (setup != null) {
      _setStatus(UsageCollectorState.needsSetup, setup: setup);
      return;
    }
    await _importPast(collector);
    _setStatus(UsageCollectorState.running, since: DateTime.now());
    _subscription = collector.start().listen(
      record,
      onError: (Object e) {
        _subscription = null;
        _setStatus(UsageCollectorState.failed, message: '$e'.replaceFirst('Exception: ', ''));
      },
    );
  }

  /// Brings in what the OS recorded before tracking started (Android keeps
  /// weeks of per-app totals), once.
  Future<void> _importPast(UsageCollector collector) async {
    final store = _store;
    if (store == null || await AppSharedPreferences.usageImported) return;
    try {
      final past = await collector.pastUsage(until: DateTime.now());
      await store.addPast(past);
      await AppSharedPreferences.setUsageImported(true);
    } catch (e) {
      debugPrint('Importing past usage failed: $e');
    }
  }

  /// Opens the system screen / prompt that grants what [UsageStatus.setup]
  /// asks for, then checks again.
  Future<void> requestSetup() async {
    await _collector?.requestSetup();
    await _start();
  }

  Future<void> _stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _collector?.stop();
    await flush();
  }

  /// Adds collector deltas to the current minute. Public for tests.
  void record(List<FlowDelta> deltas, {DateTime? at}) {
    final minute = minuteStart(at ?? DateTime.now());
    for (final d in deltas) {
      if (d.remoteIp.isEmpty) {
        // Unconnected UDP sockets used for LAN discovery.
        if (localDiscoveryPorts.contains(d.localPort)) continue;
      } else {
        if (isLocalTraffic(classifyIp(d.remoteIp))) continue;
        // A VPN client's own connections outside the tunnel go to its
        // servers: never send those addresses anywhere.
        final vpnTransport = d.iface != InterfaceKind.tunnel && looksLikeVpnApp(d.app);
        if (!vpnTransport) _enricher?.enqueue(d.remoteIp);
      }
      final key = UsageKey(minute, d.app, d.remoteIp, d.iface);
      final current = _pending[key];
      _pending[key] = current == null ? (d.rx, d.tx) : (current.$1 + d.rx, current.$2 + d.tx);
    }
  }

  Future<void> flush() async {
    final store = _store;
    if (store == null || _pending.isEmpty) return;
    final batch = Map.of(_pending);
    _pending.clear();
    try {
      await store.add(batch);
    } catch (e) {
      debugPrint('Saving usage failed: $e');
    }
  }

  Future<void> setTracking(bool enabled) async {
    await AppSharedPreferences.setUsageTracking(enabled);
    if (_store == null) return;
    if (enabled) {
      await _start();
    } else {
      await _stop();
      _setStatus(UsageCollectorState.paused);
    }
  }

  Future<void> setLookups(bool enabled) async {
    await AppSharedPreferences.setUsageLookups(enabled);
    _enricher?.enabled = enabled;
    final s = _status.valueOrNull;
    if (s != null) _status.value = s.copyWith(lookups: enabled);
  }

  void setRange(UsageRange range) => _setFilter(_filter.value.copyWith(range: range));

  /// Narrows the dashboard to one app / domain / country (null clears).
  void setDimensionFilter(UsageDimension dimension, String? key) {
    final filters = Map.of(_filter.value.filters);
    if (key == null || filters[dimension] == key) {
      filters.remove(dimension);
    } else {
      filters[dimension] = key;
    }
    _setFilter(_filter.value.copyWith(filters: filters));
  }

  void setIncludeVpnTransport(bool include) =>
      _setFilter(_filter.value.copyWith(includeVpnTransport: include));

  void _setFilter(UsageFilter filter) {
    _filter.value = filter;
    reload();
  }

  Future<void> clearHistory() async {
    _pending.clear();
    _enricher?.clear();
    await _store?.clear();
    await reload();
  }

  Future<void> reload() async {
    final store = _store;
    if (store == null) return;
    // The user may have just granted access in system settings.
    if (_status.valueOrNull?.state == UsageCollectorState.needsSetup) await _start();
    await flush();
    final filter = _filter.value;
    final now = DateTime.now();
    final (from, to) = filter.range.bounds(now);
    final summary = UsageSummary(
      range: filter.range,
      from: from,
      to: to,
      records: await store.records(from, to),
      countryNames: await store.countryNames(),
      providerNames: await store.providerNames(),
      filters: filter.filters,
      includeVpnTransport: filter.includeVpnTransport,
    );
    final binSeconds = filter.range == UsageRange.all
        ? pickBinSeconds(to - (await _firstTimestamp(store) ?? to - 86400), maxBins: 60)
        : filter.range.binSeconds;
    summary.binSeconds = binSeconds;
    summary.timeline = await store.timeline(
      from: from,
      to: to,
      binSeconds: binSeconds,
      utcOffset: now.timeZoneOffset,
      filters: filter.filters,
      excludeVpnApps: filter.includeVpnTransport ? const {} : summary.hiddenVpnApps,
    );
    if (!identical(filter, _filter.value)) return;
    _view.value = summary;
  }

  Future<int?> _firstTimestamp(UsageStore store) async {
    final rows = await store.db.rawQuery(
        'SELECT MIN(ts) AS ts FROM (SELECT MIN(ts) AS ts FROM usage_minute UNION ALL SELECT MIN(ts) FROM usage_hour)');
    return (rows.first['ts'] as num?)?.toInt();
  }

  Future<void> dispose() async {
    for (final t in _timers) {
      t.cancel();
    }
    _enricher?.dispose();
    await _stop();
  }
}
