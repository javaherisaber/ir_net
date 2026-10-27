import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:ir_net/data/call_quality.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/quality_bloc.dart';

import 'call_widgets.dart';
import 'charts.dart';
import 'components.dart';
import 'export_widgets.dart';
import 'format.dart';
import 'theme.dart';

// ───────────────────────────── shared bits ─────────────────────────────

/// Status colour for a grade (always shown with its label).
Color gradeColor(QualityGrade? grade) => switch (grade) {
      QualityGrade.excellent || QualityGrade.good => AppColors.good,
      QualityGrade.fair => AppColors.warn,
      QualityGrade.poor || QualityGrade.bad || QualityGrade.down => AppColors.bad,
      null => AppColors.text3,
    };

Color _gradeSoft(QualityGrade? grade) => switch (grade) {
      QualityGrade.excellent || QualityGrade.good => AppColors.goodSoft,
      QualityGrade.fair => AppColors.warnSoft,
      QualityGrade.poor || QualityGrade.bad || QualityGrade.down => AppColors.badSoft,
      null => AppColors.card2,
    };

class GradePill extends StatelessWidget {
  const GradePill(this.score, {super.key});
  final QualityScore? score;

  @override
  Widget build(BuildContext context) {
    final grade = score?.grade;
    return Pill(
      label: grade?.label ?? 'No data',
      dotColor: gradeColor(grade),
      textColor: grade == null ? AppColors.text3 : gradeColor(grade),
      background: _gradeSoft(grade),
    );
  }
}

/// Rectangular country flag, or a neutral globe when unknown.
class FlagIcon extends StatelessWidget {
  const FlagIcon(this.countryCode, {super.key, this.width = 20});
  final String? countryCode;
  final double width;

  @override
  Widget build(BuildContext context) {
    final code = countryCode;
    final height = width * 0.7;
    if (code == null || code.length != 2) {
      return SizedBox(
        width: width,
        height: height,
        child: Icon(Icons.public, size: height, color: AppColors.text3),
      );
    }
    return CountryFlag.fromCountryCode(
      code,
      theme: ImageTheme(width: width, height: height, shape: const RoundedRectangle(3)),
    );
  }
}

/// Status-dot colour for a metric value.
Color _metricColor(QualityMetric metric, double? v) => switch (metric.rate(v)) {
      MetricRating.good => AppColors.good,
      MetricRating.fair => AppColors.warn,
      MetricRating.poor => AppColors.bad,
      null => AppColors.text3,
    };

// ───────────────────────────── live card ─────────────────────────────

class QualityLiveCard extends StatelessWidget {
  const QualityLiveCard({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityLive>(
      stream: bloc.quality.live,
      builder: (context, snapshot) {
        final live = snapshot.data;
        if (live == null) {
          return const AppCard(child: SizedBox(height: 120, child: Center(child: _Spinner())));
        }
        if (!live.supported) {
          return const InfoBanner('Network quality monitoring needs the desktop or mobile app.');
        }
        return AppCard(
          gradient: AppGradients.card,
          padding: EdgeInsets.all(compact ? 16 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(live),
              SizedBox(height: compact ? 16 : 18),
              _scoreAndMetrics(live),
              const SizedBox(height: 18),
              if (live.running || live.samples.isNotEmpty)
                LiveProbeChart(live: live, height: compact ? 110 : 130)
              else
                _paused(),
              const SizedBox(height: 12),
              _footer(live),
            ],
          ),
        );
      },
    );
  }

  Widget _header(QualityLive live) {
    final server = live.server;
    final title = server == null ? 'Detecting your public IP…' : serverTitle(server);
    final detail = server == null
        ? 'Measurements are grouped by the IP you exit from'
        : [server.ip, server.isp].whereType<String>().join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: FlagIcon(server?.countryCode, width: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(16, FontWeight.w700, AppColors.text)),
                  ),
                  const SizedBox(width: 10),
                  _LiveBadge(running: live.running),
                ],
              ),
              const SizedBox(height: 3),
              Text(detail,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(11.5, FontWeight.w500, AppColors.text3)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        AppButton(
          label: live.running ? 'Pause' : 'Resume',
          icon: live.running ? Icons.pause : Icons.play_arrow,
          kind: live.running ? AppButtonKind.outline : AppButtonKind.ghostAccent,
          height: 34,
          onPressed: () => bloc.quality.setEnabled(!live.running),
        ),
      ],
    );
  }

  Widget _scoreAndMetrics(QualityLive live) {
    final s = live.recent;
    final score = s.score;
    final scoreBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Overline('Quality score'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(score == null ? '--' : '${score.value}',
                style: AppText.ui(52, FontWeight.w700, score == null ? AppColors.text3 : AppColors.text, height: 1)),
            const SizedBox(width: 5),
            Text('/100', style: AppText.ui(15, FontWeight.w500, AppColors.text3)),
          ],
        ),
        const SizedBox(height: 10),
        GradePill(score),
      ],
    );
    final via = s.udp.received > 0 ? 'UDP · avg' : (live.udpSkipped || s.udpBlocked ? 'HTTPS · avg' : 'UDP');
    final metrics = [
      _MetricTile('Ping', formatMs(s.latency), _metricColor(QualityMetric.ping, s.latency), hint: via),
      _MetricTile('Jitter', formatMs(s.jitter), _metricColor(QualityMetric.jitter, s.jitter), hint: via.split(' ').first),
      _MetricTile('Loss', formatPercent(s.lossPercent), _metricColor(QualityMetric.loss, s.lossPercent),
          hint: '${s.primary.sent - s.primary.received} of ${s.primary.sent} lost'),
      _MetricTile('Real delay', formatMs(s.http.avgRtt), _metricColor(QualityMetric.delay, s.http.avgRtt),
          hint: 'HTTPS · avg'),
      _MetricTile('Uptime', formatPercent(s.uptimePercent), _metricColor(QualityMetric.uptime, s.uptimePercent),
          hint: 'Connectivity'),
    ];
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 560) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            scoreBlock,
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in metrics) SizedBox(width: (c.maxWidth - 20) / 3, child: m),
              ],
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(width: 148, child: scoreBlock),
          const SizedBox(width: 8),
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: metrics[i]),
          ],
        ],
      );
    });
  }

  Widget _paused() {
    return Container(
      height: 90,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Text('Monitoring is paused. Resume it to collect measurements.',
          style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
    );
  }

  Widget _footer(QualityLive live) {
    final secs = live.interval.inSeconds;
    final httpOnly = live.udpSkipped || live.udpUnavailable != null;
    final parts = <String>[
      'Last ${QualityLive.liveWindow.inMinutes} min',
      if (live.udpSkipped)
        'HTTPS every ${secs * 2}s (system proxy: UDP not measured)'
      else if (live.udpUnavailable != null)
        'HTTPS every ${secs * 2}s (${live.udpUnavailable})'
      else
        'UDP every ${secs}s · HTTPS every ${secs * 5}s',
      '≈ ${estimatedDailyMegabytes(secs, udpSkipped: httpOnly)} MB/day',
    ];
    if (live.startedAt != null) {
      parts.add('running ${formatDuration(DateTime.now().difference(live.startedAt!))}');
    }
    return Row(
      children: [
        const Icon(Icons.info_outline, size: 13, color: AppColors.text3),
        const SizedBox(width: 7),
        Expanded(
          child: Text(parts.join(' · '),
              style: AppText.ui(11, FontWeight.w400, AppColors.text3, height: 1.4)),
        ),
      ],
    );
  }
}

/// Rough data cost of monitoring: ~250 B per STUN round trip and ~800 B per
/// HTTPS probe, tunnel overhead included.
int estimatedDailyMegabytes(int intervalSeconds, {bool udpSkipped = false}) {
  final ticks = 86400 / intervalSeconds;
  final bytes = udpSkipped ? ticks / 2 * 800 : ticks * 250 + ticks / 5 * 800;
  return (bytes / (1024 * 1024)).ceil();
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Pill(
      label: running ? 'LIVE' : 'PAUSED',
      dotColor: running ? AppColors.good : AppColors.text3,
      textColor: running ? AppColors.accent : AppColors.text3,
      background: running ? const Color(0x1433D6C6) : AppColors.card,
      borderColor: running ? const Color(0x5933D6C6) : AppColors.line,
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile(this.label, this.value, this.status, {this.hint});

  final String label;
  final String value;
  final Color status;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(status, size: 6),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(9.5, FontWeight.w500, AppColors.text3, letterSpacing: 0.6)),
              ),
            ],
          ),
          const SizedBox(height: 7),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: AppText.mono(18, FontWeight.w600, AppColors.text)),
          ),
          const SizedBox(height: 2),
          Text(hint ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui(9.5, FontWeight.w400, AppColors.text3)),
        ],
      ),
    );
  }
}

/// Last few minutes of raw probes: ping (UDP), real delay (HTTPS), lost probes.
class LiveProbeChart extends StatelessWidget {
  const LiveProbeChart({super.key, required this.live, this.height = 130});
  final QualityLive live;
  final double height;

  @override
  Widget build(BuildContext context) {
    final samples = live.samples;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final from = now - QualityLive.chartWindow.inSeconds;
    double t(ProbeSample s) => s.time.millisecondsSinceEpoch / 1000;
    final udp = [for (final s in samples) if (s.kind == ProbeKind.udp) ChartPoint(t(s), s.rtt)];
    final http = [for (final s in samples) if (s.kind == ProbeKind.http) ChartPoint(t(s), s.rtt)];
    final lost = [for (final s in samples) if (s.lost) ChartPoint(t(s), 1)];
    final byTime = <double, List<ProbeSample>>{};
    for (final s in samples) {
      byTime.putIfAbsent(t(s), () => []).add(s);
    }
    final series = <ChartSeries>[
      if (!live.udpSkipped)
        ChartSeries(label: 'Ping (UDP)', color: AppColors.series1, points: udp),
      ChartSeries(label: 'Real delay (HTTPS)', color: AppColors.series2, points: http),
      ChartSeries(label: 'Lost', color: AppColors.bad, points: lost, style: SeriesStyle.marks),
    ];
    return TimeChart(
      from: from,
      to: now,
      step: live.interval.inSeconds.toDouble() * 5,
      panels: [
        ChartPanel(
          title: 'Live · last ${QualityLive.chartWindow.inMinutes} minutes',
          series: series,
          height: height,
          minYMax: 100,
          yFormat: (v) => '${v.round()}',
          showLegend: true,
        ),
      ],
      tooltipTitle: (x) => formatClock(x, seconds: true),
      tooltipLines: (x) => [
        for (final s in byTime[x] ?? const <ProbeSample>[])
          TooltipLine(
            s.kind == ProbeKind.udp ? 'Ping (UDP)' : 'Real delay (HTTPS)',
            s.lost ? 'Lost' : formatMs(s.rtt),
            color: s.lost ? AppColors.bad : (s.kind == ProbeKind.udp ? AppColors.series1 : AppColors.series2),
            key: s.lost ? TooltipKey.dot : TooltipKey.line,
          ),
      ],
    );
  }
}

// ───────────────────────────── filters ─────────────────────────────

/// Pill-shaped segmented control used by the dashboard filter rows.
class SegmentedPills<T> extends StatelessWidget {
  const SegmentedPills({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in values)
            _Segment(label: label(v), active: v == selected, onTap: () => onSelected(v)),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(label,
              style: AppText.ui(12, active ? FontWeight.w600 : FontWeight.w500,
                  active ? AppColors.accent : AppColors.text2)),
        ),
      ),
    );
  }
}

class QualityFilterBar extends StatelessWidget {
  const QualityFilterBar({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityFilter>(
      stream: bloc.quality.filter,
      builder: (context, snapshot) {
        final f = snapshot.data ?? const QualityFilter();
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    SegmentedPills<QualityRange>(
                      values: QualityRange.values,
                      selected: f.range,
                      label: (r) => r.label,
                      onSelected: bloc.quality.setRange,
                    ),
                    const SizedBox(width: 10),
                    SegmentedPills<QualityGrouping>(
                      values: QualityGrouping.values,
                      selected: f.grouping,
                      label: (g) => g == QualityGrouping.server ? 'By IP' : 'By location',
                      onSelected: bloc.quality.setGrouping,
                    ),
                  ],
                ),
              ),
            ),
            if (QualityBloc.isSupported) ...[
              const SizedBox(width: 10),
              const QualityExportButton(),
            ],
          ],
        );
      },
    );
  }
}

// ───────────────────────────── comparison ─────────────────────────────

enum _SortColumn { score, ping, jitter, loss, voice, video, delay, uptime, time }

class QualityCompareCard extends StatefulWidget {
  const QualityCompareCard({super.key});

  @override
  State<QualityCompareCard> createState() => _QualityCompareCardState();
}

class _QualityCompareCardState extends State<QualityCompareCard> {
  _SortColumn _sort = _SortColumn.score;

  double _sortValue(ServerQuality r) {
    final s = r.stats;
    // Larger = better, so a descending sort puts the best server first.
    return switch (_sort) {
      _SortColumn.score => (s.score?.value ?? -1).toDouble(),
      _SortColumn.ping => -(s.latency ?? double.infinity),
      _SortColumn.jitter => -(s.jitter ?? double.infinity),
      _SortColumn.loss => -(s.lossPercent ?? double.infinity),
      _SortColumn.voice => s.call(CallKind.voice)?.mos ?? -1,
      _SortColumn.video => s.call(CallKind.video)?.mos ?? -1,
      _SortColumn.delay => -(s.http.avgRtt ?? double.infinity),
      _SortColumn.uptime => s.uptimePercent ?? -1,
      _SortColumn.time => s.ticks.toDouble(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityDashboard>(
      stream: bloc.quality.dashboard,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final rows = [...?data?.rows]..sort((a, b) => _sortValue(b).compareTo(_sortValue(a)));
        return AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: LayoutBuilder(builder: (context, c) {
            // Nine metric columns need room; below this the rows go two-line.
            final wide = c.maxWidth >= 980;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _title(data),
                if (wide && rows.isNotEmpty) _headerRow(),
                if (data == null)
                  const SizedBox(height: 80, child: Center(child: _Spinner()))
                else if (rows.isEmpty)
                  _empty()
                else
                  for (final r in rows)
                    wide ? _wideRow(data, r) : _compactRow(data, r),
              ],
            );
          }),
        );
      },
    );
  }

  Widget _title(QualityDashboard? data) {
    final grouping = data?.filter.grouping ?? QualityGrouping.server;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(
        children: [
          const Icon(Icons.compare_arrows, size: 16, color: AppColors.accent),
          const SizedBox(width: 9),
          Text(grouping == QualityGrouping.server ? 'COMPARE SERVERS' : 'COMPARE LOCATIONS',
              style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6)),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Tap a row to chart it',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
          ),
        ],
      ),
    );
  }

  static const _cols = <(_SortColumn, String, double)>[
    (_SortColumn.score, 'Score', 124),
    (_SortColumn.ping, 'Ping', 70),
    (_SortColumn.jitter, 'Jitter', 62),
    (_SortColumn.loss, 'Loss', 62),
    (_SortColumn.voice, 'Voice', 58),
    (_SortColumn.video, 'Video', 58),
    (_SortColumn.delay, 'Real delay', 80),
    (_SortColumn.uptime, 'Uptime', 66),
    (_SortColumn.time, 'Measured', 76),
  ];

  Widget _headerRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(
        children: [
          Expanded(child: Text('SERVER', style: AppText.overline(AppColors.text3))),
          for (final (col, label, width) in _cols)
            SizedBox(
              width: width,
              child: InkWell(
                onTap: () => setState(() => _sort = col),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(label.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          style: AppText.overline(_sort == col ? AppColors.accent : AppColors.text3)),
                    ),
                    if (_sort == col) const Icon(Icons.arrow_downward, size: 11, color: AppColors.accent),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _serverCell(QualityDashboard data, ServerQuality r) {
    final grouping = data.filter.grouping;
    final title = serverTitle(r.info, grouping: grouping);
    final subtitle = grouping == QualityGrouping.server
        ? [r.info.ip, r.info.isp].whereType<String>().join(' · ')
        : '${r.ips.length} IP${r.ips.length == 1 ? '' : 's'}${r.info.isp == null ? '' : ' · ${r.info.isp}'}';
    return Row(
      children: [
        FlagIcon(r.info.countryCode),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(13, FontWeight.w600, AppColors.text)),
                  ),
                  if (data.isCurrent(r)) ...[
                    const SizedBox(width: 7),
                    const _NowBadge(),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono(10.5, FontWeight.w500, AppColors.text3)),
            ],
          ),
        ),
        if (grouping == QualityGrouping.server)
          IconButton(
            tooltip: 'Rename',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            color: AppColors.text3,
            onPressed: () => _rename(r.info),
            icon: const Icon(Icons.edit_outlined),
          ),
      ],
    );
  }

  Widget _rowFrame(QualityDashboard data, ServerQuality r, Widget child) {
    final selected = data.filter.selected == r.key;
    return Material(
      color: selected ? AppColors.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: () => bloc.quality.toggleSelected(r.key),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
          child: child,
        ),
      ),
    );
  }

  Widget _wideRow(QualityDashboard data, ServerQuality r) {
    final s = r.stats;
    final score = s.score;
    Widget num(String text, double width, {Color? dot}) => SizedBox(
          width: width,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (dot != null) ...[StatusDot(dot, size: 5), const SizedBox(width: 5)],
              Flexible(
                child: Text(text,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono(12, FontWeight.w500, AppColors.text)),
              ),
            ],
          ),
        );
    return _rowFrame(
      data,
      r,
      Row(
        children: [
          Expanded(child: _serverCell(data, r)),
          SizedBox(
            width: 124,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: 32,
                  child: Text(score == null ? '--' : '${score.value}',
                      textAlign: TextAlign.right, style: AppText.ui(16, FontWeight.w700, AppColors.text)),
                ),
                const SizedBox(width: 8),
                SizedBox(width: 78, child: Align(alignment: Alignment.centerLeft, child: _GradeChip(score))),
              ],
            ),
          ),
          num(formatMs(s.latency), 70, dot: _metricColor(QualityMetric.ping, s.latency)),
          num(formatMs(s.jitter), 62),
          num(formatPercent(s.lossPercent), 62, dot: _metricColor(QualityMetric.loss, s.lossPercent)),
          _mosCell(s.call(CallKind.voice), 58),
          _mosCell(s.call(CallKind.video), 58),
          num(formatMs(s.http.avgRtt), 80),
          num(formatPercent(s.uptimePercent), 66),
          num(formatDuration(r.monitored), 76),
        ],
      ),
    );
  }

  Widget _mosCell(CallQuality? q, double width) => SizedBox(
        width: width,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (q != null) ...[StatusDot(gradeColor(q.grade), size: 5), const SizedBox(width: 5)],
            Text(formatMos(q?.mos), style: AppText.mono(12, FontWeight.w500, AppColors.text)),
          ],
        ),
      );

  Widget _compactRow(QualityDashboard data, ServerQuality r) {
    final s = r.stats;
    return _rowFrame(
      data,
      r,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _serverCell(data, r)),
              const SizedBox(width: 8),
              Text(s.score == null ? '--' : '${s.score!.value}',
                  style: AppText.ui(18, FontWeight.w700, AppColors.text)),
              const SizedBox(width: 7),
              _GradeChip(s.score),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 31),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _kv('Ping', formatMs(s.latency)),
                _kv('Jitter', formatMs(s.jitter)),
                _kv('Loss', formatPercent(s.lossPercent)),
                _kv('Voice', formatMos(s.call(CallKind.voice)?.mos)),
                _kv('Video', formatMos(s.call(CallKind.video)?.mos)),
                _kv('Real delay', formatMs(s.http.avgRtt)),
                _kv('Uptime', formatPercent(s.uptimePercent)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Text.rich(TextSpan(children: [
        TextSpan(text: '$k ', style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
        TextSpan(text: v, style: AppText.mono(11.5, FontWeight.w500, AppColors.text)),
      ]));

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Text(
        'No measurements in this range yet. Keep monitoring running while you use each VPN '
        'server, then compare them here.',
        style: AppText.ui(12, FontWeight.w400, AppColors.text3, height: 1.5),
      ),
    );
  }

  Future<void> _rename(ServerInfo info) async {
    final controller = TextEditingController(text: info.label ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text('Name this server', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${info.ip}${info.place.isEmpty ? '' : ' · ${info.place}'}',
                style: AppText.mono(11.5, FontWeight.w500, AppColors.text3)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: AppText.ui(14, FontWeight.w500, AppColors.text),
              decoration: const InputDecoration(hintText: 'e.g. Hetzner DE #2'),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result != null) await bloc.quality.rename(info.ip, result);
  }
}

class _GradeChip extends StatelessWidget {
  const _GradeChip(this.score);
  final QualityScore? score;

  @override
  Widget build(BuildContext context) {
    final grade = score?.grade;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: _gradeSoft(grade), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(gradeColor(grade), size: 5),
          const SizedBox(width: 5),
          Text(grade?.label ?? '—', style: AppText.ui(10, FontWeight.w600, gradeColor(grade))),
        ],
      ),
    );
  }
}

class _NowBadge extends StatelessWidget {
  const _NowBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0x5933D6C6)),
      ),
      child: Text('NOW', style: AppText.ui(8.5, FontWeight.w700, AppColors.accent, letterSpacing: 0.6)),
    );
  }
}

// ───────────────────────────── history ─────────────────────────────

class QualityHistoryCard extends StatefulWidget {
  const QualityHistoryCard({super.key});

  @override
  State<QualityHistoryCard> createState() => _QualityHistoryCardState();
}

class _QualityHistoryCardState extends State<QualityHistoryCard> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityDashboard>(
      stream: bloc.quality.dashboard,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final selected = data?.selectedRow;
        final scope = selected == null
            ? 'All servers'
            : serverTitle(selected.info, grouping: data!.filter.grouping);
        return AppCard(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.show_chart, size: 16, color: AppColors.accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text('HISTORY · ${scope.toUpperCase()}',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6)),
                  ),
                  const SizedBox(width: 10),
                  SegmentedPills<bool>(
                    values: const [false, true],
                    selected: _table,
                    label: (t) => t ? 'Table' : 'Chart',
                    onSelected: (t) => setState(() => _table = t),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (data == null)
                const SizedBox(height: 200, child: Center(child: _Spinner()))
              else if (data.bins.isEmpty)
                SizedBox(
                  height: 120,
                  child: Center(
                    child: Text('No history in this range yet.',
                        style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
                  ),
                )
              else if (_table)
                _HistoryTable(data)
              else
                QualityHistoryChart(data: data),
            ],
          ),
        );
      },
    );
  }
}

/// Score, latency and loss as small multiples on one time axis.
class QualityHistoryChart extends StatelessWidget {
  const QualityHistoryChart({super.key, required this.data});
  final QualityDashboard data;

  @override
  Widget build(BuildContext context) {
    final bin = data.binSeconds.toDouble();
    final byTime = {for (final b in data.bins) b.start + bin / 2: b};
    double c(QualityBin b) => b.start + bin / 2;
    final score = [for (final b in data.bins) ChartPoint(c(b), b.stats.score?.value.toDouble())];
    final ping = [
      for (final b in data.bins)
        ChartPoint(c(b), b.stats.udp.avgRtt, lo: b.stats.udp.rttMin, hi: b.stats.udp.rttMax),
    ];
    final delay = [for (final b in data.bins) ChartPoint(c(b), b.stats.http.avgRtt)];
    final voice = [for (final b in data.bins) ChartPoint(c(b), b.stats.call(CallKind.voice)?.mos)];
    final video = [for (final b in data.bins) ChartPoint(c(b), b.stats.call(CallKind.video)?.mos)];
    final loss = [for (final b in data.bins) ChartPoint(c(b), b.stats.lossPercent)];
    return TimeChart(
      from: data.from.toDouble(),
      to: data.to.toDouble(),
      step: bin,
      panels: [
        ChartPanel(
          title: 'Quality score',
          height: 96,
          yMax: 100,
          series: [ChartSeries(label: 'Score', color: AppColors.accent, points: score, style: SeriesStyle.area)],
        ),
        ChartPanel(
          title: 'Calls (MOS)',
          height: 80,
          yMin: 1,
          yMax: 5,
          series: [
            ChartSeries(label: 'Voice', color: AppColors.series1, points: voice),
            ChartSeries(label: 'Video', color: AppColors.series2, points: video),
          ],
        ),
        ChartPanel(
          title: 'Latency (ms) · band = min–max ping',
          height: 110,
          minYMax: 100,
          series: [
            ChartSeries(label: 'Ping (UDP)', color: AppColors.series1, points: ping, band: true),
            ChartSeries(label: 'Real delay (HTTPS)', color: AppColors.series2, points: delay),
          ],
        ),
        ChartPanel(
          title: 'Packet loss (%)',
          height: 70,
          minYMax: 5,
          yFormat: (v) => v == v.roundToDouble() ? '${v.round()}%' : '${v.toStringAsFixed(1)}%',
          series: [ChartSeries(label: 'Loss', color: AppColors.bad, points: loss, style: SeriesStyle.columns)],
        ),
      ],
      tooltipTitle: (t) => formatBin(t - bin / 2, data.binSeconds),
      tooltipLines: (t) {
        final s = byTime[t]?.stats;
        if (s == null) return const [];
        final score = s.score;
        return [
          TooltipLine('Score${score == null ? '' : ' · ${score.grade.label}'}',
              score == null ? '--' : '${score.value}', color: AppColors.accent),
          TooltipLine(
              'Ping${s.udp.rttMin == null ? '' : ' (${s.udp.rttMin!.round()}–${s.udp.rttMax!.round()})'}',
              formatMs(s.udp.avgRtt),
              color: AppColors.series1),
          TooltipLine('Real delay', formatMs(s.http.avgRtt), color: AppColors.series2),
          TooltipLine('Jitter', formatMs(s.jitter), key: TooltipKey.none),
          TooltipLine('Voice call MOS', formatMos(s.call(CallKind.voice)?.mos), key: TooltipKey.none),
          TooltipLine('Video call MOS', formatMos(s.call(CallKind.video)?.mos), key: TooltipKey.none),
          TooltipLine('Packet loss', formatPercent(s.lossPercent), color: AppColors.bad, key: TooltipKey.box),
          TooltipLine('Uptime', formatPercent(s.uptimePercent), key: TooltipKey.none),
        ];
      },
    );
  }
}

/// The table twin of the history chart.
class _HistoryTable extends StatelessWidget {
  const _HistoryTable(this.data);
  final QualityDashboard data;

  @override
  Widget build(BuildContext context) {
    final rows = data.bins.reversed.toList();
    TextStyle head = AppText.overline(AppColors.text3);
    TextStyle cell = AppText.mono(11.5, FontWeight.w500, AppColors.text);
    Widget r(List<String> values, TextStyle style, {bool first = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: first ? null : const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text(values[0], style: style, overflow: TextOverflow.ellipsis)),
              for (final v in values.skip(1))
                Expanded(flex: 2, child: Text(v, style: style, textAlign: TextAlign.right)),
            ],
          ),
        );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView(
        shrinkWrap: true,
        children: [
          r(['TIME', 'SCORE', 'PING', 'JITTER', 'LOSS', 'VOICE', 'VIDEO', 'DELAY'], head, first: true),
          for (final b in rows)
            r([
              formatBin(b.start, data.binSeconds),
              '${b.stats.score?.value ?? '--'}',
              formatMs(b.stats.latency),
              formatMs(b.stats.jitter),
              formatPercent(b.stats.lossPercent),
              formatMos(b.stats.call(CallKind.voice)?.mos),
              formatMos(b.stats.call(CallKind.video)?.mos),
              formatMs(b.stats.http.avgRtt),
            ], cell),
        ],
      ),
    );
  }
}

// ───────────────────────────── overview tile ─────────────────────────────

class QualitySummaryCard extends StatelessWidget {
  const QualitySummaryCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityLive>(
      stream: bloc.quality.live,
      builder: (context, snapshot) {
        final live = snapshot.data;
        final s = live?.recent;
        final score = s?.score;
        return AppCard(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.network_check, size: 17, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text('Network quality', style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                  const Spacer(),
                  GradePill(score),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(score == null ? '--' : '${score.value}',
                      style: AppText.ui(30, FontWeight.w700, AppColors.text)),
                  const SizedBox(width: 6),
                  Text('/ 100', style: AppText.ui(15, FontWeight.w500, AppColors.text3)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                live == null || !live.running
                    ? 'Monitoring paused'
                    : 'Ping ${formatMs(s?.latency)} · loss ${formatPercent(s?.lossPercent)} · '
                        'calls ${formatMos(s?.call(CallKind.voice)?.mos)} MOS',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(11, FontWeight.w400, AppColors.text3),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────────── misc ─────────────────────────────

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.text3),
      );
}

/// Neutral information banner.
class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.icon = Icons.info_outline, this.action});
  final String text;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0x05FFFFFF),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.text3),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text, style: AppText.ui(11.5, FontWeight.w400, AppColors.text3, height: 1.45)),
          ),
          if (action != null) ...[const SizedBox(width: 10), action!],
        ],
      ),
    );
  }
}

/// Reloads a dashboard when its section is opened; the blocs keep it fresh
/// on their own timers while it stays on screen.
class ReloadOnMount extends StatefulWidget {
  const ReloadOnMount({super.key, required this.onReload, required this.child});
  final Future<void> Function() onReload;
  final Widget child;

  @override
  State<ReloadOnMount> createState() => _ReloadOnMountState();
}

class _ReloadOnMountState extends State<ReloadOnMount> {
  @override
  void initState() {
    super.initState();
    widget.onReload();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
