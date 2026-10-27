import 'package:sqflite_common/sqlite_api.dart';

import 'call_quality.dart';
import 'quality.dart';

/// Persistence and queries for the network-quality history.
class QualityStore {
  QualityStore(this.db);

  final Database db;

  /// Minute rows older than this are deleted.
  static const retention = Duration(days: 90);

  // Rows written before durations were stored have secs = 0: count them at
  // 2 s (the default interval) per tick.
  static const _sums = '''
    SUM(ticks) AS ticks, SUM(down_ticks) AS down_ticks,
    SUM(CASE WHEN secs > 0 THEN secs ELSE ticks * 2 END) AS secs,
    SUM(udp_sent) AS udp_sent, SUM(udp_recv) AS udp_recv,
    SUM(udp_rtt_sum) AS udp_rtt_sum, MIN(udp_rtt_min) AS udp_rtt_min,
    MAX(udp_rtt_max) AS udp_rtt_max, SUM(udp_jitter_sum) AS udp_jitter_sum,
    SUM(udp_jitter_n) AS udp_jitter_n,
    SUM(http_sent) AS http_sent, SUM(http_ok) AS http_ok,
    SUM(http_rtt_sum) AS http_rtt_sum, MIN(http_rtt_min) AS http_rtt_min,
    MAX(http_rtt_max) AS http_rtt_max, SUM(http_jitter_sum) AS http_jitter_sum,
    SUM(http_jitter_n) AS http_jitter_n''';

  /// Writes the full state of each window (a window always holds everything
  /// recorded for its minute, so replacing the row is idempotent).
  Future<void> saveWindows(List<QualityWindow> windows) async {
    if (windows.isEmpty) return;
    final batch = db.batch();
    for (final w in windows) {
      batch.insert('quality_minute', w.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Records (or refreshes) location metadata for an exit IP.
  Future<void> touchServer(ServerInfo info, DateTime seenAt) async {
    final now = seenAt.millisecondsSinceEpoch ~/ 1000;
    await db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO quality_server (ip, first_seen, last_seen) VALUES (?, ?, ?)',
        [info.ip, now, now],
      );
      await txn.rawUpdate(
        'UPDATE quality_server SET country = ?, country_code = ?, region = ?, city = ?, '
        'isp = ?, last_seen = ? WHERE ip = ?',
        [info.country, info.countryCode, info.region, info.city, info.isp, now, info.ip],
      );
    });
  }

  Future<void> setLabel(String ip, String? label) async {
    final value = (label == null || label.trim().isEmpty) ? null : label.trim();
    await db.rawUpdate('UPDATE quality_server SET label = ? WHERE ip = ?', [value, ip]);
  }

  Future<Map<String, ServerInfo>> servers() async {
    final rows = await db.rawQuery('SELECT * FROM quality_server');
    return {for (final r in rows) r['ip'] as String: ServerInfo.fromRow(r)};
  }

  /// One row per server (or per location) for `[from, to)`, best score first.
  Future<List<ServerQuality>> compare({
    required int from,
    required int to,
    QualityGrouping grouping = QualityGrouping.server,
  }) async {
    final rows = await db.rawQuery(
      'SELECT server, MIN(ts) AS first_ts, MAX(ts) AS last_ts, $_sums '
      // '' = probes sent before the public IP was known: not a server.
      "FROM quality_minute WHERE ts >= ? AND ts < ? AND server != '' GROUP BY server",
      [from, to],
    );
    final infos = await servers();
    final groups = <String, _Group>{};
    for (final row in rows) {
      final ip = row['server'] as String;
      final info = infos[ip] ?? ServerInfo(ip: ip);
      final key = grouping == QualityGrouping.server ? ip : locationKey(info);
      final group = groups.putIfAbsent(key, () => _Group());
      group.stats.merge(qualityStatsFromRow(row));
      group.ips.add(ip);
      final first = (row['first_ts'] as num).toInt();
      final last = (row['last_ts'] as num).toInt();
      if (group.first == null || first < group.first!) group.first = first;
      if (group.last == null || last > group.last!) {
        group.last = last;
        group.info = info;
      }
    }
    final result = [
      for (final e in groups.entries)
        ServerQuality(
          key: e.key,
          info: e.value.info!,
          stats: e.value.stats,
          ips: e.value.ips,
          firstTs: e.value.first!,
          lastTs: e.value.last!,
        ),
    ];
    result.sort((a, b) => (b.stats.score?.value ?? -1).compareTo(a.stats.score?.value ?? -1));
    return result;
  }

  /// Location grouping key: country + city, falling back to the IP.
  static String locationKey(ServerInfo info) {
    if (info.countryCode == null && info.city == null) return info.ip;
    return '${info.countryCode ?? '?'}|${info.city ?? ''}';
  }

  /// Quality per [binSeconds] bucket over `[from, to)`. Buckets are aligned to
  /// local time ([utcOffset]) so hour/day bins start on local boundaries.
  /// Restricted to [servers] when given.
  Future<List<QualityBin>> history({
    required int from,
    required int to,
    required int binSeconds,
    Duration utcOffset = Duration.zero,
    List<String>? servers,
  }) async {
    final offset = utcOffset.inSeconds;
    final where = StringBuffer('ts >= ? AND ts < ?');
    final args = <Object?>[from, to];
    if (servers != null && servers.isNotEmpty) {
      where.write(' AND server IN (${List.filled(servers.length, '?').join(', ')})');
      args.addAll(servers);
    }
    final rows = await db.rawQuery(
      'SELECT ((ts + $offset) / $binSeconds) * $binSeconds - $offset AS bin, $_sums '
      'FROM quality_minute WHERE $where GROUP BY bin ORDER BY bin',
      args,
    );
    return [
      for (final r in rows) QualityBin((r['bin'] as num).toInt(), qualityStatsFromRow(r)),
    ];
  }

  Future<void> saveCallTest(CallTestResult result) async {
    await db.insert('call_test', result.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Most recent call tests (within `[from, to)` when given), newest first.
  Future<List<CallTestResult>> callTests({int limit = 10, int? from, int? to}) async {
    final where = [if (from != null) 'ts >= ?', if (to != null) 'ts < ?'];
    final rows = await db.rawQuery(
      'SELECT * FROM call_test${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'} ORDER BY ts DESC LIMIT ?',
      [if (from != null) from, if (to != null) to, limit],
    );
    return rows.map(CallTestResult.fromRow).toList();
  }

  /// Raw minute rows over `[from, to)`, oldest first.
  Future<List<QualityWindow>> minutes({required int from, required int to}) async {
    final rows = await db.rawQuery(
        'SELECT * FROM quality_minute WHERE ts >= ? AND ts < ? ORDER BY ts, server', [from, to]);
    return rows.map(qualityWindowFromRow).toList();
  }

  /// Earliest stored minute, for the "All" range.
  Future<int?> firstTimestamp() async {
    final rows = await db.rawQuery('SELECT MIN(ts) AS ts FROM quality_minute');
    return (rows.first['ts'] as num?)?.toInt();
  }

  Future<void> prune(DateTime now) async {
    final cutoff = now.subtract(retention).millisecondsSinceEpoch ~/ 1000;
    await db.rawDelete('DELETE FROM quality_minute WHERE ts < ?', [cutoff]);
    await db.rawDelete('DELETE FROM call_test WHERE ts < ?', [cutoff]);
  }

  Future<void> clear() async {
    await db.transaction((txn) async {
      await txn.rawDelete('DELETE FROM quality_minute');
      await txn.rawDelete('DELETE FROM quality_server');
      await txn.rawDelete('DELETE FROM call_test');
    });
  }
}

class _Group {
  final stats = QualityStats();
  final ips = <String>[];
  int? first;
  int? last;
  ServerInfo? info;
}
