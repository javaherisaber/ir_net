import 'dart:math' as math;

/// How a probe measures the path.
///
/// [udp] is a STUN binding request: one small datagram each way, so a missing
/// reply is a lost packet and the timing is the raw network round trip.
/// [http] is a HEAD request on a warm HTTPS connection (the "real delay" VPN
/// clients show): what a TCP app actually waits for, through the system proxy.
enum ProbeKind { udp, http }

/// One probe outcome, kept in memory for the live chart.
class ProbeSample {
  const ProbeSample(this.time, this.kind, this.rtt, {this.server = ''});

  final DateTime time;
  final ProbeKind kind;

  /// Round-trip time in milliseconds, or null when no reply came back in time.
  final double? rtt;

  /// Exit IP the probe was attributed to.
  final String server;

  bool get lost => rtt == null;
}

/// Running statistics for one probe series (UDP or HTTP).
///
/// Jitter is the mean absolute difference between consecutive replies (the
/// definition speed tests use), so it is accumulated as a sum + count and can
/// be merged across minutes exactly.
class SeriesStats {
  int sent = 0;
  int received = 0;
  double rttSum = 0;
  double? rttMin;
  double? rttMax;
  double jitterSum = 0;
  int jitterCount = 0;

  void addLost() => sent++;

  /// Records a reply. [previous] is the series' previous reply on the same
  /// server, when there is one.
  void addReply(double rtt, {double? previous}) {
    sent++;
    received++;
    rttSum += rtt;
    rttMin = rttMin == null ? rtt : math.min(rttMin!, rtt);
    rttMax = rttMax == null ? rtt : math.max(rttMax!, rtt);
    if (previous != null) {
      jitterSum += (rtt - previous).abs();
      jitterCount++;
    }
  }

  void merge(SeriesStats other) {
    sent += other.sent;
    received += other.received;
    rttSum += other.rttSum;
    rttMin = _minOf(rttMin, other.rttMin);
    rttMax = _maxOf(rttMax, other.rttMax);
    jitterSum += other.jitterSum;
    jitterCount += other.jitterCount;
  }

  double? get avgRtt => received == 0 ? null : rttSum / received;
  double? get jitter => jitterCount == 0 ? null : jitterSum / jitterCount;

  /// Share of probes without a reply, 0–100.
  double? get lossPercent => sent == 0 ? null : (sent - received) * 100 / sent;
}

double? _minOf(double? a, double? b) => a == null ? b : (b == null ? a : math.min(a, b));
double? _maxOf(double? a, double? b) => a == null ? b : (b == null ? a : math.max(a, b));

/// Aggregated quality over some span (a minute, a chart bin, a whole range).
class QualityStats {
  /// Monitoring ticks (one per probe interval) and how many of them had no
  /// connectivity at all (UDP lost and HTTPS failing).
  int ticks = 0;
  int downTicks = 0;

  /// Time actually monitored (sum of the probe intervals).
  double seconds = 0;
  final SeriesStats udp = SeriesStats();
  final SeriesStats http = SeriesStats();

  void merge(QualityStats other) {
    ticks += other.ticks;
    downTicks += other.downTicks;
    seconds += other.seconds;
    udp.merge(other.udp);
    http.merge(other.http);
  }

  bool get hasData => ticks > 0 || udp.sent > 0 || http.sent > 0;

  /// UDP never got through while HTTPS did: the VPN does not carry UDP.
  bool get udpBlocked => udp.sent >= 3 && udp.received == 0 && http.received > 0;

  /// The series the score and headline latency come from: UDP when it works,
  /// otherwise HTTPS, otherwise whichever was probed at all (so an outage
  /// shows as "Offline" rather than "no data").
  SeriesStats get primary {
    if (udp.received > 0) return udp;
    if (http.received > 0) return http;
    return udp.sent > 0 ? udp : http;
  }

  double? get latency => primary.avgRtt;
  double? get jitter => primary.jitter;
  double? get lossPercent => udp.sent > 0 && !udpBlocked ? udp.lossPercent : http.lossPercent;

  /// Share of ticks with working connectivity, 0–100.
  double? get uptimePercent => ticks == 0 ? null : (ticks - downTicks) * 100 / ticks;

  QualityScore? get score => QualityScore.of(this);
}

enum QualityGrade { excellent, good, fair, poor, bad, down }

extension QualityGradeLabel on QualityGrade {
  String get label => switch (this) {
        QualityGrade.excellent => 'Excellent',
        QualityGrade.good => 'Good',
        QualityGrade.fair => 'Fair',
        QualityGrade.poor => 'Poor',
        QualityGrade.bad => 'Bad',
        QualityGrade.down => 'Offline',
      };
}

/// A 0–100 quality score derived from the ITU-T G.107 E-model (the
/// simplified form network monitors use for VoIP MOS): latency, jitter and
/// loss each pull the R-factor down, then R is scaled so a perfect path is 100.
class QualityScore {
  const QualityScore(this.value, this.grade);

  final int value;
  final QualityGrade grade;

  static const _maxR = 93.2;

  static QualityScore? of(QualityStats stats) {
    final series = stats.primary;
    if (series.sent == 0) return null;
    if (series.received == 0) return const QualityScore(0, QualityGrade.down);
    final r = rFactor(
      latencyMs: series.avgRtt!,
      jitterMs: series.jitter ?? 0,
      lossPercent: series.lossPercent ?? 0,
    );
    return fromR(r);
  }

  static QualityScore fromR(double r) {
    final value = (r / _maxR * 100).round().clamp(0, 100);
    return QualityScore(value, gradeOf(value));
  }

  static QualityGrade gradeOf(int value) {
    if (value >= 90) return QualityGrade.excellent;
    if (value >= 75) return QualityGrade.good;
    if (value >= 60) return QualityGrade.fair;
    if (value >= 40) return QualityGrade.poor;
    return QualityGrade.bad;
  }

  /// Simplified E-model R-factor (0–93.2).
  static double rFactor({
    required double latencyMs,
    required double jitterMs,
    required double lossPercent,
  }) {
    final effective = latencyMs + jitterMs * 2 + 10;
    var r = effective < 160 ? _maxR - effective / 40 : _maxR - (effective - 120) / 10;
    r -= lossPercent * 2.5;
    return r.clamp(0.0, _maxR);
  }
}

/// One minute of measurements for one exit IP, as stored in `quality_minute`.
class QualityWindow extends QualityStats {
  QualityWindow(this.start, this.server);

  /// Minute start, seconds since epoch (UTC).
  final int start;
  final String server;

  /// Changed since it was last written to the database.
  bool dirty = false;

  Map<String, Object?> toRow() => {
        'ts': start,
        'server': server,
        'ticks': ticks,
        'down_ticks': downTicks,
        'secs': seconds,
        'udp_sent': udp.sent,
        'udp_recv': udp.received,
        'udp_rtt_sum': udp.rttSum,
        'udp_rtt_min': udp.rttMin,
        'udp_rtt_max': udp.rttMax,
        'udp_jitter_sum': udp.jitterSum,
        'udp_jitter_n': udp.jitterCount,
        'http_sent': http.sent,
        'http_ok': http.received,
        'http_rtt_sum': http.rttSum,
        'http_rtt_min': http.rttMin,
        'http_rtt_max': http.rttMax,
        'http_jitter_sum': http.jitterSum,
        'http_jitter_n': http.jitterCount,
      };
}

/// A stored minute row.
QualityWindow qualityWindowFromRow(Map<String, Object?> row) =>
    QualityWindow((row['ts'] as num).toInt(), row['server'] as String)..merge(qualityStatsFromRow(row));

/// Reads the aggregate columns produced by `QualityStore` queries.
QualityStats qualityStatsFromRow(Map<String, Object?> row) {
  int i(String k) => (row[k] as num?)?.toInt() ?? 0;
  double d(String k) => (row[k] as num?)?.toDouble() ?? 0;
  double? n(String k) => (row[k] as num?)?.toDouble();
  final stats = QualityStats()
    ..ticks = i('ticks')
    ..downTicks = i('down_ticks')
    ..seconds = d('secs');
  stats.udp
    ..sent = i('udp_sent')
    ..received = i('udp_recv')
    ..rttSum = d('udp_rtt_sum')
    ..rttMin = n('udp_rtt_min')
    ..rttMax = n('udp_rtt_max')
    ..jitterSum = d('udp_jitter_sum')
    ..jitterCount = i('udp_jitter_n');
  stats.http
    ..sent = i('http_sent')
    ..received = i('http_ok')
    ..rttSum = d('http_rtt_sum')
    ..rttMin = n('http_rtt_min')
    ..rttMax = n('http_rtt_max')
    ..jitterSum = d('http_jitter_sum')
    ..jitterCount = i('http_jitter_n');
  return stats;
}

/// Exit point (VPN server / ISP) identified by its public IP.
class ServerInfo {
  const ServerInfo({
    required this.ip,
    this.country,
    this.countryCode,
    this.region,
    this.city,
    this.isp,
    this.label,
    this.firstSeen,
    this.lastSeen,
  });

  final String ip;
  final String? country;
  final String? countryCode;
  final String? region;
  final String? city;
  final String? isp;

  /// User-given name, e.g. "Hetzner DE #2".
  final String? label;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  /// From the ip-api.com lookup the app already runs (fields=8923).
  static ServerInfo? fromLookup(dynamic json) {
    if (json is! Map) return null;
    final ip = _s(json['query']);
    if (ip == null) return null;
    return ServerInfo(
      ip: ip,
      country: _s(json['country']),
      countryCode: _s(json['countryCode']),
      region: _s(json['regionName']),
      city: _s(json['city']),
      isp: _s(json['isp']),
    );
  }

  factory ServerInfo.fromRow(Map<String, Object?> row) => ServerInfo(
        ip: row['ip'] as String,
        country: row['country'] as String?,
        countryCode: row['country_code'] as String?,
        region: row['region'] as String?,
        city: row['city'] as String?,
        isp: row['isp'] as String?,
        label: row['label'] as String?,
        firstSeen: _date(row['first_seen']),
        lastSeen: _date(row['last_seen']),
      );

  /// "Frankfurt, Germany" – whatever parts are known.
  String get place => [city, country].whereType<String>().join(', ');

  /// The same server without its user-given name.
  ServerInfo get unlabeled => ServerInfo(
        ip: ip,
        country: country,
        countryCode: countryCode,
        region: region,
        city: city,
        isp: isp,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
      );

  bool get isIran => country == 'Iran';

  static String? _s(dynamic v) => (v == null || '$v'.isEmpty) ? null : '$v';
  static DateTime? _date(Object? v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v * 1000) : null;
}

/// How the comparison table groups measurements.
enum QualityGrouping { server, location }

/// A server's display name: its user-given label, else its location, else the IP.
String serverTitle(ServerInfo info, {QualityGrouping grouping = QualityGrouping.server}) {
  if (grouping == QualityGrouping.server && info.label != null) return info.label!;
  final place = info.place;
  return place.isEmpty ? info.ip : place;
}

/// Traffic-light rating of a single metric (the dots next to values).
enum MetricRating { good, fair, poor }

/// Metrics with their good / fair limits, shared by the dashboard and reports.
enum QualityMetric {
  ping(120, 250),
  jitter(20, 50),
  loss(1, 5),
  delay(300, 800),
  uptime(99.5, 98, higherIsBetter: true);

  const QualityMetric(this.goodLimit, this.fairLimit, {this.higherIsBetter = false});

  final double goodLimit;
  final double fairLimit;
  final bool higherIsBetter;

  MetricRating? rate(double? value) {
    if (value == null) return null;
    if (higherIsBetter ? value >= goodLimit : value <= goodLimit) return MetricRating.good;
    if (higherIsBetter ? value >= fairLimit : value <= fairLimit) return MetricRating.fair;
    return MetricRating.poor;
  }
}

/// A comparison-table row: one exit IP, or every IP of one city.
class ServerQuality {
  ServerQuality({
    required this.key,
    required this.info,
    required this.stats,
    required this.ips,
    required this.firstTs,
    required this.lastTs,
  });

  final String key;

  /// Metadata of the (most recently seen) IP in this row.
  final ServerInfo info;
  final QualityStats stats;
  final List<String> ips;
  final int firstTs;
  final int lastTs;

  /// Time actually monitored. Rows written before durations were stored
  /// count 2 s (the default interval) per tick.
  Duration get monitored =>
      Duration(seconds: (stats.seconds > 0 ? stats.seconds : stats.ticks * 2).round());
}

/// One bucket of the history chart.
class QualityBin {
  const QualityBin(this.start, this.stats);

  /// Bucket start, seconds since epoch.
  final int start;
  final QualityStats stats;
}

/// History ranges offered by the quality dashboard.
enum QualityRange {
  hour1('1 hour', Duration(hours: 1)),
  hours6('6 hours', Duration(hours: 6)),
  hours24('24 hours', Duration(hours: 24)),
  days7('7 days', Duration(days: 7)),
  days30('30 days', Duration(days: 30)),
  all('All time', null);

  const QualityRange(this.label, this.span);

  final String label;

  /// Null for "all time".
  final Duration? span;
}
