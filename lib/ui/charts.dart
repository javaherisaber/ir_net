import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'format.dart';
import 'theme.dart';

/// How a series is drawn.
enum SeriesStyle {
  /// 2px line; points with a null value (or too far apart) break it.
  line,

  /// Line with a faint wash down to the baseline.
  area,

  /// Columns centred on each point (stacked when the panel says so).
  columns,

  /// Event markers (e.g. lost probes): a dot on the baseline plus a faint
  /// vertical rule. Only the point time matters.
  marks,
}

class ChartPoint {
  const ChartPoint(this.t, this.y, {this.lo, this.hi});

  /// Seconds since epoch (x).
  final double t;
  final double? y;

  /// Optional min / max around [y], drawn as a band.
  final double? lo;
  final double? hi;
}

class ChartSeries {
  const ChartSeries({
    required this.label,
    required this.color,
    required this.points,
    this.style = SeriesStyle.line,
    this.band = false,
  });

  final String label;
  final Color color;
  final List<ChartPoint> points;
  final SeriesStyle style;

  /// Draw the lo–hi range of the points as a wash behind the line.
  final bool band;
}

class ChartPanel {
  const ChartPanel({
    required this.title,
    required this.series,
    this.height = 110,
    this.yMin = 0,
    this.yMax,
    this.minYMax = 1,
    this.yFormat = _plainNumber,
    this.stacked = false,
    this.showLegend,
    this.niceMax = niceCeil,
  });

  final String title;
  final List<ChartSeries> series;

  /// Plot height (the x-axis band is added below the last panel).
  final double height;

  /// Bottom of the y scale (e.g. 1 for MOS).
  final double yMin;

  /// Fixed top of the y scale; otherwise a round number above the data.
  final double? yMax;
  final double minYMax;
  final String Function(double value) yFormat;
  final bool stacked;

  /// Defaults to "two or more series".
  final bool? showLegend;

  /// Rounds the data maximum up to the top of the scale.
  final double Function(double value) niceMax;
}

String _plainNumber(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

enum TooltipKey { line, box, dot, none }

class TooltipLine {
  const TooltipLine(this.label, this.value, {this.color, this.key = TooltipKey.line});

  final String label;
  final String value;
  final Color? color;
  final TooltipKey key;
}

/// Stacked panels sharing one time axis, with a crosshair that snaps to the
/// nearest data point and a tooltip listing every series at that time.
class TimeChart extends StatefulWidget {
  const TimeChart({
    super.key,
    required this.from,
    required this.to,
    required this.step,
    required this.panels,
    required this.tooltipTitle,
    required this.tooltipLines,
    this.dimmed = false,
  });

  final double from;
  final double to;

  /// Expected spacing between points in seconds: column width and the
  /// distance after which a line is broken (gap in the data).
  final double step;
  final List<ChartPanel> panels;
  final String Function(double t) tooltipTitle;
  final List<TooltipLine> Function(double t) tooltipLines;

  /// Holds the previous render at reduced opacity while data reloads.
  final bool dimmed;

  @override
  State<TimeChart> createState() => _TimeChartState();
}

class _TimeChartState extends State<TimeChart> {
  double? _hoverT;
  Offset? _pointer;
  List<double> _times = const [];

  static const _tooltipWidth = 196.0;

  @override
  void initState() {
    super.initState();
    _collectTimes();
  }

  @override
  void didUpdateWidget(TimeChart old) {
    super.didUpdateWidget(old);
    _collectTimes();
    if (_hoverT != null && (_hoverT! < widget.from || _hoverT! > widget.to)) _hoverT = null;
  }

  void _collectTimes() {
    final set = <double>{};
    for (final panel in widget.panels) {
      for (final s in panel.series) {
        for (final p in s.points) {
          if (p.t >= widget.from && p.t <= widget.to) set.add(p.t);
        }
      }
    }
    _times = set.toList()..sort();
  }

  void _hover(Offset position, double width) {
    if (_times.isEmpty) return;
    final plotWidth = width - PanelPainter.leftPad - PanelPainter.rightPad;
    if (plotWidth <= 0) return;
    final fraction = ((position.dx - PanelPainter.leftPad) / plotWidth).clamp(0.0, 1.0);
    final t = widget.from + fraction * (widget.to - widget.from);
    // Binary search for the nearest point time.
    var lo = 0, hi = _times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = _times[lo];
    if (lo > 0 && (t - _times[lo - 1]).abs() < (best - t).abs()) best = _times[lo - 1];
    setState(() {
      _hoverT = best;
      _pointer = position;
    });
  }

  void _clear() => setState(() => _hoverT = null);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final panels = <Widget>[];
      for (var i = 0; i < widget.panels.length; i++) {
        final panel = widget.panels[i];
        final last = i == widget.panels.length - 1;
        if (i > 0) panels.add(const SizedBox(height: 14));
        panels.add(_PanelHeader(panel));
        panels.add(const SizedBox(height: 8));
        panels.add(CustomPaint(
          size: Size(width, panel.height + (last ? PanelPainter.axisBand : 2)),
          painter: PanelPainter(
            panel: panel,
            from: widget.from,
            to: widget.to,
            step: widget.step,
            showAxis: last,
            hoverT: _hoverT,
          ),
        ));
      }
      return MouseRegion(
        onHover: (e) => _hover(e.localPosition, width),
        onExit: (_) => _clear(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _hover(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _hover(d.localPosition, width),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: widget.dimmed ? 0.45 : 1,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: panels),
              ),
              if (_hoverT != null && _pointer != null) _tooltip(width),
            ],
          ),
        ),
      );
    });
  }

  Widget _tooltip(double width) {
    final t = _hoverT!;
    final plotWidth = width - PanelPainter.leftPad - PanelPainter.rightPad;
    final x = PanelPainter.leftPad + (t - widget.from) / (widget.to - widget.from) * plotWidth;
    var left = x + 14;
    if (left + _tooltipWidth > width) left = x - 14 - _tooltipWidth;
    left = left.clamp(0.0, math.max(0.0, width - _tooltipWidth));
    final lines = widget.tooltipLines(t);
    return Positioned(
      left: left,
      top: 22,
      width: _tooltipWidth,
      child: IgnorePointer(
        child: ChartTooltip(title: widget.tooltipTitle(t), lines: lines),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader(this.panel);
  final ChartPanel panel;

  @override
  Widget build(BuildContext context) {
    final legend = panel.showLegend ?? panel.series.length > 1;
    // Title left, legend right; on narrow cards the legend wraps below.
    return Padding(
      padding: const EdgeInsets.only(left: PanelPainter.leftPad, right: PanelPainter.rightPad),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 6,
        children: [
          Text(panel.title, style: AppText.ui(12, FontWeight.w600, AppColors.text2)),
          if (legend)
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [for (final s in panel.series) LegendItem(s.label, s.color, style: s.style)],
            ),
        ],
      ),
    );
  }
}

/// Legend entry: the key mirrors the mark (line for lines, box for columns,
/// dot for markers); the label stays in text ink.
class LegendItem extends StatelessWidget {
  const LegendItem(this.label, this.color, {super.key, this.style = SeriesStyle.line});

  final String label;
  final Color color;
  final SeriesStyle style;

  @override
  Widget build(BuildContext context) {
    final key = switch (style) {
      SeriesStyle.columns => Container(
          width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      SeriesStyle.marks => Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      _ => Container(width: 14, height: 2.5, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        key,
        const SizedBox(width: 6),
        Text(label, style: AppText.ui(11, FontWeight.w500, AppColors.text2)),
      ],
    );
  }
}

/// Value-first tooltip: the number is the strong element, the series name
/// follows in muted ink, keyed by a short stroke of the series colour.
class ChartTooltip extends StatelessWidget {
  const ChartTooltip({super.key, required this.title, required this.lines});

  final String title;
  final List<TooltipLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: AppColors.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: AppText.ui(11, FontWeight.w500, AppColors.text3)),
          const SizedBox(height: 6),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  SizedBox(width: 16, child: _key(l)),
                  Text(l.value, style: AppText.mono(12.5, FontWeight.w600, AppColors.text)),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(l.label,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _key(TooltipLine l) {
    final color = l.color;
    if (color == null || l.key == TooltipKey.none) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: switch (l.key) {
        TooltipKey.box => Container(
            width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        TooltipKey.dot => Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        _ => Container(width: 10, height: 2.5, color: color),
      },
    );
  }
}

/// Paints one panel: hairline grid with y labels, the series, the shared
/// x axis (last panel only) and the crosshair.
class PanelPainter extends CustomPainter {
  PanelPainter({
    required this.panel,
    required this.from,
    required this.to,
    required this.step,
    required this.showAxis,
    this.hoverT,
  });

  final ChartPanel panel;
  final double from;
  final double to;
  final double step;
  final bool showAxis;
  final double? hoverT;

  static const leftPad = 46.0;
  static const rightPad = 12.0;
  static const topPad = 4.0;
  static const axisBand = 22.0;
  static const surface = AppColors.card;

  Rect plotRect(Size size) =>
      Rect.fromLTRB(leftPad, topPad, size.width - rightPad, size.height - (showAxis ? axisBand : 2));

  double get _span => math.max(1, to - from);

  double yMaxFor() {
    if (panel.yMax != null) return panel.yMax!;
    var maxValue = 0.0;
    if (panel.stacked) {
      final sums = <double, double>{};
      for (final s in panel.series) {
        if (s.style != SeriesStyle.columns) continue;
        for (final p in s.points) {
          if (p.y != null) sums[p.t] = (sums[p.t] ?? 0) + p.y!;
        }
      }
      for (final v in sums.values) {
        maxValue = math.max(maxValue, v);
      }
    }
    for (final s in panel.series) {
      if (s.style == SeriesStyle.marks) continue;
      for (final p in s.points) {
        if (p.t < from || p.t > to) continue;
        maxValue = math.max(maxValue, (s.band ? p.hi : null) ?? p.y ?? 0);
      }
    }
    return panel.niceMax(math.max(maxValue * 1.08, panel.minYMax));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotRect(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    final yMax = yMaxFor();
    final yMin = panel.yMin;
    final range = math.max(1e-9, yMax - yMin);
    double x(double t) => plot.left + (t - from) / _span * plot.width;
    double y(double v) => plot.bottom - ((v - yMin) / range).clamp(0.0, 1.0) * plot.height;

    _grid(canvas, plot, yMin, yMax);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(plot.left - 6, 0, plot.right + 6, size.height));
    for (final s in panel.series) {
      if (s.band) _band(canvas, s, x, y);
    }
    _columns(canvas, plot, x, y);
    for (final s in panel.series) {
      if (s.style == SeriesStyle.area) _line(canvas, plot, s, x, y, fill: true);
    }
    for (final s in panel.series) {
      if (s.style == SeriesStyle.line || s.style == SeriesStyle.area) _line(canvas, plot, s, x, y);
    }
    for (final s in panel.series) {
      if (s.style == SeriesStyle.marks) _marks(canvas, plot, s, x);
    }
    if (hoverT != null) _crosshair(canvas, plot, x, y);
    canvas.restore();

    if (showAxis) _xAxis(canvas, plot);
  }

  void _grid(Canvas canvas, Rect plot, double yMin, double yMax) {
    final grid = Paint()
      ..color = AppColors.grid
      ..strokeWidth = 1;
    final base = Paint()
      ..color = AppColors.baseline
      ..strokeWidth = 1;
    for (final f in const [0.0, 0.5, 1.0]) {
      final yy = (plot.bottom - f * plot.height).roundToDouble() + 0.5;
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), f == 0 ? base : grid);
      _label(canvas, panel.yFormat(yMin + (yMax - yMin) * f), Offset(plot.left - 8, yy), align: _Align.rightMiddle);
    }
  }

  /// Contiguous runs of points with values, split where data is missing.
  List<List<ChartPoint>> _runs(ChartSeries s, {bool needBand = false}) {
    final sorted = [...s.points]..sort((a, b) => a.t.compareTo(b.t));
    final runs = <List<ChartPoint>>[];
    var current = <ChartPoint>[];
    ChartPoint? prev;
    for (final p in sorted) {
      final ok = p.y != null && (!needBand || (p.lo != null && p.hi != null));
      final gap = prev != null && p.t - prev.t > step * 2.5;
      if (!ok || gap) {
        if (current.isNotEmpty) runs.add(current);
        current = <ChartPoint>[];
      }
      if (ok) current.add(p);
      prev = ok ? p : null;
    }
    if (current.isNotEmpty) runs.add(current);
    return runs;
  }

  void _line(Canvas canvas, Rect plot, ChartSeries s, double Function(double) x, double Function(double) y,
      {bool fill = false}) {
    final stroke = Paint()
      ..color = s.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final wash = Paint()..color = s.color.withValues(alpha: 0.10);
    for (final run in _runs(s)) {
      if (run.length == 1) {
        if (!fill) canvas.drawCircle(Offset(x(run.first.t), y(run.first.y!)), 2.5, Paint()..color = s.color);
        continue;
      }
      final path = Path()..moveTo(x(run.first.t), y(run.first.y!));
      for (final p in run.skip(1)) {
        path.lineTo(x(p.t), y(p.y!));
      }
      if (fill) {
        path
          ..lineTo(x(run.last.t), plot.bottom)
          ..lineTo(x(run.first.t), plot.bottom)
          ..close();
        canvas.drawPath(path, wash);
      } else {
        canvas.drawPath(path, stroke);
      }
    }
  }

  void _band(Canvas canvas, ChartSeries s, double Function(double) x, double Function(double) y) {
    final paint = Paint()..color = s.color.withValues(alpha: 0.14);
    for (final run in _runs(s, needBand: true)) {
      if (run.length < 2) continue;
      final path = Path()..moveTo(x(run.first.t), y(run.first.hi!));
      for (final p in run.skip(1)) {
        path.lineTo(x(p.t), y(p.hi!));
      }
      for (final p in run.reversed) {
        path.lineTo(x(p.t), y(p.lo!));
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  void _columns(Canvas canvas, Rect plot, double Function(double) x, double Function(double) y) {
    final columns = panel.series.where((s) => s.style == SeriesStyle.columns).toList();
    if (columns.isEmpty) return;
    final slot = plot.width * step / _span;
    final width = (slot - 2).clamp(1.5, 24.0);
    final bases = <double, double>{};
    for (var i = 0; i < columns.length; i++) {
      final s = columns[i];
      final paint = Paint()..color = s.color;
      for (final p in s.points) {
        final v = p.y;
        if (v == null || v <= 0 || p.t < from || p.t > to) continue;
        final base = panel.stacked ? (bases[p.t] ?? 0) : 0.0;
        if (panel.stacked) bases[p.t] = base + v;
        final cx = x(p.t);
        var bottom = y(base);
        final top = y(base + v);
        // 2px surface gap between stacked segments.
        if (panel.stacked && base > 0) bottom -= 2;
        if (bottom - top < 0.5) continue;
        final isTop = !panel.stacked || !_hasAbove(columns, i, p.t);
        final rect = Rect.fromLTRB(cx - width / 2, top, cx + width / 2, bottom);
        final radius = (isTop && width >= 6 && rect.height >= 4) ? const Radius.circular(4) : Radius.zero;
        canvas.drawRRect(
          RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
          paint,
        );
      }
    }
  }

  bool _hasAbove(List<ChartSeries> columns, int index, double t) {
    for (final s in columns.skip(index + 1)) {
      for (final p in s.points) {
        if (p.t == t && (p.y ?? 0) > 0) return true;
      }
    }
    return false;
  }

  void _marks(Canvas canvas, Rect plot, ChartSeries s, double Function(double) x) {
    final rule = Paint()
      ..color = s.color.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    final dot = Paint()..color = s.color;
    final ring = Paint()..color = surface;
    for (final p in s.points) {
      if (p.y == null || p.t < from || p.t > to) continue;
      final cx = x(p.t).roundToDouble() + 0.5;
      canvas.drawLine(Offset(cx, plot.top), Offset(cx, plot.bottom), rule);
      final c = Offset(cx, plot.bottom - 1);
      canvas.drawCircle(c, 5.5, ring);
      canvas.drawCircle(c, 3.5, dot);
    }
  }

  void _crosshair(Canvas canvas, Rect plot, double Function(double) x, double Function(double) y) {
    final t = hoverT!;
    final cx = x(t).roundToDouble() + 0.5;
    canvas.drawLine(
      Offset(cx, plot.top),
      Offset(cx, plot.bottom),
      Paint()
        ..color = const Color(0x59FFFFFF)
        ..strokeWidth = 1,
    );
    for (final s in panel.series) {
      if (s.style != SeriesStyle.line && s.style != SeriesStyle.area) continue;
      for (final p in s.points) {
        if (p.t != t || p.y == null) continue;
        final c = Offset(x(p.t), y(p.y!));
        canvas.drawCircle(c, 6, Paint()..color = surface);
        canvas.drawCircle(c, 4, Paint()..color = s.color);
      }
    }
  }

  void _xAxis(Canvas canvas, Rect plot) {
    final offset = DateTime.now().timeZoneOffset.inSeconds;
    final ticks = timeTicks(from, to, plot.width, offset);
    final labelDays = ticks.step >= 86400;
    for (final t in ticks.times) {
      final xx = plot.left + (t - from) / _span * plot.width;
      final midnight = ((t + offset) % 86400) == 0;
      final text = labelDays || (midnight && _span > 86400) ? formatDay(t) : formatClock(t);
      _label(canvas, text, Offset(xx, plot.bottom + 6), align: _Align.topCenter, minX: plot.left - leftPad + 2, maxX: plot.right + rightPad - 2);
    }
  }

  void _label(Canvas canvas, String text, Offset at,
      {required _Align align, double? minX, double? maxX}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: AppText.mono(10, FontWeight.w500, AppColors.text3)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = switch (align) {
      _Align.rightMiddle => at.dx - painter.width,
      _Align.topCenter => at.dx - painter.width / 2,
    };
    if (minX != null) dx = math.max(dx, minX);
    if (maxX != null) dx = math.min(dx, maxX - painter.width);
    final dy = align == _Align.rightMiddle ? at.dy - painter.height / 2 : at.dy;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(PanelPainter old) =>
      old.panel != panel || old.from != from || old.to != to || old.hoverT != hoverT || old.step != step;
}

enum _Align { rightMiddle, topCenter }

const _niceSteps = [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0];

/// Smallest "round" number ≥ [value] (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8 × 10ⁿ),
/// so the top gridline sits close above the data and its half is round too.
double niceCeil(double value) {
  if (value <= 0) return 1;
  final exponent = (math.log(value) / math.ln10).floor();
  final base = math.pow(10, exponent).toDouble();
  final f = value / base;
  return _niceSteps.firstWhere((s) => f <= s + 1e-9) * base;
}

/// [niceCeil] in the 1024-based unit the value is displayed in, so a byte
/// axis reads "60 MB", not "57.2 MB".
double niceBytes(double value) {
  var unit = 1.0;
  while (value / unit >= 1024) {
    unit *= 1024;
  }
  return niceCeil(value / unit) * unit;
}

/// Tick times for a time axis, aligned to local time (`offsetSeconds` = UTC
/// offset), at least ~80px apart.
({List<double> times, int step}) timeTicks(double from, double to, double width, int offsetSeconds) {
  // Labels show HH:mm, so ticks are at least a minute apart.
  const steps = [
    60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 2 * 86400, 7 * 86400,
    14 * 86400, 30 * 86400,
  ];
  final span = to - from;
  final maxTicks = math.max(2, (width / 80).floor());
  var step = steps.last;
  for (final s in steps) {
    if (span / s <= maxTicks) {
      step = s;
      break;
    }
  }
  final first = ((from + offsetSeconds) / step).ceil() * step - offsetSeconds;
  return (
    times: [for (var t = first.toDouble(); t <= to; t += step) t],
    step: step,
  );
}
