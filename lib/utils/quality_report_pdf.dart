/// The network-quality report as a designed, printable PDF (A4): a summary
/// with key findings, history charts and comparison tables.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/call_quality.dart';
import '../data/quality.dart';
import '../data/quality_report.dart';
import '../ui/charts.dart' show niceCeil, timeTicks;
import '../ui/format.dart';
import 'quality_export.dart';

/// Fonts embedded in the report: the app's Space Grotesk as static weights
/// (a PDF can't use the variable font's weight axis) and JetBrains Mono.
class ReportFonts {
  ReportFonts._(this.regular, this.medium, this.bold, this.mono, this._uiRunes, this._monoRunes);

  static const regularAsset = 'assets/fonts/pdf/SpaceGrotesk-Regular.ttf';
  static const mediumAsset = 'assets/fonts/pdf/SpaceGrotesk-Medium.ttf';
  static const boldAsset = 'assets/fonts/pdf/SpaceGrotesk-Bold.ttf';
  static const monoAsset = 'assets/fonts/JetBrainsMono.ttf';

  /// [read] loads an asset, e.g. `rootBundle.load`.
  static Future<ReportFonts> load(Future<ByteData> Function(String asset) read) async {
    final regular = await read(regularAsset);
    final mono = await read(monoAsset);
    return ReportFonts._(
      pw.Font.ttf(regular),
      pw.Font.ttf(await read(mediumAsset)),
      pw.Font.ttf(await read(boldAsset)),
      pw.Font.ttf(mono),
      _runes(regular),
      _runes(mono),
    );
  }

  final pw.Font regular;
  final pw.Font medium;
  final pw.Font bold;
  final pw.Font mono;
  final Set<int> _uiRunes;
  final Set<int> _monoRunes;

  static Set<int> _runes(ByteData data) => TtfParser(data).charToGlyphIndexMap.keys.toSet();

  /// Whether every character of [text] has a glyph (e.g. not a Persian label).
  bool canWrite(String text) => text.runes.every((c) => c < 0x21 || _uiRunes.contains(c));

  /// [text] with characters the font lacks replaced by "?".
  String clean(String text, {bool mono = false}) {
    final runes = mono ? _monoRunes : _uiRunes;
    return String.fromCharCodes(text.runes.map((c) => c < 0x21 || runes.contains(c) ? c : 0x3F));
  }
}

/// Builds the PDF. Server labels the fonts can't draw fall back to the
/// location, so names never print as boxes.
Future<Uint8List> buildQualityReportPdf(QualityReport report, ReportFonts fonts) =>
    _ReportPdf(report.keepingLabels(fonts.canWrite), fonts).build();

/// Print palette: light surface, the app's teal as the brand colour, the
/// chart pair validated on white (blue/orange light steps) and status colours
/// that always come with a label.
class _C {
  static const ink = PdfColor.fromInt(0xFF0F1720);
  static const ink2 = PdfColor.fromInt(0xFF4A5565);
  static const ink3 = PdfColor.fromInt(0xFF8A94A3);
  static const line = PdfColor.fromInt(0xFFDCE1E7);
  static const grid = PdfColor.fromInt(0xFFECEFF3);
  static const baseline = PdfColor.fromInt(0xFFC3CAD3);
  static const panel = PdfColor.fromInt(0xFFF5F7F9);

  static const accent = PdfColor.fromInt(0xFF1F8F86);
  static const accentBright = PdfColor.fromInt(0xFF33D6C6);
  static const accentSoft = PdfColor.fromInt(0xFFE6F7F5);
  static const series1 = PdfColor.fromInt(0xFF2A78D6);
  static const series2 = PdfColor.fromInt(0xFFEB6834);

  static const good = PdfColor.fromInt(0xFF0CA30C);
  static const warn = PdfColor.fromInt(0xFFF0A30A);
  static const bad = PdfColor.fromInt(0xFFD03B3B);
  static const goodSoft = PdfColor.fromInt(0xFFE7F6E7);
  static const warnSoft = PdfColor.fromInt(0xFFFDF3DC);
  static const badSoft = PdfColor.fromInt(0xFFFBEAEA);

  // The cover band repeats the app's dark theme.
  static const night = PdfColor.fromInt(0xFF0B0F14);
  static const nightCard = PdfColor.fromInt(0xFF141D28);
  static const nightText = PdfColor.fromInt(0xFFE7EEF5);
  static const nightText2 = PdfColor.fromInt(0xFF94A3B2);
  static const nightText3 = PdfColor.fromInt(0xFF5D6B7A);
}

PdfColor _toneColor(FindingTone tone) => switch (tone) {
      FindingTone.good => _C.good,
      FindingTone.warn => _C.warn,
      FindingTone.bad => _C.bad,
      FindingTone.info => _C.ink3,
    };

PdfColor _toneSoft(FindingTone tone) => switch (tone) {
      FindingTone.good => _C.goodSoft,
      FindingTone.warn => _C.warnSoft,
      FindingTone.bad => _C.badSoft,
      FindingTone.info => _C.panel,
    };

/// Material's "shield" icon, the app's brand mark.
const _shieldSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<path fill="#04211E" d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z"/></svg>';

class _ReportPdf {
  _ReportPdf(this.r, this.fonts) : findings = reportFindings(r);

  final QualityReport r;
  final ReportFonts fonts;
  final List<ReportFinding> findings;

  String _t(String text) => fonts.clean(text);
  String _m(String text) => fonts.clean(text, mono: true);

  pw.TextStyle _ui(double size, {PdfColor color = _C.ink, pw.Font? font, double? letterSpacing, double? lineSpacing}) =>
      pw.TextStyle(
        font: font ?? fonts.regular,
        fontSize: size,
        color: color,
        letterSpacing: letterSpacing,
        lineSpacing: lineSpacing,
      );

  pw.TextStyle _mono(double size, {PdfColor color = _C.ink}) =>
      pw.TextStyle(font: fonts.mono, fontSize: size, color: color);

  pw.Widget _overline(String text, {PdfColor color = _C.ink3, double size = 6.3}) =>
      pw.Text(text.toUpperCase(), style: _ui(size, font: fonts.medium, color: color, letterSpacing: 0.7));

  pw.Widget _dot(PdfColor color, {double size = 5}) => pw.Container(
        width: size,
        height: size,
        decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle),
      );

  pw.Widget _brandMark(double size) => pw.Container(
        width: size,
        height: size,
        padding: pw.EdgeInsets.all(size * 0.2),
        decoration: pw.BoxDecoration(
          gradient: const pw.LinearGradient(
            begin: pw.Alignment.topLeft,
            end: pw.Alignment.bottomRight,
            colors: [_C.accentBright, PdfColor.fromInt(0xFF1F8F86)],
          ),
          borderRadius: pw.BorderRadius.circular(size * 0.32),
        ),
        child: pw.SvgImage(svg: _shieldSvg),
      );

  Future<Uint8List> build() {
    final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold);
    final doc = pw.Document(
      title: 'IRNet network quality report',
      author: 'IRNet',
      creator: r.appVersion.isEmpty ? 'IRNet' : 'IRNet ${r.appVersion}',
      subject: _t('${reportRangeLabel(r)}, ${reportPeriod(r)}'),
      keywords: 'network quality, VPN, ping, jitter, packet loss, MOS',
      theme: theme,
    );
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 24),
        theme: theme,
      ),
      header: _pageHeader,
      footer: _pageFooter,
      build: (context) => [
        _cover(),
        pw.SizedBox(height: 12),
        _summary(),
        pw.SizedBox(height: 16),
        ..._findingsSection(),
        ..._chartsSection(),
        ..._serversSection(),
        ..._worstSection(),
        ..._callTestsSection(),
        ..._methodSection(),
      ],
    ));
    return doc.save();
  }

  // ─────────────────────────── page chrome ───────────────────────────

  pw.Widget _pageHeader(pw.Context context) {
    if (context.pageNumber == 1) return pw.SizedBox();
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _C.line, width: 0.6))),
      child: pw.Row(children: [
        _brandMark(12),
        pw.SizedBox(width: 6),
        pw.Text('Network quality report', style: _ui(8, font: fonts.medium, color: _C.ink2)),
        pw.Spacer(),
        pw.Text(_t('${reportRangeLabel(r)} · ${reportPeriod(r)}'), style: _ui(7, color: _C.ink3)),
      ]),
    );
  }

  pw.Widget _pageFooter(pw.Context context) {
    final by = r.appVersion.isEmpty ? 'IRNet' : 'IRNet ${r.appVersion}';
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(children: [
        pw.Text(_t('Generated by $by${r.platform.isEmpty ? '' : ' on ${r.platform}'} · ${reportDateTime(r.generatedAt)}'),
            style: _ui(6.5, color: _C.ink3)),
        pw.Spacer(),
        pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: _ui(6.5, color: _C.ink3)),
      ]),
    );
  }

  pw.Widget _section(String title, {String? note}) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Container(
              width: 3,
              height: 11,
              decoration: pw.BoxDecoration(color: _C.accent, borderRadius: pw.BorderRadius.circular(1.5)),
            ),
            pw.SizedBox(width: 6),
            pw.Text(title, style: _ui(11, font: fonts.bold)),
            pw.Spacer(),
            if (note != null) pw.Text(_t(note), style: _ui(7, color: _C.ink3)),
          ],
        ),
      );

  // ─────────────────────────── cover ───────────────────────────

  pw.Widget _cover() {
    final current = r.current;
    final generated = [
      if (r.appVersion.isNotEmpty) 'IRNet ${r.appVersion}' else 'IRNet',
      if (r.platform.isNotEmpty) r.platform,
    ].join(' · ');
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: pw.BoxDecoration(color: _C.night, borderRadius: pw.BorderRadius.circular(12)),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(children: [
                  _brandMark(20),
                  pw.SizedBox(width: 7),
                  pw.Text('IRNet', style: _ui(11, font: fonts.bold, color: _C.nightText)),
                ]),
                pw.SizedBox(height: 14),
                pw.Text('Network quality report', style: _ui(22, font: fonts.bold, color: _C.nightText)),
                pw.SizedBox(height: 5),
                pw.Text(_t('${reportRangeLabel(r)} · ${reportPeriod(r)}'), style: _ui(8.5, color: _C.nightText2)),
                pw.SizedBox(height: 2),
                pw.Text(_t('Scope: ${reportScope(r)}'), style: _ui(8.5, color: _C.nightText2)),
              ],
            ),
          ),
          pw.SizedBox(width: 14),
          pw.Container(
            width: 168,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: _C.nightCard, borderRadius: pw.BorderRadius.circular(8)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _overline('Connected through', color: _C.nightText3),
                pw.SizedBox(height: 3),
                if (current == null)
                  pw.Text('Unknown', style: _ui(9.5, font: fonts.medium, color: _C.nightText))
                else ...[
                  pw.Text(_t(serverTitle(current)),
                      style: _ui(9.5, font: fonts.medium, color: _C.nightText), maxLines: 1),
                  pw.SizedBox(height: 1.5),
                  pw.Text(_m(current.ip), style: _mono(7.5, color: _C.accentBright)),
                  if (current.isp != null) pw.Text(_t(current.isp!), style: _ui(7, color: _C.nightText2), maxLines: 1),
                ],
                pw.SizedBox(height: 8),
                _overline('Generated', color: _C.nightText3),
                pw.SizedBox(height: 3),
                pw.Text(reportDateTime(r.generatedAt), style: _ui(8, color: _C.nightText)),
                pw.Text(_t(generated), style: _ui(7, color: _C.nightText2)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── score + KPIs ───────────────────────────

  pw.Widget _summary() {
    final s = r.total;
    final score = s.score;
    final voice = s.call(CallKind.voice);
    final video = s.call(CallKind.video);
    final via = identical(s.primary, s.http) ? 'HTTPS' : 'UDP';
    final lost = s.primary.sent - s.primary.received;
    String average(String series, double? value) => value == null ? 'no data' : '$series · average';
    final selected = r.selected;
    final servers = selected == null ? r.rows.length : selected.ips.length;
    final noun = selected != null ? 'IP' : (r.grouping == QualityGrouping.server ? 'server' : 'location');
    final tiles = [
      _kpi('Ping', formatMs(s.latency), toneOfRating(QualityMetric.ping.rate(s.latency)), average(via, s.latency)),
      _kpi('Jitter', formatMs(s.jitter), toneOfRating(QualityMetric.jitter.rate(s.jitter)), average(via, s.jitter)),
      _kpi('Packet loss', formatPercent(s.lossPercent), toneOfRating(QualityMetric.loss.rate(s.lossPercent)),
          s.primary.sent == 0 ? 'no probes' : '$lost of ${s.primary.sent} lost'),
      _kpi('Real delay', formatMs(s.http.avgRtt), toneOfRating(QualityMetric.delay.rate(s.http.avgRtt)),
          average('HTTPS', s.http.avgRtt)),
      _kpi('Uptime', formatPercent(s.uptimePercent, digits: 2),
          toneOfRating(QualityMetric.uptime.rate(s.uptimePercent)), _outageHint()),
      _kpi('Voice call', voice == null ? '—' : '${formatMosValue(voice.mos)} MOS', toneOfGrade(voice?.grade),
          voice == null ? 'no data' : voice.grade.label),
      _kpi('Video call', video == null ? '—' : '${formatMosValue(video.mos)} MOS', toneOfGrade(video?.grade),
          video == null ? 'no data' : video.grade.label),
      _kpi('Monitored', formatDuration(r.monitored), FindingTone.info, '$servers $noun${servers == 1 ? '' : 's'}'),
    ];
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _scoreCard(score),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Column(children: [
            pw.Row(children: _spaced(tiles.sublist(0, 4))),
            pw.SizedBox(height: 8),
            pw.Row(children: _spaced(tiles.sublist(4))),
          ]),
        ),
      ],
    );
  }

  String _outageHint() {
    final n = r.outages.length;
    if (r.total.ticks == 0) return 'no data';
    return n == 0 ? 'no outages' : (n == 1 ? '1 outage' : '$n outages');
  }

  List<pw.Widget> _spaced(List<pw.Widget> tiles) => [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) pw.SizedBox(width: 8),
          pw.Expanded(child: tiles[i]),
        ],
      ];

  pw.Widget _kpi(String label, String value, FindingTone tone, String hint) => pw.Container(
        height: 56,
        padding: const pw.EdgeInsets.fromLTRB(8, 7, 8, 7),
        decoration: pw.BoxDecoration(color: _C.panel, borderRadius: pw.BorderRadius.circular(7)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _overline(label),
            pw.SizedBox(height: 4),
            pw.Text(value, style: _mono(12.5)),
            pw.Spacer(),
            pw.Row(children: [
              if (tone != FindingTone.info) ...[_dot(_toneColor(tone), size: 4.5), pw.SizedBox(width: 3)],
              pw.Expanded(child: pw.Text(_t(hint), style: _ui(6.5, color: _C.ink3), maxLines: 1)),
            ]),
          ],
        ),
      );

  pw.Widget _scoreCard(QualityScore? score) {
    final tone = toneOfGrade(score?.grade);
    return pw.Container(
      width: 140,
      height: 120,
      padding: const pw.EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: pw.BoxDecoration(
        color: _C.panel,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: _C.line, width: 0.6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _overline('Quality score'),
          pw.SizedBox(height: 2),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(score == null ? '—' : '${score.value}', style: _ui(34, font: fonts.bold)),
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 3, bottom: 7),
                child: pw.Text('/100', style: _ui(9, color: _C.ink3)),
              ),
            ],
          ),
          _pill(score?.grade.label ?? 'No data', tone),
          pw.Spacer(),
          _scoreScale(score?.value),
          pw.SizedBox(height: 3),
          pw.Row(children: [
            for (final (label, flex) in const [('Bad', 40), ('Poor', 20), ('Fair', 15), ('Good', 15), ('Exc.', 10)])
              pw.Expanded(flex: flex, child: pw.Text(label, style: _ui(5, color: _C.ink3))),
          ]),
        ],
      ),
    );
  }

  pw.Widget _pill(String label, FindingTone tone) => pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(5, 2.5, 6, 2.5),
        decoration: pw.BoxDecoration(color: _toneSoft(tone), borderRadius: pw.BorderRadius.circular(8)),
        child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          _dot(_toneColor(tone), size: 4.5),
          pw.SizedBox(width: 3.5),
          pw.Text(label, style: _ui(7.5, font: fonts.medium)),
        ]),
      );

  /// A 0–100 track split at the grade limits, filled up to the score.
  pw.Widget _scoreScale(int? value) => pw.CustomPaint(
        size: const PdfPoint(118, 6),
        painter: (canvas, size) {
          const limits = [40, 60, 75, 90];
          final w = size.x;
          canvas
            ..setFillColor(_C.line)
            ..drawRRect(0, 1.5, w, 3, 1.5, 1.5)
            ..fillPath();
          if (value != null && value > 0) {
            canvas
              ..setFillColor(_toneColor(toneOfGrade(QualityScore.gradeOf(value))))
              ..drawRRect(0, 1.5, w * value / 100, 3, 1.5, 1.5)
              ..fillPath();
          }
          canvas.setFillColor(_C.panel);
          for (final l in limits) {
            canvas
              ..drawRect(w * l / 100 - 0.5, 0, 1, 6)
              ..fillPath();
          }
        },
      );

  // ─────────────────────────── findings ───────────────────────────

  /// A section title kept on the same page as what follows it (a plain
  /// Column could be split between them).
  pw.Widget _titled(String title, pw.Widget child, {String? note}) => pw.Inseparable(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [_section(title, note: note), child],
        ),
      );

  List<pw.Widget> _findingsSection() => [
        _section('Key findings'),
        pw.Container(
          padding: const pw.EdgeInsets.fromLTRB(11, 9, 11, 4),
          decoration: pw.BoxDecoration(
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border.all(color: _C.line, width: 0.6),
          ),
          child: pw.Column(
            children: [
              for (final f in findings)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 5),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Padding(padding: const pw.EdgeInsets.only(top: 2.6), child: _dot(_toneColor(f.tone))),
                      pw.SizedBox(width: 7),
                      pw.Expanded(child: pw.Text(_t(f.text), style: _ui(8.3, lineSpacing: 1.5))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        pw.SizedBox(height: 16),
      ];

  // ─────────────────────────── charts ───────────────────────────

  List<pw.Widget> _chartsSection() {
    final bins = r.bins;
    final title = r.selected == null ? 'Quality over time' : _t('Quality over time · ${r.titleOf(r.selected!)}');
    final note = 'Each point covers ${_spanWords(r.binSeconds)}';
    if (bins.isEmpty) {
      return [_section(title), _empty('No measurements in this period.'), pw.SizedBox(height: 16)];
    }
    final starts = [for (final b in bins) b.start];
    List<double?> of(double? Function(QualityStats s) f) => [for (final b in bins) f(b.stats)];
    _TimeChart chart(List<_Panel> panels) => _TimeChart(
          starts: starts,
          binSeconds: r.binSeconds,
          from: r.from.toDouble(),
          to: r.to.toDouble(),
          panels: panels,
          fonts: fonts,
        );
    String percent(double v) => v == v.roundToDouble() ? '${v.round()}%' : '${v.toStringAsFixed(1)}%';
    return [
      _titled(title, note: note, chart([
        _Panel('Quality score (0–100)', [
          _Series('Score', _C.accent, of((s) => s.score?.value.toDouble()), style: _Style.area),
        ], height: 74, yMax: 100),
        _Panel('Calls (MOS, 1–5)', [
          _Series('Voice', _C.series1, of((s) => s.call(CallKind.voice)?.mos)),
          _Series('Video', _C.series2, of((s) => s.call(CallKind.video)?.mos)),
        ], height: 54, yMin: 1, yMax: 5),
      ])),
      pw.SizedBox(height: 12),
      chart([
        _Panel('Latency (ms) · band = min–max ping', [
          _Series('Ping (UDP)', _C.series1, of((s) => s.udp.avgRtt),
              lo: of((s) => s.udp.rttMin), hi: of((s) => s.udp.rttMax)),
          _Series('Real delay (HTTPS)', _C.series2, of((s) => s.http.avgRtt)),
        ], height: 84, minYMax: 100),
        _Panel('Packet loss (%)', [
          _Series('Loss', _C.bad, of((s) => s.lossPercent), style: _Style.columns),
        ], height: 46, minYMax: 5, format: percent),
      ]),
      pw.SizedBox(height: 18),
    ];
  }

  /// "10 minutes", "1 hour", "2 days".
  static String _spanWords(int seconds) {
    String unit(int n, String name) => n == 1 ? '1 $name' : '$n ${name}s';
    if (seconds % 86400 == 0) return unit(seconds ~/ 86400, 'day');
    if (seconds % 3600 == 0) return unit(seconds ~/ 3600, 'hour');
    return unit(seconds ~/ 60, 'minute');
  }

  pw.Widget _empty(String text) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 18),
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(color: _C.panel, borderRadius: pw.BorderRadius.circular(8)),
        child: pw.Text(text, style: _ui(8, color: _C.ink3)),
      );

  // ─────────────────────────── tables ───────────────────────────

  pw.Widget _table({
    required List<String> headers,
    required List<List<pw.Widget>> rows,
    required List<double> flex,
    Set<int> left = const {0},
    Set<int> highlighted = const {},
  }) {
    pw.Alignment align(int i) => left.contains(i) ? pw.Alignment.centerLeft : pw.Alignment.centerRight;
    return pw.Table(
      columnWidths: {for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i])},
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _C.line, width: 0.8))),
          children: [
            for (var i = 0; i < headers.length; i++)
              pw.Container(
                alignment: align(i),
                padding: const pw.EdgeInsets.fromLTRB(4, 0, 4, 5),
                child: _overline(headers[i], size: 5.8),
              ),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          pw.TableRow(
            verticalAlignment: pw.TableCellVerticalAlignment.middle,
            decoration: pw.BoxDecoration(
              color: highlighted.contains(i) ? _C.accentSoft : null,
              border: const pw.Border(bottom: pw.BorderSide(color: _C.grid, width: 0.6)),
            ),
            children: [
              for (var j = 0; j < rows[i].length; j++)
                pw.Container(
                  alignment: align(j),
                  padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4.5),
                  child: rows[i][j],
                ),
            ],
          ),
      ],
    );
  }

  pw.Widget _num(String value, {FindingTone? tone}) => pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          if (tone != null && tone != FindingTone.info) ...[_dot(_toneColor(tone), size: 4), pw.SizedBox(width: 3)],
          pw.Text(value, style: _mono(7.3)),
        ],
      );

  pw.Widget _mos(CallQuality? q) => q == null ? _num('—') : _num(formatMosValue(q.mos), tone: toneOfGrade(q.grade));

  pw.Widget _scoreCell(QualityScore? score) {
    if (score == null) return pw.Text('—', style: _mono(7.3, color: _C.ink3));
    final color = _toneColor(toneOfGrade(score.grade));
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(children: [
          pw.Text('${score.value}', style: _mono(7.6)),
          pw.SizedBox(width: 3),
          pw.Text(score.grade.label, style: _ui(6.3, color: _C.ink3)),
        ]),
        pw.SizedBox(height: 2.5),
        pw.Row(children: [
          if (score.value > 0) pw.Expanded(flex: score.value, child: pw.Container(height: 2.5, color: color)),
          if (score.value < 100) pw.Expanded(flex: 100 - score.value, child: pw.Container(height: 2.5, color: _C.grid)),
        ]),
      ],
    );
  }

  List<pw.Widget> _statCells(QualityStats s) => [
        _scoreCell(s.score),
        _num(formatMs(s.latency), tone: toneOfRating(QualityMetric.ping.rate(s.latency))),
        _num(formatMs(s.jitter), tone: toneOfRating(QualityMetric.jitter.rate(s.jitter))),
        _num(formatPercent(s.lossPercent), tone: toneOfRating(QualityMetric.loss.rate(s.lossPercent))),
        _num(formatMs(s.http.avgRtt)),
        _num(formatPercent(s.uptimePercent), tone: toneOfRating(QualityMetric.uptime.rate(s.uptimePercent))),
        _mos(s.call(CallKind.voice)),
        _mos(s.call(CallKind.video)),
      ];

  static const _statHeaders = ['Score', 'Ping', 'Jitter', 'Loss', 'Real delay', 'Uptime', 'Voice', 'Video'];
  static const _statFlex = [1.55, 0.95, 0.9, 0.9, 1.25, 0.95, 0.75, 0.75];

  List<pw.Widget> _serversSection() {
    if (r.rows.isEmpty) return const [];
    final byIp = r.grouping == QualityGrouping.server;
    final rows = r.rows;
    final table = _table(
        headers: [byIp ? 'Server' : 'Location', ..._statHeaders, 'Time'],
        flex: [2.9, ..._statFlex, 0.95],
        highlighted: {
          for (var i = 0; i < rows.length; i++)
            if (r.isCurrent(rows[i])) i,
        },
        rows: [
          for (final row in rows)
            [
              _serverCell(row),
              ..._statCells(row.stats),
              _num(formatDuration(row.monitored)),
            ],
        ],
      );
    return [
      ..._keepShort(byIp ? 'Servers compared' : 'Locations compared', table, rows.length,
          note: 'Best score first · tinted row = current exit'),
      pw.SizedBox(height: 18),
    ];
  }

  /// Title and table on one page when the table is short; long tables flow
  /// over pages (repeating their header row).
  List<pw.Widget> _keepShort(String title, pw.Widget table, int rows, {String? note}) =>
      rows <= 15 ? [_titled(title, table, note: note)] : [_section(title, note: note), table];

  pw.Widget _serverCell(ServerQuality row) {
    final info = row.info;
    final ips = row.ips.length == 1 ? row.ips.single : '${row.ips.length} IPs';
    final title = r.titleOf(row);
    final detail = [
      if (title != ips) ips,
      if (info.label != null && r.grouping == QualityGrouping.server && info.place.isNotEmpty) info.place,
      if (info.isp != null) info.isp!,
    ].join(' · ');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(children: [
          if (info.countryCode != null) ...[
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 2.5, vertical: 0.8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _C.line, width: 0.6),
                borderRadius: pw.BorderRadius.circular(2),
              ),
              child: pw.Text(_m(info.countryCode!), style: _mono(5.6, color: _C.ink2)),
            ),
            pw.SizedBox(width: 4),
          ],
          pw.Expanded(
            child: pw.Text(_t(_short(title, 60)), style: _ui(7.8, font: fonts.medium), maxLines: 2),
          ),
        ]),
        if (detail.isNotEmpty) ...[
          pw.SizedBox(height: 1.5),
          pw.Text(_t(_short(detail, 90)), style: _ui(6.2, color: _C.ink3, lineSpacing: 1), maxLines: 2),
        ],
      ],
    );
  }

  static String _short(String text, int max) => text.length <= max ? text : '${text.substring(0, max - 1).trimRight()}…';

  List<pw.Widget> _worstSection() {
    if (r.bins.isEmpty) return const [];
    final worst = r.worstPeriods();
    return [
      _titled(
        'Weakest periods',
        note: 'Time buckets that scored below Good, worst first',
        worst.isEmpty
            ? _empty('No period scored below Good.')
            : _table(
                headers: const ['Period', ..._statHeaders],
                flex: const [2.6, ..._statFlex],
                rows: [
                  for (final b in worst)
                    [
                      pw.Text(binLabel(b.start, r.binSeconds), style: _ui(7.4, font: fonts.medium)),
                      ..._statCells(b.stats),
                    ],
                ],
              ),
      ),
      pw.SizedBox(height: 18),
    ];
  }

  List<pw.Widget> _callTestsSection() {
    final tests = r.callTests;
    if (tests.isEmpty) return const [];
    final shown = tests.take(25).toList();
    final table = _table(
        headers: const ['Time', 'Server', 'Voice', 'Video', 'Loss', 'Late', 'Jitter', 'Ping', 'Down / up', 'Video tier'],
        flex: const [1.45, 2.3, 0.75, 0.75, 0.85, 0.8, 0.9, 0.9, 1.6, 1.3],
        left: const {0, 1},
        rows: [
          for (final t in shown)
            [
              pw.Text(formatDayClock(t.at.millisecondsSinceEpoch ~/ 1000), style: _ui(7.2)),
              pw.Text(_t(_short(r.serverName(t.server), 28)), style: _ui(7.2, font: fonts.medium), maxLines: 1),
              if (t.udpBlocked) ...[_num('—'), _num('—')] else ...[_mos(t.voice), _mos(t.video)],
              _num(formatPercent(t.lossPercent), tone: toneOfRating(QualityMetric.loss.rate(t.lossPercent))),
              _num(formatPercent(t.latePercent)),
              _num(formatMs(t.jitter), tone: toneOfRating(QualityMetric.jitter.rate(t.jitter))),
              _num(formatMs(t.rttMedian), tone: toneOfRating(QualityMetric.ping.rate(t.rttMedian))),
              _num(t.downMbps == null ? '—' : '${_mbps(t.downMbps!)} / ${_mbps(t.upMbps!)}'),
              pw.Text(t.tier?.label ?? '—', style: _ui(7.2)),
            ],
        ],
      );
    return [
      ..._keepShort('Call tests', table, shown.length, note: '400 voice packets every 20 ms, then a bandwidth check'),
      if (tests.length > 25)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('${tests.length - 25} older tests are in the CSV export.', style: _ui(6.5, color: _C.ink3)),
        ),
      pw.SizedBox(height: 18),
    ];
  }

  static String _mbps(double v) => v < 10 ? v.toStringAsFixed(1) : '${v.round()}';

  // ─────────────────────────── methodology ───────────────────────────

  List<pw.Widget> _methodSection() {
    final every = r.probeInterval == null ? 'Every few seconds' : 'Every ${r.probeInterval!.inSeconds} s';
    final entries = [
      ('Ping, jitter, loss',
          '$every IRNet sends a STUN request over UDP to a public STUN server (Cloudflare, Google or Twilio). '
              'A reply missing after 2 s counts as lost. Jitter is the average change between consecutive round trips.'),
      ('Real delay',
          'Every 5th probe, an HTTPS request on a kept-alive connection through the system proxy: '
              'what web and other TCP apps wait for, as VPN clients measure it.'),
      ('Uptime',
          'Share of probe intervals with any connectivity. An interval is down when the UDP probe is lost '
              'and HTTPS fails too. Sleep is not monitored, and reconnecting after waking only counts when it '
              'takes over 2 minutes.'),
      ('Quality score',
          'The ITU-T G.107 E-model R-factor from latency, jitter and loss, scaled to 0–100. '
              'Excellent ≥ 90, Good ≥ 75, Fair ≥ 60, Poor ≥ 40, Bad below.'),
      ('Call quality (MOS)',
          'Mean opinion score from 1 to 4.5, estimated with the E-model from the same probes. Video tolerates '
              'less loss than voice. Good ≥ 4.03, Fair ≥ 3.6, Poor ≥ 3.1.'),
      ('Call test',
          '400 voice-sized UDP packets every 20 ms, like a real call, then a 2.5 MB download and 1.5 MB upload. '
              'Video needs ~0.6 Mbps (SD), 1.2 (HD) or 3 (Full HD) each way.'),
      ('Servers',
          'Measurements are grouped by public exit IP (the VPN server or ISP), located with ip-api.com.'),
      ('Status dots',
          'Good / fair limits: ping 120 / 250 ms, jitter 20 / 50 ms, loss 1 / 5 %, real delay 300 / 800 ms, '
              'uptime 99.5 / 98 %. Beyond them: poor.'),
    ];
    pw.Widget entry((String, String) e) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 7),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(e.$1, style: _ui(7.4, font: fonts.bold)),
              pw.SizedBox(height: 1.5),
              pw.Text(e.$2, style: _ui(7, color: _C.ink2, lineSpacing: 1.4)),
            ],
          ),
        );
    final half = (entries.length / 2).ceil();
    return [
      _titled(
        'How this was measured',
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: pw.Column(children: [for (final e in entries.take(half)) entry(e)])),
            pw.SizedBox(width: 16),
            pw.Expanded(child: pw.Column(children: [for (final e in entries.skip(half)) entry(e)])),
          ],
        ),
      ),
    ];
  }
}

// ─────────────────────────── time chart ───────────────────────────

enum _Style { line, area, columns }

class _Series {
  const _Series(this.label, this.color, this.values, {this.style = _Style.line, this.lo, this.hi});

  final String label;
  final PdfColor color;

  /// One value per bin (null = no data).
  final List<double?> values;
  final _Style style;

  /// Optional min–max band drawn behind the line.
  final List<double?>? lo;
  final List<double?>? hi;
}

class _Panel {
  const _Panel(this.title, this.series, {required this.height, this.yMin = 0, this.yMax, this.minYMax = 0, this.format});

  final String title;
  final List<_Series> series;
  final double height;
  final double yMin;

  /// Fixed top of the scale; otherwise a round number above the data.
  final double? yMax;
  final double minYMax;
  final String Function(double value)? format;
}

/// Stacked panels over one shared time axis, drawn like the app's history
/// chart: hairline grid, 1.3 pt lines broken at gaps, legend for ≥ 2 series.
class _TimeChart extends pw.Widget {
  _TimeChart({
    required this.starts,
    required this.binSeconds,
    required this.from,
    required this.to,
    required this.panels,
    required this.fonts,
  });

  final List<int> starts;
  final int binSeconds;
  final double from;
  final double to;
  final List<_Panel> panels;
  final ReportFonts fonts;

  static const _axis = 30.0;
  static const _header = 14.0;
  static const _gap = 9.0;
  static const _xAxis = 12.0;

  double get _height => panels.fold<double>(0, (h, p) => h + _header + p.height + _gap) - _gap + _xAxis;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, constraints.maxWidth, _height);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final canvas = context.canvas;
    final regular = fonts.regular.getFont(context);
    final medium = fonts.medium.getFont(context);
    final mono = fonts.mono.getFont(context);
    final b = box!;
    final left = b.left + _axis;
    final width = b.right - left;
    final span = math.max(1.0, to - from);
    double x(double t) => left + (t - from) / span * width;

    var top = b.top;
    var bottom = top;
    for (final panel in panels) {
      _text(canvas, medium, 7.3, panel.title, b.left, top - 8.5, _C.ink2);
      if (panel.series.length > 1) _legend(canvas, regular, panel, b.right, top - 8.5);
      top -= _header;
      bottom = top - panel.height;
      _plot(canvas, mono, panel, left, width, top, bottom, x);
      top = bottom - _gap;
    }

    // Shared time axis under the last panel.
    final offset = DateTime.now().timeZoneOffset.inSeconds;
    final ticks = timeTicks(from, to, width, offset);
    canvas.setStrokeColor(_C.baseline);
    canvas.setLineWidth(0.5);
    for (final t in ticks.times) {
      final tx = x(t);
      canvas
        ..drawLine(tx, bottom, tx, bottom - 2.5)
        ..strokePath();
      final local = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
      final midnight = local.hour == 0 && local.minute == 0;
      final label = ticks.step >= 86400 || (midnight && span > 86400) ? formatDay(t) : formatClock(t);
      final w = _width(regular, 6.3, label);
      _text(canvas, regular, 6.3, label, (tx - w / 2).clamp(left, b.right - w), bottom - 9.5, _C.ink3);
    }
  }

  void _plot(
    PdfGraphics canvas,
    PdfFont mono,
    _Panel panel,
    double left,
    double width,
    double top,
    double bottom,
    double Function(double t) x,
  ) {
    final height = top - bottom;
    var dataMax = panel.minYMax;
    for (final s in panel.series) {
      for (final v in [...s.values, ...?s.hi]) {
        if (v != null && v > dataMax) dataMax = v;
      }
    }
    final yMin = panel.yMin;
    final yMax = panel.yMax ?? niceCeil(dataMax);
    double y(double v) => bottom + (v - yMin) / (yMax - yMin) * height;
    final format = panel.format ?? (v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

    // Grid: baseline, middle and top, labelled on the left.
    for (final v in [yMin, (yMin + yMax) / 2, yMax]) {
      canvas
        ..setStrokeColor(v == yMin ? _C.baseline : _C.grid)
        ..setLineWidth(v == yMin ? 0.6 : 0.5)
        ..drawLine(left, y(v), left + width, y(v))
        ..strokePath();
      final label = format(v);
      _text(canvas, mono, 5.8, label, left - 4 - _width(mono, 5.8, label), y(v) - 2, _C.ink3);
    }

    canvas
      ..saveContext()
      ..drawRect(left, bottom, width, height + 1)
      ..clipPath();
    for (final s in panel.series) {
      if (s.style == _Style.columns) {
        for (var i = 0; i < starts.length; i++) {
          final v = s.values[i];
          if (v == null || v <= 0) continue;
          final x0 = x(starts[i].toDouble());
          final x1 = x(math.min(starts[i] + binSeconds.toDouble(), to));
          final gap = math.min(1.2, (x1 - x0) * 0.25);
          canvas
            ..setFillColor(s.color)
            ..drawRect(x0 + gap / 2, bottom, math.max(0.6, x1 - x0 - gap), math.max(0.6, y(v) - bottom))
            ..fillPath();
        }
        continue;
      }
      for (final run in _runs(s.values)) {
        final xs = [for (final i in run) x(_mid(i))];
        if (s.lo != null && s.hi != null) {
          final band = [
            for (final i in run)
              if (s.lo![i] != null && s.hi![i] != null) i,
          ];
          if (band.length > 1) {
            canvas
              ..saveContext()
              ..setGraphicState(const PdfGraphicState(opacity: 0.14))
              ..setFillColor(s.color)
              ..moveTo(x(_mid(band.first)), y(s.hi![band.first]!));
            for (final i in band.skip(1)) {
              canvas.lineTo(x(_mid(i)), y(s.hi![i]!));
            }
            for (final i in band.reversed) {
              canvas.lineTo(x(_mid(i)), y(s.lo![i]!));
            }
            canvas
              ..closePath()
              ..fillPath()
              ..restoreContext();
          }
        }
        if (run.length == 1) {
          canvas
            ..setFillColor(s.color)
            ..drawEllipse(xs.single, y(s.values[run.single]!), 1.8, 1.8)
            ..fillPath();
          continue;
        }
        if (s.style == _Style.area) {
          canvas
            ..saveContext()
            ..setGraphicState(const PdfGraphicState(opacity: 0.16))
            ..setFillColor(_C.accentBright)
            ..moveTo(xs.first, y(yMin));
          for (var k = 0; k < run.length; k++) {
            canvas.lineTo(xs[k], y(s.values[run[k]]!));
          }
          canvas
            ..lineTo(xs.last, y(yMin))
            ..closePath()
            ..fillPath()
            ..restoreContext();
        }
        canvas
          ..setStrokeColor(s.color)
          ..setLineWidth(1.3)
          ..setLineJoin(PdfLineJoin.round)
          ..setLineCap(PdfLineCap.round)
          ..moveTo(xs.first, y(s.values[run.first]!));
        for (var k = 1; k < run.length; k++) {
          canvas.lineTo(xs[k], y(s.values[run[k]]!));
        }
        canvas.strokePath();
      }
    }
    canvas.restoreContext();
  }

  /// Where bin [i] is plotted: the middle of the part of it that has
  /// happened (the current bin ends in the future).
  double _mid(int i) => (starts[i] + math.min(starts[i] + binSeconds.toDouble(), to)) / 2;

  /// Index runs of consecutive bins with values (a missing bin breaks a line).
  List<List<int>> _runs(List<double?> values) {
    final runs = <List<int>>[];
    List<int>? current;
    for (var i = 0; i < values.length; i++) {
      final contiguous = i > 0 && starts[i] - starts[i - 1] <= binSeconds;
      if (values[i] == null) {
        current = null;
        continue;
      }
      if (current == null || !contiguous) {
        current = [];
        runs.add(current);
      }
      current.add(i);
    }
    return runs;
  }

  void _legend(PdfGraphics canvas, PdfFont font, _Panel panel, double right, double baseline) {
    const size = 6.5;
    var x = right;
    for (final s in panel.series.reversed) {
      final w = _width(font, size, s.label);
      x -= w;
      _text(canvas, font, size, s.label, x, baseline, _C.ink2);
      x -= 3 + 9;
      canvas
        ..setStrokeColor(s.color)
        ..setLineWidth(1.6)
        ..setLineCap(PdfLineCap.round)
        ..drawLine(x, baseline + 2.2, x + 9, baseline + 2.2)
        ..strokePath();
      x -= 10;
    }
  }

  static double _width(PdfFont font, double size, String text) => font.stringMetrics(text).advanceWidth * size;

  static void _text(PdfGraphics canvas, PdfFont font, double size, String text, double x, double y, PdfColor color) {
    canvas
      ..setFillColor(color)
      ..drawString(font, size, text, x, y);
  }
}
