import 'package:flutter/material.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/usage_bloc.dart';
import 'package:ir_net/utils/app_names.dart';
import 'package:ir_net/utils/ip_tools.dart';

import 'charts.dart';
import 'components.dart';
import 'format.dart';
import 'quality_widgets.dart';
import 'theme.dart';

String dimensionLabel(UsageDimension d) => switch (d) {
      UsageDimension.app => 'Apps',
      UsageDimension.domain => 'Domains',
      UsageDimension.country => 'Countries',
    };

/// Display name for a domain-dimension key.
String domainTitle(String key) {
  if (key == DomainKeys.unknown) return 'Unknown destination';
  if (key == DomainKeys.fakeIp) return 'Hidden by VPN (fake IP)';
  if (key == DomainKeys.cgnat) return 'Carrier-grade NAT / Tailscale';
  if (DomainKeys.isProvider(key)) return key.substring(DomainKeys.providerPrefix.length);
  return key;
}

String countryTitle(String code, Map<String, String> names) =>
    code.isEmpty ? 'Unknown' : (names[code] ?? code);

// ───────────────────────────── filters ─────────────────────────────

class UsageFilterBar extends StatelessWidget {
  const UsageFilterBar({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageFilter>(
      stream: bloc.usage.filter,
      builder: (context, snapshot) {
        final f = snapshot.data ?? const UsageFilter();
        return StreamBuilder<UsageSummary>(
          stream: bloc.usage.view,
          builder: (context, view) {
            final names = view.data?.countryNames ?? const {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedPills<UsageRange>(
                    values: UsageRange.values,
                    selected: f.range,
                    label: (r) => r.label,
                    onSelected: bloc.usage.setRange,
                  ),
                ),
                if (f.filters.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in f.filters.entries)
                        _FilterChip(
                          label: switch (e.key) {
                            UsageDimension.app => 'App: ${e.value}',
                            UsageDimension.domain => 'Domain: ${domainTitle(e.value)}',
                            UsageDimension.country => 'Country: ${countryTitle(e.value, names)}',
                          },
                          onClear: () => bloc.usage.setDimensionFilter(e.key, null),
                        ),
                    ],
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.onClear});
  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onClear,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppText.ui(12, FontWeight.w600, AppColors.accent)),
              const SizedBox(width: 6),
              const Icon(Icons.close, size: 14, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── status ─────────────────────────────

class UsageStatusBanner extends StatefulWidget {
  const UsageStatusBanner({super.key});

  @override
  State<UsageStatusBanner> createState() => _UsageStatusBannerState();
}

class _UsageStatusBannerState extends State<UsageStatusBanner> {
  // Coming back from system settings (e.g. after granting usage access)
  // should pick the change up right away.
  late final _lifecycle = AppLifecycleListener(onResume: bloc.usage.reload);

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageStatus>(
      stream: bloc.usage.status,
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null) return const SizedBox.shrink();
        switch (status.state) {
          case UsageCollectorState.unsupported:
            return _spaced(InfoBanner(status.message ?? 'Not available on this platform.', icon: Icons.block));
          case UsageCollectorState.needsSetup:
            final setup = status.setup;
            return _spaced(InfoBanner(
              setup?.message ?? 'Tracking needs a permission.',
              icon: Icons.lock_open_outlined,
              action: setup?.actionLabel == null
                  ? null
                  : AppButton(
                      label: setup!.actionLabel!,
                      kind: AppButtonKind.ghostAccent,
                      height: 32,
                      onPressed: bloc.usage.requestSetup,
                    ),
            ));
          case UsageCollectorState.failed:
            return _spaced(InfoBanner(
              'Tracking stopped: ${status.message ?? 'unknown error'}',
              icon: Icons.error_outline,
              action: AppButton(
                label: 'Retry',
                kind: AppButtonKind.ghostAccent,
                height: 32,
                onPressed: () async {
                  await bloc.usage.setTracking(false);
                  await bloc.usage.setTracking(true);
                },
              ),
            ));
          case UsageCollectorState.paused:
            return _spaced(InfoBanner(
              'Usage tracking is paused. History is kept.',
              icon: Icons.pause_circle_outline,
              action: AppButton(
                label: 'Resume',
                icon: Icons.play_arrow,
                kind: AppButtonKind.ghostAccent,
                height: 32,
                onPressed: () => bloc.usage.setTracking(true),
              ),
            ));
          case UsageCollectorState.starting:
          case UsageCollectorState.running:
            return const SizedBox.shrink();
        }
      },
    );
  }
}

Widget _spaced(Widget banner) => Padding(padding: const EdgeInsets.only(bottom: 12), child: banner);

class _TrackingPill extends StatelessWidget {
  const _TrackingPill();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageStatus>(
      stream: bloc.usage.status,
      builder: (context, snapshot) {
        final s = snapshot.data;
        final running = s?.state == UsageCollectorState.running;
        return Tooltip(
          message: running
              ? 'Measured with ${s?.source}'
                  '${s?.since == null ? '' : ' since ${formatClock(s!.since!.millisecondsSinceEpoch / 1000)}'}'
              : (s?.message ?? ''),
          child: Pill(
            label: running
                ? 'TRACKING'
                : switch (s?.state) {
                    UsageCollectorState.paused => 'PAUSED',
                    UsageCollectorState.needsSetup => 'NEEDS ACCESS',
                    _ => 'OFF',
                  },
            dotColor: running ? AppColors.good : AppColors.text3,
            textColor: running ? AppColors.accent : AppColors.text3,
            background: running ? const Color(0x1433D6C6) : AppColors.card,
            borderColor: running ? const Color(0x5933D6C6) : AppColors.line,
          ),
        );
      },
    );
  }
}

// ───────────────────────────── totals + timeline ─────────────────────────────

class UsageOverviewCard extends StatelessWidget {
  const UsageOverviewCard({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageSummary>(
      stream: bloc.usage.view,
      builder: (context, snapshot) {
        final view = snapshot.data;
        final (value, unit) = formatBytesParts(view?.total ?? 0);
        return AppCard(
          gradient: AppGradients.card,
          padding: EdgeInsets.all(compact ? 16 : 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.data_usage, size: 17, color: AppColors.accent),
                  const SizedBox(width: 9),
                  Text(view == null ? 'Internet usage' : 'Internet usage · ${view.range.label.toLowerCase()}',
                      style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                  const Spacer(),
                  const _TrackingPill(),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 26,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(view == null ? '--' : value,
                          style: AppText.ui(compact ? 40 : 48, FontWeight.w700, AppColors.text, height: 1)),
                      const SizedBox(width: 6),
                      Text(unit, style: AppText.ui(16, FontWeight.w500, AppColors.text3)),
                    ],
                  ),
                  _figure(Icons.south, 'Download', view == null ? '--' : formatBytes(view.rx), AppColors.series1),
                  _figure(Icons.north, 'Upload', view == null ? '--' : formatBytes(view.tx), AppColors.series2),
                ],
              ),
              const SizedBox(height: 18),
              if (view != null && view.timeline.isNotEmpty)
                _timeline(view)
              else
                Container(
                  height: 120,
                  alignment: Alignment.center,
                  child: Text(view == null ? '' : 'No traffic recorded in this range yet.',
                      style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
                ),
              if (view != null && view.hiddenVpnBytes > 0) ...[
                const SizedBox(height: 14),
                _VpnNote(view),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _figure(IconData icon, String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            Icon(icon, size: 12, color: AppColors.text3),
            const SizedBox(width: 3),
            Text(label.toUpperCase(), style: AppText.overline(AppColors.text3)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: AppText.ui(20, FontWeight.w600, AppColors.text)),
      ],
    );
  }

  Widget _timeline(UsageSummary view) {
    final bin = view.binSeconds.toDouble();
    final byStart = {for (final b in view.timeline) b.start + bin / 2: b};
    // Leading empty bins of "All time" would squash the chart: start at the data.
    final from = view.range == UsageRange.all
        ? (view.timeline.first.start - bin).toDouble()
        : view.from.toDouble();
    return TimeChart(
      from: from,
      to: view.to.toDouble(),
      step: bin,
      panels: [
        ChartPanel(
          title: 'Traffic per ${_binLabel(view.binSeconds)}',
          height: compact ? 100 : 120,
          stacked: true,
          minYMax: 1024,
          niceMax: niceBytes,
          yFormat: (v) => v == 0 ? '0' : formatBytesTick(v),
          series: [
            ChartSeries(
              label: 'Download',
              color: AppColors.series1,
              style: SeriesStyle.columns,
              points: [for (final b in view.timeline) ChartPoint(b.start + bin / 2, b.rx.toDouble())],
            ),
            ChartSeries(
              label: 'Upload',
              color: AppColors.series2,
              style: SeriesStyle.columns,
              points: [for (final b in view.timeline) ChartPoint(b.start + bin / 2, b.tx.toDouble())],
            ),
          ],
        ),
      ],
      tooltipTitle: (t) => formatBin(t - bin / 2, view.binSeconds),
      tooltipLines: (t) {
        final b = byStart[t];
        if (b == null) return const [];
        return [
          TooltipLine('Total', formatBytes(b.total), key: TooltipKey.none),
          TooltipLine('Download', formatBytes(b.rx), color: AppColors.series1, key: TooltipKey.box),
          TooltipLine('Upload', formatBytes(b.tx), color: AppColors.series2, key: TooltipKey.box),
        ];
      },
    );
  }

  static String _binLabel(int seconds) {
    if (seconds % 86400 == 0) return seconds == 86400 ? 'day' : '${seconds ~/ 86400} days';
    if (seconds % 3600 == 0) return seconds == 3600 ? 'hour' : '${seconds ~/ 3600} hours';
    return seconds == 60 ? 'minute' : '${seconds ~/ 60} minutes';
  }
}

class _VpnNote extends StatelessWidget {
  const _VpnNote(this.view);
  final UsageSummary view;

  @override
  Widget build(BuildContext context) {
    final apps = view.hiddenVpnApps.join(', ');
    final text = view.includeVpnTransport
        ? 'Including $apps (${formatBytes(view.hiddenVpnBytes)}): the VPN\'s encrypted copy of '
            'the traffic above, so totals count it twice.'
        : '$apps carried ${formatBytes(view.hiddenVpnBytes)} for the apps above (encrypted VPN '
            'tunnel). It is hidden so traffic isn\'t counted twice.';
    return InfoBanner(
      text,
      icon: Icons.vpn_lock_outlined,
      action: AppButton(
        label: view.includeVpnTransport ? 'Hide' : 'Show',
        kind: AppButtonKind.outline,
        height: 30,
        onPressed: () => bloc.usage.setIncludeVpnTransport(!view.includeVpnTransport),
      ),
    );
  }
}

// ───────────────────────────── breakdown ─────────────────────────────

class UsageBreakdownCard extends StatefulWidget {
  const UsageBreakdownCard({super.key});

  @override
  State<UsageBreakdownCard> createState() => _UsageBreakdownCardState();
}

class _UsageBreakdownCardState extends State<UsageBreakdownCard> {
  UsageDimension _tab = UsageDimension.app;
  bool _all = false;

  static const _collapsed = 10;

  void _drillDown(UsageDimension dimension, String key) {
    bloc.usage.setDimensionFilter(dimension, key);
    // Follow the selection to the next breakdown: app → domains → countries.
    setState(() {
      _all = false;
      _tab = switch (dimension) {
        UsageDimension.app => UsageDimension.domain,
        UsageDimension.domain => UsageDimension.country,
        UsageDimension.country => UsageDimension.app,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageStatus>(
      stream: bloc.usage.status,
      builder: (context, statusSnap) {
        final appsOnly = statusSnap.data?.hasDestinations == false;
        return StreamBuilder<UsageSummary>(
          stream: bloc.usage.view,
          builder: (context, snapshot) => _card(snapshot.data, appsOnly),
        );
      },
    );
  }

  Widget _card(UsageSummary? view, bool appsOnly) {
    final tab = appsOnly ? UsageDimension.app : _tab;
    final entries = view?.entries[tab] ?? const <UsageEntry>[];
    final shown = _all ? entries : entries.take(_collapsed).toList();
    final max = entries.isEmpty ? 1 : entries.first.total;
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: appsOnly
                ? Row(
                    children: [
                      const Icon(Icons.apps, size: 16, color: AppColors.accent),
                      const SizedBox(width: 9),
                      Text('APPS${view == null ? '' : '  ${entries.length}'}',
                          style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6)),
                    ],
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedPills<UsageDimension>(
                      values: UsageDimension.values,
                      selected: tab,
                      label: (d) {
                        final n = view?.entries[d]?.length;
                        return n == null ? dimensionLabel(d) : '${dimensionLabel(d)}  $n';
                      },
                      onSelected: (d) => setState(() {
                        _tab = d;
                        _all = false;
                      }),
                    ),
                  ),
          ),
          Container(height: 1, color: AppColors.line),
          if (view == null)
            const SizedBox(height: 80)
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(22),
              child: Text('Nothing here for this range.', style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
            )
          else ...[
            for (final e in shown)
              _UsageRow(
                dimension: tab,
                entry: e,
                fraction: e.total / max,
                view: view,
                selected: view.filters[tab] == e.key,
                // Drilling into an app's destinations needs destinations.
                onTap: appsOnly ? null : () => _drillDown(tab, e.key),
              ),
            if (entries.length > _collapsed)
              TextButton(
                onPressed: () => setState(() => _all = !_all),
                child: Text(_all ? 'Show top $_collapsed' : 'Show all ${entries.length}',
                    style: AppText.ui(12, FontWeight.w600, AppColors.accent)),
              ),
          ],
          if (appsOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Text(
                'Android reports data per app (including traffic through your VPN), but not where it '
                'went, so domains and countries are not available here.',
                style: AppText.ui(10.5, FontWeight.w400, AppColors.text3, height: 1.45),
              ),
            )
          else if (tab == UsageDimension.domain)
            _domainFootnote(),
        ],
      ),
    );
  }

  Widget _domainFootnote() {
    return StreamBuilder<UsageStatus>(
      stream: bloc.usage.status,
      builder: (context, snapshot) {
        final lookups = snapshot.data?.lookups ?? true;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: Text(
            lookups
                ? 'Domains come from reverse DNS of each address (asked through your DNS resolver), '
                    'falling back to the network owner. Country and owner come from geojs.io over '
                    'HTTPS; only addresses are sent, and never your VPN server\'s.'
                : 'Destination lookups are off in Settings, so addresses are shown as-is.',
            style: AppText.ui(10.5, FontWeight.w400, AppColors.text3, height: 1.45),
          ),
        );
      },
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.dimension,
    required this.entry,
    required this.fraction,
    required this.view,
    required this.selected,
    required this.onTap,
  });

  final UsageDimension dimension;
  final UsageEntry entry;
  final double fraction;
  final UsageSummary view;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle, leading) = _describe();
    return Material(
      color: selected ? AppColors.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
          child: Row(
            children: [
              SizedBox(width: 30, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(13, FontWeight.w600, AppColors.text)),
                        ),
                        const SizedBox(width: 10),
                        Text(formatBytes(entry.total), style: AppText.mono(12.5, FontWeight.w600, AppColors.text)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _Bar(fraction: fraction),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: Text(subtitle,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(10.5, FontWeight.w400, AppColors.text3)),
                        ),
                        Text('↓ ${formatBytes(entry.rx)}  ↑ ${formatBytes(entry.tx)}',
                            style: AppText.mono(10.5, FontWeight.w500, AppColors.text3)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  (String, String, Widget) _describe() {
    final share = view.total == 0 ? '' : '${(entry.total * 100 / view.total).toStringAsFixed(1)}% of total';
    switch (dimension) {
      case UsageDimension.app:
        final vpn = looksLikeVpnApp(entry.key);
        return (entry.key, vpn ? 'VPN client · $share' : share, _Avatar(entry.key, vpn: vpn));
      case UsageDimension.domain:
        final key = entry.key;
        final provider = DomainKeys.isProvider(key)
            ? 'Network owner (no reverse DNS)'
            : (view.providerNames[key] ?? (DomainKeys.isSpecial(key) ? '' : ''));
        final country = entry.topCountry == null ? null : countryTitle(entry.topCountry!, view.countryNames);
        final sub = [provider, country, share].where((s) => s != null && s.isNotEmpty).join(' · ');
        final Widget leading = DomainKeys.isSpecial(key)
            ? const Icon(Icons.help_outline, size: 18, color: AppColors.text3)
            : FlagIcon(entry.topCountry, width: 22);
        return (domainTitle(key), sub, leading);
      case UsageDimension.country:
        return (
          countryTitle(entry.key, view.countryNames),
          entry.key.isEmpty ? 'Not looked up, local VPN address or lookups off · $share' : share,
          FlagIcon(entry.key.isEmpty ? null : entry.key, width: 22),
        );
    }
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        height: 6,
        color: AppColors.grid,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction.clamp(0.01, 1.0),
          child: Container(
            decoration: BoxDecoration(color: AppColors.series1, borderRadius: BorderRadius.circular(3)),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar(this.name, {this.vpn = false});
  final String name;
  final bool vpn;

  @override
  Widget build(BuildContext context) {
    if (vpn) return const IconTile(icon: Icons.vpn_lock, size: 28, iconSize: 15, radius: 8);
    final letter = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppColors.card2, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.line)),
      child: Text(letter, style: AppText.ui(13, FontWeight.w700, AppColors.text2)),
    );
  }
}

// ───────────────────────────── overview tile ─────────────────────────────

class UsageSummaryCard extends StatelessWidget {
  const UsageSummaryCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UsageSummary>(
      stream: bloc.usage.view,
      builder: (context, snapshot) {
        final view = snapshot.data;
        final top = view?.entries[UsageDimension.app]?.firstOrNull;
        final (value, unit) = formatBytesParts(view?.total ?? 0);
        return AppCard(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.data_usage, size: 17, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('Data usage · ${view?.range.label.toLowerCase() ?? 'today'}',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(view == null ? '--' : value, style: AppText.ui(30, FontWeight.w700, AppColors.text)),
                  const SizedBox(width: 6),
                  Text(unit, style: AppText.ui(15, FontWeight.w500, AppColors.text3)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                top == null ? 'No traffic recorded yet' : 'Top app: ${top.key} · ${formatBytes(top.total)}',
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
