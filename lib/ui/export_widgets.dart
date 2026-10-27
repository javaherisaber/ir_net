import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/data/quality_report.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/app_info.dart';
import 'package:ir_net/utils/file_delivery.dart';
import 'package:ir_net/utils/quality_export.dart';
import 'package:ir_net/utils/quality_report_pdf.dart';

import 'components.dart';
import 'format.dart';
import 'theme.dart';

/// "macOS", "Windows", …
String platformName() {
  if (kIsWeb) return 'Web';
  return switch (Platform.operatingSystem) {
    'macos' => 'macOS',
    'ios' => 'iOS',
    'android' => 'Android',
    'windows' => 'Windows',
    'linux' => 'Linux',
    final other => other,
  };
}

enum ExportFormat { pdf, zip }

/// Builds the network-quality exports and hands them to [FileDelivery].
class QualityExporter {
  QualityExporter({
    this.delivery = const FileDelivery(),
    Future<QualityReport?> Function()? load,
    Future<ReportFonts> Function()? fonts,
  })  : _load = load ?? (() => bloc.quality.report(appVersion: AppInfo.version, platform: platformName())),
        _fonts = fonts ?? _bundledFonts;

  /// Makes the exporter the Export button uses; tests swap in fakes.
  @visibleForTesting
  static QualityExporter Function() create = QualityExporter.new;

  final FileDelivery delivery;
  final Future<QualityReport?> Function() _load;
  final Future<ReportFonts> Function() _fonts;

  static Future<ReportFonts>? _cachedFonts;
  static Future<ReportFonts> _bundledFonts() => _cachedFonts ??= ReportFonts.load(rootBundle.load);

  Future<QualityReport?> load() => _load();

  Future<DeliveredFile> export(QualityReport report, ExportFormat format) async {
    switch (format) {
      case ExportFormat.pdf:
        final bytes = await buildQualityReportPdf(report, await _fonts());
        return delivery.deliver(reportFileName(report, 'pdf'), bytes,
            mimeType: 'application/pdf', subject: 'IRNet network quality report');
      case ExportFormat.zip:
        return delivery.deliver(reportFileName(report, 'zip'), buildReportZip(report),
            mimeType: 'application/zip', subject: 'IRNet network quality data');
    }
  }
}

/// The "Export" button of the quality filter row.
class QualityExportButton extends StatelessWidget {
  const QualityExportButton({super.key, this.exporter});
  final QualityExporter? exporter;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Export',
      icon: Icons.ios_share_rounded,
      kind: AppButtonKind.ghostAccent,
      height: 37,
      onPressed: () => showQualityExportDialog(context, exporter: exporter),
    );
  }
}

Future<void> showQualityExportDialog(BuildContext context, {QualityExporter? exporter}) => showDialog<void>(
      context: context,
      builder: (_) => QualityExportDialog(exporter: exporter ?? QualityExporter.create()),
    );

/// Lets the user save or share the current quality view as a PDF report or
/// as raw CSV data, or copy a text summary.
class QualityExportDialog extends StatefulWidget {
  const QualityExportDialog({super.key, required this.exporter});
  final QualityExporter exporter;

  @override
  State<QualityExportDialog> createState() => _QualityExportDialogState();
}

class _QualityExportDialogState extends State<QualityExportDialog> {
  QualityReport? _report;
  bool _loading = true;
  ExportFormat? _busy;
  DeliveredFile? _saved;
  String? _error;
  bool _copied = false;
  Timer? _copiedTimer;

  bool get _shares => widget.exporter.delivery.sharesFiles;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final report = await widget.exporter.load();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
        if (report == null) _error = 'Quality history is not available on this device.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read the quality history: $e';
      });
    }
  }

  Future<void> _export(ExportFormat format) async {
    final report = _report;
    if (report == null || _busy != null) return;
    setState(() {
      _busy = format;
      _error = null;
      _saved = null;
    });
    try {
      final file = await widget.exporter.export(report, format);
      if (!mounted) return;
      if (file.shared) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _saved = file);
    } catch (e) {
      if (mounted) setState(() => _error = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _copySummary() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: reportSummary(report)));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open it: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final ready = report != null && !report.isEmpty;
    return Dialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconTile(icon: Icons.ios_share_rounded, size: 34, iconSize: 17, radius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Export network quality', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
                  ),
                  IconActionButton(icon: Icons.close_rounded, onPressed: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.accent),
                    ),
                  ),
                )
              else if (report != null) ...[
                _ScopeSummary(report),
                const SizedBox(height: 14),
                if (report.isEmpty) ...[
                  const _Note(
                    icon: Icons.info_outline,
                    color: AppColors.text3,
                    text: 'Nothing was measured in this range yet. Keep monitoring on, or pick a longer range.',
                  ),
                  const SizedBox(height: 12),
                ],
                _ExportOption(
                  icon: Icons.picture_as_pdf_outlined,
                  title: 'PDF report',
                  description: 'Key findings, charts and the server comparison, ready to read, print or forward.',
                  action: _shares ? 'Share PDF' : 'Save PDF',
                  primary: true,
                  busy: _busy == ExportFormat.pdf,
                  onPressed: ready && _busy == null ? () => _export(ExportFormat.pdf) : null,
                ),
                const SizedBox(height: 10),
                _ExportOption(
                  icon: Icons.table_chart_outlined,
                  title: 'Raw data (CSV)',
                  description: 'Every minute per server, the history, call tests and recent probes, in one ZIP.',
                  action: _shares ? 'Share ZIP' : 'Save ZIP',
                  busy: _busy == ExportFormat.zip,
                  onPressed: ready && _busy == null ? () => _export(ExportFormat.zip) : null,
                ),
              ],
              if (_saved != null) ...[
                const SizedBox(height: 12),
                _SavedFile(
                  file: _saved!,
                  onOpen: () => _run(() => widget.exporter.delivery.open(_saved!.path)),
                  onReveal: () => _run(() => widget.exporter.delivery.reveal(_saved!.path)),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                _Note(icon: Icons.error_outline, color: AppColors.bad, text: _error!),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: ready ? _copySummary : null,
                    icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded, size: 15),
                    label: Text(_copied ? 'Copied' : 'Copy text summary'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      textStyle: AppText.ui(12.5, FontWeight.w600, AppColors.accent),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.text2,
                      textStyle: AppText.ui(12.5, FontWeight.w600, AppColors.text2),
                    ),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the export covers: range, scope and how much data.
class _ScopeSummary extends StatelessWidget {
  const _ScopeSummary(this.report);
  final QualityReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final servers = r.rows.length;
    final noun = r.grouping == QualityGrouping.server ? 'server' : 'location';
    final facts = [
      '$servers $noun${servers == 1 ? '' : 's'}',
      '${formatDuration(r.monitored)} monitored',
      '${r.callTests.length} call test${r.callTests.length == 1 ? '' : 's'}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${reportRangeLabel(r)} · ${reportScope(r)}',
            style: AppText.ui(13, FontWeight.w600, AppColors.text, height: 1.35)),
        const SizedBox(height: 3),
        Text(reportPeriod(r), style: AppText.ui(11.5, FontWeight.w400, AppColors.text2, height: 1.35)),
        const SizedBox(height: 6),
        Text(facts.join(' · '), style: AppText.mono(11, FontWeight.w500, AppColors.text3)),
      ],
    );
  }
}

class _ExportOption extends StatelessWidget {
  const _ExportOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onPressed,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 112,
      child: busy
          ? const SizedBox(
              height: 38,
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.accent),
                ),
              ),
            )
          : AppButton(
              label: action,
              kind: primary ? AppButtonKind.primary : AppButtonKind.outline,
              height: 38,
              expand: true,
              onPressed: onPressed,
            ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.ui(13.5, FontWeight.w600, AppColors.text)),
        const SizedBox(height: 3),
        Text(description, style: AppText.ui(11.5, FontWeight.w400, AppColors.text2, height: 1.4)),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final tile = IconTile(icon: icon, size: 36, iconSize: 18, radius: 10);
        if (c.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                tile,
                const SizedBox(width: 12),
                Expanded(child: text),
              ]),
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: button),
            ],
          );
        }
        return Row(
          children: [
            tile,
            const SizedBox(width: 12),
            Expanded(child: text),
            const SizedBox(width: 12),
            button,
          ],
        );
      }),
    );
  }
}

class _SavedFile extends StatelessWidget {
  const _SavedFile({required this.file, required this.onOpen, required this.onReveal});
  final DeliveredFile file;
  final VoidCallback onOpen;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.goodSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0x404ADE80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.good),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Saved ${file.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.ui(12.5, FontWeight.w600, AppColors.text)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(file.folder,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.mono(10.5, FontWeight.w500, AppColors.text3)),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            // IntrinsicWidth: a Wrap hands buttons its full width otherwise.
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IntrinsicWidth(
                  child: AppButton(
                    label: 'Open',
                    icon: Icons.open_in_new_rounded,
                    kind: AppButtonKind.outline,
                    height: 34,
                    onPressed: onOpen,
                  ),
                ),
                IntrinsicWidth(
                  child: AppButton(
                    label: 'Show in folder',
                    icon: Icons.folder_open_rounded,
                    kind: AppButtonKind.outline,
                    height: 34,
                    onPressed: onReveal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: AppText.ui(11.5, FontWeight.w400, color, height: 1.45))),
      ],
    );
  }
}
