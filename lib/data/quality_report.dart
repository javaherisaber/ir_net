import 'call_quality.dart';
import 'quality.dart';

/// A run of consecutive minutes in which connectivity was lost completely.
class Outage {
  Outage(this.start, this.end, this.downSeconds);

  /// First and last affected minute (minute starts, seconds since epoch).
  final int start;
  int end;

  /// Time without any connectivity inside those minutes.
  double downSeconds;
}

/// Everything one export contains, captured once so the PDF report, the CSV
/// files and the text summary all describe the same data.
class QualityReport {
  QualityReport({
    required this.generatedAt,
    required this.range,
    required this.grouping,
    required this.from,
    required this.to,
    required this.binSeconds,
    required this.rows,
    required this.bins,
    required this.minutes,
    required this.servers,
    required this.callTests,
    this.samples = const [],
    this.selected,
    this.current,
    this.probeInterval,
    this.appVersion = '',
    this.platform = '',
  });

  final DateTime generatedAt;
  final QualityRange range;
  final QualityGrouping grouping;

  /// Period covered, seconds since epoch (`to` may lie in the current minute).
  final int from;
  final int to;

  /// Size of one [bins] bucket.
  final int binSeconds;

  /// Comparison rows, best score first.
  final List<ServerQuality> rows;

  /// History of the report's scope (see [selected]).
  final List<QualityBin> bins;

  /// Every stored minute of the period, for all servers.
  final List<QualityWindow> minutes;

  /// Metadata per exit IP.
  final Map<String, ServerInfo> servers;

  /// Call tests run during the period, newest first.
  final List<CallTestResult> callTests;

  /// The latest raw probes kept in memory (a few minutes' worth).
  final List<ProbeSample> samples;

  /// Comparison row the dashboard was narrowed to; null = all servers.
  final ServerQuality? selected;

  /// Exit point the app is connected through right now.
  final ServerInfo? current;
  final Duration? probeInterval;
  final String appVersion;
  final String platform;

  /// This report with only the server labels [keep] accepts; the others fall
  /// back to the location (e.g. labels a PDF font has no glyphs for).
  QualityReport keepingLabels(bool Function(String label) keep) {
    ServerInfo fix(ServerInfo info) => info.label == null || keep(info.label!) ? info : info.unlabeled;
    ServerQuality fixRow(ServerQuality q) =>
        ServerQuality(key: q.key, info: fix(q.info), stats: q.stats, ips: q.ips, firstTs: q.firstTs, lastTs: q.lastTs);
    final fixedRows = [for (final q in rows) fixRow(q)];
    final selectedKey = selected?.key;
    return QualityReport(
      generatedAt: generatedAt,
      range: range,
      grouping: grouping,
      from: from,
      to: to,
      binSeconds: binSeconds,
      rows: fixedRows,
      bins: bins,
      minutes: minutes,
      servers: servers.map((ip, info) => MapEntry(ip, fix(info))),
      callTests: callTests,
      samples: samples,
      selected: selected == null
          ? null
          : fixedRows.firstWhere((q) => q.key == selectedKey, orElse: () => fixRow(selected!)),
      current: current == null ? null : fix(current!),
      probeInterval: probeInterval,
      appVersion: appVersion,
      platform: platform,
    );
  }

  /// End of the period as shown to people (never in the future).
  int get end {
    final now = generatedAt.millisecondsSinceEpoch ~/ 1000;
    return to < now ? to : now;
  }

  /// Totals over the report's scope.
  late final QualityStats total = () {
    final stats = QualityStats();
    for (final b in bins) {
      stats.merge(b.stats);
    }
    return stats;
  }();

  bool get isEmpty => !total.hasData && callTests.isEmpty;

  /// Monitored time in scope (rows stored before durations count 2 s a tick).
  Duration get monitored => Duration(seconds: (total.seconds > 0 ? total.seconds : total.ticks * 2).round());

  /// Minutes in scope.
  late final List<QualityWindow> scopeMinutes = selected == null
      ? minutes
      : [
          for (final m in minutes)
            if (selected!.ips.contains(m.server)) m,
        ];

  /// Minutes with enough probes to judge their loss.
  Iterable<QualityWindow> get _judgedMinutes => scopeMinutes.where((m) => m.primary.sent >= 5);

  int get measuredMinutes => _judgedMinutes.length;

  /// Minutes that lost more than [percent] of their probes.
  int lossyMinutes([double percent = 5]) => _judgedMinutes.where((m) => (m.lossPercent ?? 0) > percent).length;

  /// Complete outages: runs of minutes that had ticks without any connectivity.
  late final List<Outage> outages = () {
    // Two servers can share a minute (the exit IP changed), so merge by time.
    final down = <int, double>{};
    for (final m in scopeMinutes) {
      if (m.downTicks == 0 || m.ticks == 0) continue;
      final perTick = m.seconds > 0 ? m.seconds / m.ticks : 2.0;
      down.update(m.start, (v) => v + m.downTicks * perTick, ifAbsent: () => m.downTicks * perTick);
    }
    final result = <Outage>[];
    for (final ts in down.keys.toList()..sort()) {
      final last = result.isEmpty ? null : result.last;
      if (last != null && ts - last.end <= 60) {
        last
          ..end = ts
          ..downSeconds += down[ts]!;
      } else {
        result.add(Outage(ts, ts, down[ts]!));
      }
    }
    return result;
  }();

  /// Buckets that scored below "Good", worst first.
  List<QualityBin> worstPeriods({int limit = 6}) {
    final poor = [
      for (final b in bins)
        if ((b.stats.score?.value ?? 100) < 75) b,
    ];
    poor.sort((a, b) {
      final byScore = a.stats.score!.value.compareTo(b.stats.score!.value);
      return byScore != 0 ? byScore : (b.stats.lossPercent ?? 0).compareTo(a.stats.lossPercent ?? 0);
    });
    return poor.take(limit).toList();
  }

  /// Call tests on the report's scope, newest first.
  List<CallTestResult> get scopeCallTests => selected == null
      ? callTests
      : [
          for (final t in callTests)
            if (selected!.ips.contains(t.server)) t,
        ];

  /// Comparison rows that have a score, best first.
  List<ServerQuality> get scoredRows => [
        for (final r in rows)
          if (r.stats.score != null) r,
      ];

  /// Rows whose UDP probes never got an answer while HTTPS worked.
  List<ServerQuality> get udpBlockedRows => [
        for (final r in rows)
          if (r.stats.udpBlocked) r,
      ];

  /// Display name of a row, as in the comparison table.
  String titleOf(ServerQuality row) => serverTitle(row.info, grouping: grouping);

  /// Display name of an exit IP.
  String serverName(String ip) {
    final info = servers[ip];
    if (info == null) return ip.isEmpty ? 'Unknown network' : ip;
    return serverTitle(info);
  }

  /// Whether [row] contains the exit point currently in use.
  bool isCurrent(ServerQuality row) => current != null && row.ips.contains(current!.ip);
}
