import 'package:ir_net/utils/app_names.dart';

/// Which interface carried a flow. Stored as the enum index.
enum InterfaceKind {
  other,
  physical,

  /// A VPN/tunnel interface (utun, tun, wg, ppp…): traffic of apps going
  /// through a full-tunnel or TUN-mode VPN.
  tunnel,
}

final _tunnelInterface = RegExp(
  r'^(utun|tun|tap|wg|ppp|ipsec|gpd|zt|tailscale|nordlynx|wintun|proton|mullvad|sing|clash|mihomo|xray|v2ray|meta)',
  caseSensitive: false,
);

InterfaceKind interfaceKindOf(String? name) {
  if (name == null || name.isEmpty) return InterfaceKind.other;
  final n = name.toLowerCase();
  if (_tunnelInterface.hasMatch(n) || n.contains('vpn') || n.contains('wireguard')) {
    return InterfaceKind.tunnel;
  }
  return InterfaceKind.physical;
}

/// Bytes moved by one app to one remote address since the previous sample.
class FlowDelta {
  const FlowDelta({
    required this.app,
    required this.remoteIp,
    required this.iface,
    required this.rx,
    required this.tx,
    this.remotePort,
    this.localPort,
  });

  final String app;

  /// Empty when the socket has no single remote end (unconnected UDP).
  final String remoteIp;
  final int? remotePort;
  final int? localPort;
  final InterfaceKind iface;
  final int rx;
  final int tx;

  @override
  String toString() => 'FlowDelta($app → $remoteIp:$remotePort ${iface.name} rx=$rx tx=$tx)';
}

/// Usage time ranges the dashboard offers.
enum UsageRange {
  last10m('10 min'),
  last60m('60 min'),
  today('Today'),
  yesterday('Yesterday'),
  last7d('7 days'),
  last30d('30 days'),
  all('All time');

  const UsageRange(this.label);

  final String label;

  /// `[from, to)` in seconds since epoch. "Today" and "Yesterday" follow the
  /// local calendar day.
  (int, int) bounds(DateTime now) {
    int s(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    final end = s(now) + 1;
    final midnight = DateTime(now.year, now.month, now.day);
    return switch (this) {
      UsageRange.last10m => (end - 600, end),
      UsageRange.last60m => (end - 3600, end),
      UsageRange.today => (s(midnight), end),
      UsageRange.yesterday => (s(DateTime(now.year, now.month, now.day - 1)), s(midnight)),
      UsageRange.last7d => (end - 7 * 86400, end),
      UsageRange.last30d => (end - 30 * 86400, end),
      UsageRange.all => (0, end),
    };
  }

  /// Timeline bucket size.
  int get binSeconds => switch (this) {
        UsageRange.last10m => 60,
        UsageRange.last60m => 120,
        UsageRange.today || UsageRange.yesterday => 3600,
        UsageRange.last7d => 6 * 3600,
        UsageRange.last30d || UsageRange.all => 86400,
      };
}

enum UsageDimension { app, domain, country }

/// Traffic for one (app, domain, country, interface) combination in a range.
class UsageRecord {
  const UsageRecord({
    required this.app,
    required this.domain,
    required this.country,
    required this.iface,
    required this.rx,
    required this.tx,
  });

  final String app;
  final String domain;

  /// ISO country code, or empty when unknown.
  final String country;
  final InterfaceKind iface;
  final int rx;
  final int tx;

  int get total => rx + tx;

  String keyOf(UsageDimension d) => switch (d) {
        UsageDimension.app => app,
        UsageDimension.domain => domain,
        UsageDimension.country => country,
      };
}

/// One row of a breakdown list.
class UsageEntry {
  UsageEntry(this.key);

  final String key;
  int rx = 0;
  int tx = 0;

  /// For domains: the country carrying most of the bytes.
  String? topCountry;
  final _countryBytes = <String, int>{};

  int get total => rx + tx;

  void add(UsageRecord r) {
    rx += r.rx;
    tx += r.tx;
    if (r.country.isEmpty) return;
    final bytes = (_countryBytes[r.country] ?? 0) + r.total;
    _countryBytes[r.country] = bytes;
    if (topCountry == null || bytes > (_countryBytes[topCountry!] ?? 0)) topCountry = r.country;
  }
}

/// Bucket of the usage timeline.
class UsageBin {
  const UsageBin(this.start, this.rx, this.tx);
  final int start;
  final int rx;
  final int tx;
  int get total => rx + tx;
}

/// What the dashboard shows for the current range + filters.
class UsageSummary {
  UsageSummary({
    required this.range,
    required this.from,
    required this.to,
    required this.records,
    required this.countryNames,
    required this.providerNames,
    this.filters = const {},
    this.includeVpnTransport = false,
  }) {
    _build();
  }

  final UsageRange range;
  final int from;
  final int to;

  /// All records in the range (before filters / VPN exclusion).
  final List<UsageRecord> records;

  /// Traffic over time for the same filters, loaded separately.
  List<UsageBin> timeline = const [];
  int binSeconds = 3600;
  final Map<String, String> countryNames;

  /// Network owner per domain key, where known.
  final Map<String, String> providerNames;
  final Map<UsageDimension, String> filters;
  final bool includeVpnTransport;

  int rx = 0;
  int tx = 0;
  int get total => rx + tx;

  /// VPN-client traffic left out of the totals (see [isVpnTransport]).
  int hiddenVpnBytes = 0;
  final hiddenVpnApps = <String>{};

  /// Whether this range saw traffic on a tunnel interface at all.
  bool tunnelActive = false;
  final Map<UsageDimension, List<UsageEntry>> entries = {};

  /// With a full-tunnel / TUN VPN every app's traffic is seen on the tunnel
  /// interface and again, encrypted, as the VPN client's own traffic on the
  /// physical interface. That second copy is hidden unless asked for.
  bool isVpnTransport(UsageRecord r) =>
      tunnelActive && r.iface != InterfaceKind.tunnel && looksLikeVpnApp(r.app);

  void _build() {
    tunnelActive = records.any((r) => r.iface == InterfaceKind.tunnel && r.total > 0);
    final maps = {for (final d in UsageDimension.values) d: <String, UsageEntry>{}};
    for (final r in records) {
      if (!_matchesFilters(r)) continue;
      if (isVpnTransport(r)) {
        hiddenVpnBytes += r.total;
        hiddenVpnApps.add(r.app);
        if (!includeVpnTransport) continue;
      }
      rx += r.rx;
      tx += r.tx;
      for (final d in UsageDimension.values) {
        maps[d]!.putIfAbsent(r.keyOf(d), () => UsageEntry(r.keyOf(d))).add(r);
      }
    }
    for (final d in UsageDimension.values) {
      entries[d] = maps[d]!.values.where((e) => e.total > 0).toList()
        ..sort((a, b) => b.total.compareTo(a.total));
    }
  }

  bool _matchesFilters(UsageRecord r) {
    for (final f in filters.entries) {
      if (r.keyOf(f.key) != f.value) return false;
    }
    return true;
  }
}
