import 'package:ir_net/utils/ip_enricher.dart';
import 'package:ir_net/utils/ip_tools.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'usage.dart';

/// Identifies one accumulated counter: a minute, an app, a remote address and
/// the interface kind.
class UsageKey {
  const UsageKey(this.minute, this.app, this.ip, this.iface);

  final int minute;
  final String app;
  final String ip;
  final InterfaceKind iface;

  @override
  bool operator ==(Object other) =>
      other is UsageKey &&
      other.minute == minute &&
      other.app == app &&
      other.ip == ip &&
      other.iface == iface;

  @override
  int get hashCode => Object.hash(minute, app, ip, iface);
}

/// Persistence and queries for per-app / per-destination traffic.
///
/// Recent traffic lives in `usage_minute` keyed by remote IP, so domain and
/// country can be attached later, once lookups finish. Rows older than
/// [fineRetention] are rolled up into `usage_hour` by domain and country.
class UsageStore {
  UsageStore(this.db);

  final Database db;

  /// Keeps "Today" and "Yesterday" at minute resolution.
  static const fineRetention = Duration(days: 3);

  static const _domainExpr =
      "COALESCE(i.domain_key, CASE WHEN u.ip = '' THEN '${DomainKeys.unknown}' ELSE u.ip END)";
  static const _countryExpr = "COALESCE(i.country_code, '')";

  Future<void> add(Map<UsageKey, (int, int)> counts) async {
    if (counts.isEmpty) return;
    final batch = db.batch();
    counts.forEach((k, v) {
      final args = [k.minute, k.app, k.ip, k.iface.index];
      batch.rawInsert(
          'INSERT OR IGNORE INTO usage_minute (ts, app, ip, iface, rx, tx) VALUES (?, ?, ?, ?, 0, 0)',
          args);
      batch.rawUpdate(
          'UPDATE usage_minute SET rx = rx + ?, tx = tx + ? WHERE ts = ? AND app = ? AND ip = ? AND iface = ?',
          [v.$1, v.$2, ...args]);
    });
    await batch.commit(noResult: true);
  }

  /// Per-app totals from before tracking started (no destinations).
  Future<void> addPast(List<PastAppUsage> past) async {
    if (past.isEmpty) return;
    final batch = db.batch();
    for (final p in past) {
      final args = [p.start.millisecondsSinceEpoch ~/ 1000, p.app, DomainKeys.unknown, '', InterfaceKind.other.index];
      batch.rawInsert(
          'INSERT OR IGNORE INTO usage_hour (ts, app, domain, country, iface, rx, tx) VALUES (?, ?, ?, ?, ?, 0, 0)',
          args);
      batch.rawUpdate(
          'UPDATE usage_hour SET rx = rx + ?, tx = tx + ? '
          'WHERE ts = ? AND app = ? AND domain = ? AND country = ? AND iface = ?',
          [p.rx, p.tx, ...args]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> saveIpDetails(List<IpDetails> details) async {
    if (details.isEmpty) return;
    final batch = db.batch();
    for (final d in details) {
      batch.insert('ip_info', d.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<IpDetails>> loadIpDetails() async {
    final rows = await db.rawQuery('SELECT * FROM ip_info');
    return rows.map(IpDetails.fromRow).toList();
  }

  /// Traffic per (app, domain, country, interface) over `[from, to)`.
  Future<List<UsageRecord>> records(int from, int to) async {
    final fine = await db.rawQuery(
      'SELECT u.app AS app, $_domainExpr AS d, $_countryExpr AS c, u.iface AS iface, '
      'SUM(u.rx) AS rx, SUM(u.tx) AS tx '
      'FROM usage_minute u LEFT JOIN ip_info i ON i.ip = u.ip '
      'WHERE u.ts >= ? AND u.ts < ? GROUP BY u.app, d, c, u.iface',
      [from, to],
    );
    final coarse = await db.rawQuery(
      'SELECT app, domain AS d, country AS c, iface, SUM(rx) AS rx, SUM(tx) AS tx '
      'FROM usage_hour WHERE ts >= ? AND ts < ? GROUP BY app, d, c, iface',
      [from, to],
    );
    final merged = <String, List<int>>{};
    final keys = <String, (String, String, String, int)>{};
    for (final row in [...fine, ...coarse]) {
      final app = row['app'] as String;
      final d = row['d'] as String;
      final c = row['c'] as String;
      final iface = (row['iface'] as num).toInt();
      final key = '$app\u0000$d\u0000$c\u0000$iface';
      keys[key] = (app, d, c, iface);
      final sums = merged.putIfAbsent(key, () => [0, 0]);
      sums[0] += (row['rx'] as num?)?.toInt() ?? 0;
      sums[1] += (row['tx'] as num?)?.toInt() ?? 0;
    }
    return [
      for (final e in merged.entries)
        UsageRecord(
          app: keys[e.key]!.$1,
          domain: keys[e.key]!.$2,
          country: keys[e.key]!.$3,
          iface: InterfaceKind.values[keys[e.key]!.$4.clamp(0, InterfaceKind.values.length - 1)],
          rx: e.value[0],
          tx: e.value[1],
        ),
    ];
  }

  /// Traffic per [binSeconds] bucket (aligned to local time via [utcOffset])
  /// with the same filters as the breakdown. [excludeVpnApps] drops those
  /// apps' non-tunnel traffic (the VPN transport copy).
  Future<List<UsageBin>> timeline({
    required int from,
    required int to,
    required int binSeconds,
    Duration utcOffset = Duration.zero,
    Map<UsageDimension, String> filters = const {},
    Set<String> excludeVpnApps = const {},
  }) async {
    final offset = utcOffset.inSeconds;
    final bins = <int, List<int>>{};

    Future<void> run(String table, String app, String domain, String country, String join) async {
      final where = StringBuffer('$app IS NOT NULL AND ts >= ? AND ts < ?');
      final args = <Object?>[from, to];
      void eq(String expr, String? value) {
        if (value == null) return;
        where.write(' AND $expr = ?');
        args.add(value);
      }

      eq(app, filters[UsageDimension.app]);
      eq(domain, filters[UsageDimension.domain]);
      eq(country, filters[UsageDimension.country]);
      if (excludeVpnApps.isNotEmpty) {
        final marks = List.filled(excludeVpnApps.length, '?').join(', ');
        where.write(' AND NOT ($app IN ($marks) AND iface != ${InterfaceKind.tunnel.index})');
        args.addAll(excludeVpnApps);
      }
      final rows = await db.rawQuery(
        'SELECT ((ts + $offset) / $binSeconds) * $binSeconds - $offset AS bin, '
        'SUM(rx) AS rx, SUM(tx) AS tx FROM $table $join WHERE $where GROUP BY bin',
        args,
      );
      for (final r in rows) {
        final sums = bins.putIfAbsent((r['bin'] as num).toInt(), () => [0, 0]);
        sums[0] += (r['rx'] as num?)?.toInt() ?? 0;
        sums[1] += (r['tx'] as num?)?.toInt() ?? 0;
      }
    }

    await run('usage_minute u', 'u.app', _domainExpr, _countryExpr,
        'LEFT JOIN ip_info i ON i.ip = u.ip');
    await run('usage_hour', 'app', 'domain', 'country', '');
    final starts = bins.keys.toList()..sort();
    return [for (final s in starts) UsageBin(s, bins[s]![0], bins[s]![1])];
  }

  /// ISO code → country name, from everything looked up so far.
  Future<Map<String, String>> countryNames() async {
    final rows = await db.rawQuery(
        'SELECT DISTINCT country_code, country FROM ip_info WHERE country_code IS NOT NULL AND country IS NOT NULL');
    return {for (final r in rows) r['country_code'] as String: r['country'] as String};
  }

  /// Domain key → the network owner most of its addresses belong to.
  Future<Map<String, String>> providerNames() async {
    final rows = await db.rawQuery(
        'SELECT domain_key, org, COUNT(*) AS n FROM ip_info '
        'WHERE domain_key IS NOT NULL AND org IS NOT NULL GROUP BY domain_key, org ORDER BY n');
    // Ascending by count, so the most common owner is written last.
    return {for (final r in rows) r['domain_key'] as String: r['org'] as String};
  }

  /// Rolls minute rows older than [fineRetention] into hourly rows.
  Future<void> compact(DateTime now) async {
    final cutoffSeconds = now.subtract(fineRetention).millisecondsSinceEpoch ~/ 1000;
    final cutoff = cutoffSeconds - cutoffSeconds % 3600;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT (u.ts / 3600) * 3600 AS h, u.app AS app, $_domainExpr AS d, $_countryExpr AS c, '
        'u.iface AS iface, SUM(u.rx) AS rx, SUM(u.tx) AS tx '
        'FROM usage_minute u LEFT JOIN ip_info i ON i.ip = u.ip '
        'WHERE u.ts < ? GROUP BY h, u.app, d, c, u.iface',
        [cutoff],
      );
      if (rows.isEmpty) return;
      final batch = txn.batch();
      for (final r in rows) {
        final args = [r['h'], r['app'], r['d'], r['c'], r['iface']];
        batch.rawInsert(
            'INSERT OR IGNORE INTO usage_hour (ts, app, domain, country, iface, rx, tx) '
            'VALUES (?, ?, ?, ?, ?, 0, 0)',
            args);
        batch.rawUpdate(
            'UPDATE usage_hour SET rx = rx + ?, tx = tx + ? '
            'WHERE ts = ? AND app = ? AND domain = ? AND country = ? AND iface = ?',
            [r['rx'], r['tx'], ...args]);
      }
      batch.rawDelete('DELETE FROM usage_minute WHERE ts < ?', [cutoff]);
      await batch.commit(noResult: true);
    });
  }

  /// Deletes all traffic and every looked-up address.
  Future<void> clear() async {
    await db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM usage_minute');
      await txn.rawDelete('DELETE FROM usage_hour');
      await txn.rawDelete('DELETE FROM ip_info');
    });
  }
}
