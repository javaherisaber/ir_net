/// Turns a [QualityReport] into things a network admin can read: a short
/// text summary, a ZIP of CSV files and (see `quality_report_pdf.dart`) a PDF.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../data/call_quality.dart';
import '../data/quality.dart';
import '../data/quality_report.dart';
import '../ui/format.dart';

// ───────────────────────────── wording ─────────────────────────────

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int v) => v.toString().padLeft(2, '0');

DateTime _at(int epochSeconds) => DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);

/// "Oct 26, 2026 14:05" (local time).
String reportDateTime(DateTime t) => '${_months[t.month - 1]} ${t.day}, ${t.year} ${_two(t.hour)}:${_two(t.minute)}';

/// "UTC+03:30".
String utcOffsetLabel(Duration offset) {
  if (offset == Duration.zero) return 'UTC';
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  return 'UTC$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
}

/// "Oct 25, 2026 14:05 – Oct 26, 2026 14:05 (UTC+03:30)".
String reportPeriod(QualityReport r) {
  final from = _at(r.from);
  final to = _at(r.end);
  final sameDay = from.year == to.year && from.month == to.month && from.day == to.day;
  final range = sameDay
      ? '${reportDateTime(from)}–${_two(to.hour)}:${_two(to.minute)}'
      : '${reportDateTime(from)} – ${reportDateTime(to)}';
  return '$range (${utcOffsetLabel(r.generatedAt.timeZoneOffset)})';
}

/// "Last 24 hours" / "All time".
String reportRangeLabel(QualityReport r) => r.range.span == null ? r.range.label : 'Last ${r.range.label}';

/// "All servers, by IP" or the selected comparison row.
String reportScope(QualityReport r) {
  final selected = r.selected;
  if (selected == null) {
    return r.grouping == QualityGrouping.server ? 'All servers, compared by IP' : 'All servers, compared by location';
  }
  final title = r.titleOf(selected);
  final ips = selected.ips.length == 1 ? selected.ips.single : '${selected.ips.length} IPs';
  return title == ips ? title : '$title ($ips)';
}

/// A history bucket, always with its date: "Oct 26, 09:00–10:00".
String binLabel(int start, int binSeconds) {
  if (binSeconds >= 86400) return formatBin(start, binSeconds);
  return '${formatDay(start)}, ${formatClock(start)}–${formatClock(start + binSeconds)}';
}

String formatMosValue(double? mos) => mos == null ? '—' : mos.toStringAsFixed(1);

String formatMbpsValue(double? mbps) {
  if (mbps == null) return '—';
  return mbps < 10 ? '${mbps.toStringAsFixed(1)} Mbps' : '${mbps.round()} Mbps';
}

/// "IRNet-network-quality-2026-10-26-1405.pdf".
String reportFileName(QualityReport r, String extension) => qualityFileName(r.generatedAt, extension);

/// Name of a quality export or screenshot made at [t].
String qualityFileName(DateTime t, String extension) =>
    'IRNet-network-quality-${t.year}-${_two(t.month)}-${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}.$extension';

String _times(int n) => n == 1 ? 'once' : (n == 2 ? 'twice' : '$n times');

// ───────────────────────────── findings ─────────────────────────────

/// How a finding reads at a glance.
enum FindingTone { good, warn, bad, info }

class ReportFinding {
  const ReportFinding(this.tone, this.text);
  final FindingTone tone;
  final String text;
}

FindingTone toneOfGrade(QualityGrade? grade) => switch (grade) {
      QualityGrade.excellent || QualityGrade.good => FindingTone.good,
      QualityGrade.fair => FindingTone.warn,
      QualityGrade.poor || QualityGrade.bad || QualityGrade.down => FindingTone.bad,
      null => FindingTone.info,
    };

FindingTone toneOfRating(MetricRating? rating) => switch (rating) {
      MetricRating.good => FindingTone.good,
      MetricRating.fair => FindingTone.warn,
      MetricRating.poor => FindingTone.bad,
      null => FindingTone.info,
    };

FindingTone _worst(Iterable<FindingTone> tones) {
  const order = [FindingTone.bad, FindingTone.warn, FindingTone.good];
  for (final t in order) {
    if (tones.contains(t)) return t;
  }
  return FindingTone.info;
}

/// Plain-language observations, most important first.
List<ReportFinding> reportFindings(QualityReport r) {
  final s = r.total;
  final score = s.score;
  final out = <ReportFinding>[];
  if (score == null) {
    out.add(const ReportFinding(FindingTone.info, 'No quality measurements were recorded in this period.'));
  } else if (score.grade == QualityGrade.down) {
    out.add(ReportFinding(FindingTone.bad,
        'No probe got an answer during the ${formatDuration(r.monitored)} monitored: the connection was down.'));
  } else {
    out.add(ReportFinding(toneOfGrade(score.grade),
        'Overall quality was ${score.grade.label.toLowerCase()}: score ${score.value}/100 over ${formatDuration(r.monitored)} of monitoring.'));

    if (s.udpBlocked) {
      out.add(const ReportFinding(FindingTone.warn,
          'UDP probes got no answers while HTTPS worked: this connection does not carry UDP, so call apps fall back to slower TCP relays. Ping and jitter come from HTTPS here.'));
    }

    final ping = s.latency;
    if (ping != null) {
      final via = identical(s.primary, s.udp) ? 'UDP' : 'HTTPS';
      final delay = s.http.avgRtt;
      out.add(ReportFinding(
        _worst([toneOfRating(QualityMetric.ping.rate(ping)), toneOfRating(QualityMetric.jitter.rate(s.jitter))]),
        'Ping averaged ${formatMs(ping)} with ${formatMs(s.jitter)} of jitter ($via)'
        '${delay == null ? '' : '; an HTTPS request (the "real delay") took ${formatMs(delay)} on average'}.',
      ));
    }

    final loss = s.lossPercent;
    if (loss != null) {
      final lossy = r.lossyMinutes();
      final measured = r.measuredMinutes;
      var tone = toneOfRating(QualityMetric.loss.rate(loss));
      if (tone == FindingTone.good && measured > 0 && lossy / measured > 0.02) tone = FindingTone.warn;
      final text = loss == 0 ? 'No packet loss was measured' : 'Packet loss averaged ${formatPercent(loss)}';
      final burst = lossy == 0 ? '' : '; $lossy of $measured minutes lost more than 5% of packets';
      out.add(ReportFinding(tone, '$text$burst.'));
    }

    final outages = r.outages;
    if (outages.isEmpty) {
      if (s.ticks > 0) out.add(const ReportFinding(FindingTone.good, 'No complete outages were detected.'));
    } else {
      final down = outages.fold<double>(0, (t, o) => t + o.downSeconds);
      final longest = outages.reduce((a, b) => b.downSeconds > a.downSeconds ? b : a);
      out.add(ReportFinding(
        _worst([FindingTone.warn, toneOfRating(QualityMetric.uptime.rate(s.uptimePercent))]),
        'Connectivity dropped completely ${_times(outages.length)}, about '
        '${formatDuration(Duration(seconds: down.round()))} in total (uptime ${formatPercent(s.uptimePercent, digits: 2)}); '
        'the longest drop was around ${formatDayClock(longest.start)}.',
      ));
    }

    final voice = s.call(CallKind.voice);
    final video = s.call(CallKind.video);
    if (voice != null && video != null) {
      out.add(ReportFinding(
        _worst([toneOfGrade(voice.grade), toneOfGrade(video.grade)]),
        'Estimated call quality: voice MOS ${formatMosValue(voice.mos)} (${voice.grade.label.toLowerCase()}), '
        'video MOS ${formatMosValue(video.mos)} (${video.grade.label.toLowerCase()})${voice.viaTcp ? ', over TCP relays' : ''}.',
      ));
    }
  }

  if (r.scopeCallTests.isNotEmpty) {
    final t = r.scopeCallTests.first;
    final tier = t.tier;
    final result = t.udpBlocked
        ? 'no UDP packet got through'
        : 'voice MOS ${formatMosValue(t.voice.mos)}, video MOS ${formatMosValue(t.video.mos)}, ${formatPercent(t.lossPercent)} loss';
    out.add(ReportFinding(
      t.udpBlocked ? FindingTone.bad : toneOfGrade(t.voice.grade),
      'Latest call test (${formatDayClock(t.at.millisecondsSinceEpoch ~/ 1000)}, ${r.serverName(t.server)}): $result'
      '${tier == null ? '' : ', bandwidth for ${tier == VideoTier.audioOnly ? 'audio only' : '${tier.label} video'}'}.',
    ));
  }

  final scored = r.scoredRows;
  if (scored.length >= 2) {
    final noun = r.grouping == QualityGrouping.server ? 'server' : 'location';
    final best = scored.first;
    final worst = scored.last;
    out.add(ReportFinding(FindingTone.info,
        'Best $noun: ${r.titleOf(best)} (score ${best.stats.score!.value}); worst: ${r.titleOf(worst)} (score ${worst.stats.score!.value}).'));
  }
  if (r.rows.length > 1) {
    for (final row in r.udpBlockedRows.take(3)) {
      out.add(ReportFinding(FindingTone.warn, 'UDP is blocked on ${r.titleOf(row)}: calls there use TCP relays.'));
    }
  }

  final worst = r.worstPeriods(limit: 1);
  if (worst.isNotEmpty) {
    final st = worst.first.stats;
    out.add(ReportFinding(toneOfGrade(st.score!.grade),
        'Worst period: ${binLabel(worst.first.start, r.binSeconds)}, score ${st.score!.value} '
        '(${formatPercent(st.lossPercent)} loss, ${formatMs(st.latency)} ping).'));
  }
  return out;
}

// ───────────────────────────── text summary ─────────────────────────────

/// A plain-text version of the report, for pasting into a chat or e-mail.
String reportSummary(QualityReport r) {
  final b = StringBuffer()
    ..writeln('IRNet network quality report')
    ..writeln('Period: ${reportRangeLabel(r)}, ${reportPeriod(r)}')
    ..writeln('Scope: ${reportScope(r)}');
  final current = r.current;
  if (current != null) {
    b.writeln('Current exit: ${[current.ip, current.place, current.isp].where((s) => s != null && s.isNotEmpty).join(' — ')}');
  }
  final by = [if (r.appVersion.isNotEmpty) 'IRNet ${r.appVersion}' else 'IRNet', if (r.platform.isNotEmpty) 'on ${r.platform}'];
  b.writeln('Generated by ${by.join(' ')}, ${reportDateTime(r.generatedAt)}');

  final s = r.total;
  final score = s.score;
  b.writeln();
  if (score == null) {
    b.writeln('No quality measurements in this period.');
  } else {
    b
      ..writeln('Overall: ${score.grade.label}, score ${score.value}/100 (${formatDuration(r.monitored)} monitored)')
      ..writeln('Ping ${formatMs(s.latency)} · Jitter ${formatMs(s.jitter)} · Loss ${formatPercent(s.lossPercent)} · '
          'Real delay ${formatMs(s.http.avgRtt)} · Uptime ${formatPercent(s.uptimePercent)}');
    final voice = s.call(CallKind.voice);
    final video = s.call(CallKind.video);
    if (voice != null && video != null) {
      b.writeln('Calls: voice MOS ${formatMosValue(voice.mos)} (${voice.grade.label}) · '
          'video MOS ${formatMosValue(video.mos)} (${video.grade.label})');
    }
  }

  b
    ..writeln()
    ..writeln('Key findings');
  for (final f in reportFindings(r)) {
    b.writeln('- ${f.text}');
  }

  if (r.rows.isNotEmpty) {
    b
      ..writeln()
      ..writeln(r.grouping == QualityGrouping.server ? 'Servers (best first)' : 'Locations (best first)');
    var i = 0;
    for (final row in r.rows) {
      i++;
      final st = row.stats;
      final sc = st.score;
      final ips = row.ips.length == 1 ? row.ips.single : '${row.ips.length} IPs';
      final title = r.titleOf(row);
      b.writeln('$i. ${title == ips ? title : '$title ($ips)'}${r.isCurrent(row) ? ' [current]' : ''}: '
          '${sc == null ? 'no score' : 'score ${sc.value} (${sc.grade.label})'} · ping ${formatMs(st.latency)} · '
          'jitter ${formatMs(st.jitter)} · loss ${formatPercent(st.lossPercent)} · uptime ${formatPercent(st.uptimePercent)} · '
          'voice ${formatMosValue(st.call(CallKind.voice)?.mos)} · video ${formatMosValue(st.call(CallKind.video)?.mos)} · '
          '${formatDuration(row.monitored)}');
    }
  }

  if (r.callTests.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Call tests');
    for (final t in r.callTests.take(10)) {
      final tier = t.tier;
      b.writeln('- ${formatDayClock(t.at.millisecondsSinceEpoch ~/ 1000)} · ${r.serverName(t.server)}: '
          '${t.udpBlocked ? 'UDP blocked' : 'voice ${formatMosValue(t.voice.mos)} · video ${formatMosValue(t.video.mos)} · loss ${formatPercent(t.lossPercent)}'}'
          '${t.downMbps == null ? '' : ' · ${formatMbpsValue(t.downMbps)} down / ${formatMbpsValue(t.upMbps)} up'}'
          '${tier == null ? '' : ' · ${tier.label}'}');
    }
  }
  return b.toString();
}

// ───────────────────────────── CSV ─────────────────────────────

/// One CSV field (RFC 4180 quoting).
String csvField(Object? value) {
  if (value == null) return '';
  final text = '$value';
  if (text.contains(RegExp(r'[",\r\n]'))) return '"${text.replaceAll('"', '""')}"';
  return text;
}

/// A CSV table. Starts with a byte-order mark so Excel reads it as UTF-8.
String _csv(List<String> header, Iterable<List<Object?>> rows) {
  final b = StringBuffer()..write('\uFEFF${header.join(',')}\r\n');
  for (final row in rows) {
    b.write('${row.map(csvField).join(',')}\r\n');
  }
  return b.toString();
}

String? _num(double? v, [int digits = 1]) => v?.toStringAsFixed(digits);

/// ISO 8601 local time with its UTC offset: "2026-10-26T14:05:00+03:30".
String isoLocal(int epochSeconds) {
  final t = _at(epochSeconds);
  final offset = utcOffsetLabel(t.timeZoneOffset).replaceFirst('UTC', '');
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}${offset.isEmpty ? 'Z' : offset}';
}

String serversCsv(QualityReport r) => _csv(
      [
        'name', 'label', 'ips', 'country', 'country_code', 'region', 'city', 'isp', 'current', 'first_minute',
        'last_minute', 'monitored_s', 'score', 'grade', 'ping_ms', 'ping_min_ms', 'ping_max_ms', 'jitter_ms',
        'loss_pct', 'real_delay_ms', 'uptime_pct', 'voice_mos', 'video_mos', 'udp_sent', 'udp_received',
        'https_sent', 'https_ok',
      ],
      r.rows.map((row) {
        final s = row.stats;
        final info = row.info;
        final p = s.primary;
        return [
          r.titleOf(row), info.label, row.ips.join(' '), info.country, info.countryCode, info.region, info.city,
          info.isp, r.isCurrent(row) ? 'yes' : 'no', isoLocal(row.firstTs), isoLocal(row.lastTs),
          row.monitored.inSeconds, s.score?.value, s.score?.grade.label, _num(s.latency), _num(p.rttMin),
          _num(p.rttMax), _num(s.jitter), _num(s.lossPercent, 2), _num(s.http.avgRtt), _num(s.uptimePercent, 2),
          _num(s.call(CallKind.voice)?.mos, 2), _num(s.call(CallKind.video)?.mos, 2), s.udp.sent, s.udp.received,
          s.http.sent, s.http.received,
        ];
      }),
    );

String minutesCsv(QualityReport r) => _csv(
      [
        'time', 'server_ip', 'ticks', 'down_ticks', 'seconds', 'udp_sent', 'udp_received', 'udp_avg_ms',
        'udp_min_ms', 'udp_max_ms', 'udp_jitter_ms', 'https_sent', 'https_ok', 'https_avg_ms', 'https_min_ms',
        'https_max_ms', 'https_jitter_ms', 'loss_pct', 'score',
      ],
      r.minutes.map((m) => [
            isoLocal(m.start), m.server, m.ticks, m.downTicks, _num(m.seconds), m.udp.sent, m.udp.received,
            _num(m.udp.avgRtt), _num(m.udp.rttMin), _num(m.udp.rttMax), _num(m.udp.jitter), m.http.sent,
            m.http.received, _num(m.http.avgRtt), _num(m.http.rttMin), _num(m.http.rttMax), _num(m.http.jitter),
            _num(m.lossPercent, 2), m.score?.value,
          ]),
    );

String historyCsv(QualityReport r) => _csv(
      [
        'start', 'end', 'score', 'grade', 'ping_ms', 'ping_min_ms', 'ping_max_ms', 'jitter_ms', 'loss_pct',
        'real_delay_ms', 'uptime_pct', 'voice_mos', 'video_mos', 'monitored_s',
      ],
      r.bins.map((b) {
        final s = b.stats;
        final p = s.primary;
        return [
          isoLocal(b.start), isoLocal(b.start + r.binSeconds), s.score?.value, s.score?.grade.label,
          _num(s.latency), _num(p.rttMin), _num(p.rttMax), _num(s.jitter), _num(s.lossPercent, 2),
          _num(s.http.avgRtt), _num(s.uptimePercent, 2), _num(s.call(CallKind.voice)?.mos, 2),
          _num(s.call(CallKind.video)?.mos, 2), s.seconds.round(),
        ];
      }),
    );

String callTestsCsv(QualityReport r) => _csv(
      [
        'time', 'server_ip', 'server', 'packets_sent', 'packets_received', 'late', 'loss_pct', 'late_pct',
        'max_burst', 'burst_ratio', 'rtt_median_ms', 'rtt_p95_ms', 'jitter_ms', 'voice_mos', 'video_mos',
        'via_tcp', 'down_mbps', 'up_mbps', 'video_tier',
      ],
      r.callTests.map((t) => [
            isoLocal(t.at.millisecondsSinceEpoch ~/ 1000), t.server, r.serverName(t.server), t.sent, t.received,
            t.late, _num(t.lossPercent, 2), _num(t.latePercent, 2), t.maxBurst, _num(t.burstRatio, 2),
            _num(t.rttMedian), _num(t.rttP95), _num(t.jitter), _num(t.voice.mos, 2), _num(t.video.mos, 2),
            t.voice.viaTcp ? 'yes' : 'no', _num(t.downMbps, 2), _num(t.upMbps, 2), t.tier?.label,
          ]),
    );

String probesCsv(QualityReport r) => _csv(
      ['time', 'server_ip', 'kind', 'rtt_ms', 'lost'],
      r.samples.map((p) => [
            isoLocal(p.time.millisecondsSinceEpoch ~/ 1000), p.server, p.kind == ProbeKind.udp ? 'udp' : 'https',
            _num(p.rtt), p.lost ? 'yes' : 'no',
          ]),
    );

const _filesGuide = '''
Files
- servers.csv     One row per server (exit IP) or location: score, ping, jitter, loss, real delay, uptime, call MOS.
- history.csv     The charted history: one row per time bucket of the report's scope.
- minutes.csv     Every stored minute of the period for every server (raw counters and timings).
- call_tests.csv  Simulated calls run in the period (400 voice packets + a bandwidth check).
- probes.csv      The latest individual probes still in memory (a few minutes).

Times are local, ISO 8601 with the UTC offset. Ping/jitter: UDP STUN round trips. Real delay:
HTTPS request on a warm connection. Score: ITU-T G.107 E-model, scaled to 0-100. MOS: 1-4.5.
''';

/// The report as a ZIP: README.txt plus one CSV per table.
Uint8List buildReportZip(QualityReport r) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('README.txt', '${reportSummary(r)}\n$_filesGuide'))
    ..addFile(ArchiveFile.string('servers.csv', serversCsv(r)))
    ..addFile(ArchiveFile.string('history.csv', historyCsv(r)))
    ..addFile(ArchiveFile.string('minutes.csv', minutesCsv(r)))
    ..addFile(ArchiveFile.string('call_tests.csv', callTestsCsv(r)))
    ..addFile(ArchiveFile.string('probes.csv', probesCsv(r)));
  return ZipEncoder().encodeBytes(archive, modified: r.generatedAt);
}
