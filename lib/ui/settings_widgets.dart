import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'components.dart';
import 'quality_widgets.dart';
import 'theme.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _group('Behaviour', [
          _futureToggle(
            title: 'Auto-login to Kerio',
            subtitle: 'Reconnect to the balance account on launch',
            value: AppSharedPreferences.kerioAutoLogin,
            onChanged: AppSharedPreferences.setKerioAutoLogin,
          ),
          _futureToggle(
            title: 'Show leak detection on tray icon',
            subtitle: 'Reflect leak status in the system tray',
            value: AppSharedPreferences.showLeakInSysTray,
            onChanged: AppSharedPreferences.setShowLeakInSysTray,
          ),
          _launchAtStartup(),
        ]),
        const SizedBox(height: 18),
        _group('Monitoring', [
          _SettingRow(
            title: 'Leak check interval',
            subtitle: 'How often monitored sites are re-tested',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.line2),
              ),
              child: Text('Every 20s', style: AppText.mono(13, FontWeight.w500, AppColors.text)),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        _group('Network quality', [
          _futureToggle(
            title: 'Quality monitoring',
            subtitle: 'Measure ping, jitter and packet loss in the background',
            value: AppSharedPreferences.qualityMonitoring,
            onChanged: bloc.quality.setEnabled,
          ),
          _probeInterval(),
          _clearRow(
            title: 'Clear quality history',
            subtitle: 'Deletes all measurements and server names',
            onConfirm: bloc.quality.clearHistory,
          ),
        ]),
        const SizedBox(height: 18),
        _group('Data usage', [
          if (usageUnsupportedReason() == null)
            _futureToggle(
              title: 'Track usage per app',
              subtitle: 'Attribute traffic to apps, domains and countries',
              value: AppSharedPreferences.usageTracking,
              onChanged: bloc.usage.setTracking,
            )
          else
            _SettingRow(
              title: 'Track usage per app',
              subtitle: usageUnsupportedReason()!,
              trailing: const AppSwitch(value: false, onChanged: null),
            ),
          _futureToggle(
            title: 'Look up destinations',
            subtitle: 'Country & owner from geojs.io (HTTPS), names via reverse DNS. VPN server addresses are never sent',
            value: AppSharedPreferences.usageLookups,
            onChanged: bloc.usage.setLookups,
          ),
          _clearRow(
            title: 'Clear usage history',
            subtitle: 'Deletes recorded traffic and looked-up addresses',
            onConfirm: bloc.usage.clearHistory,
          ),
        ]),
      ],
    );
  }

  Widget _probeInterval() {
    return FutureBuilder<int>(
      future: AppSharedPreferences.qualityInterval,
      builder: (context, snapshot) {
        final seconds = snapshot.data ?? 2;
        return _SettingRow(
          title: 'Probe interval',
          subtitle: 'Shorter catches more glitches · ≈ ${estimatedDailyMegabytes(seconds)} MB of data a day',
          trailing: SegmentedPills<int>(
            values: const [2, 5, 10],
            selected: seconds,
            label: (v) => '${v}s',
            onSelected: (v) async {
              await bloc.quality.setIntervalSeconds(v);
              if (mounted) setState(() {});
            },
          ),
        );
      },
    );
  }

  Widget _clearRow({
    required String title,
    required String subtitle,
    required Future<void> Function() onConfirm,
  }) {
    return _SettingRow(
      title: title,
      subtitle: subtitle,
      trailing: AppButton(
        label: 'Clear',
        kind: AppButtonKind.danger,
        height: 34,
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: AppColors.card,
              title: Text('$title?', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
              content: Text('This can\'t be undone.',
                  style: AppText.ui(13, FontWeight.w400, AppColors.text2)),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text('Clear', style: AppText.ui(14, FontWeight.w600, AppColors.bad)),
                ),
              ],
            ),
          );
          if (ok == true) await onConfirm();
        },
      ),
    );
  }

  Widget _group(String title, List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) {
        children.add(Container(height: 1, color: AppColors.line));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Overline(title),
        const SizedBox(height: 10),
        AppCard(padding: EdgeInsets.zero, clip: true, child: Column(children: children)),
      ],
    );
  }

  Widget _futureToggle({
    required String title,
    required String subtitle,
    required Future<bool> value,
    required Future<void> Function(bool) onChanged,
  }) {
    return FutureBuilder<bool>(
      future: value,
      builder: (context, snapshot) {
        final v = snapshot.data ?? false;
        return _SettingRow(
          title: title,
          subtitle: subtitle,
          trailing: AppSwitch(
            value: v,
            onChanged: (next) async {
              await onChanged(next);
              if (mounted) setState(() {});
            },
          ),
        );
      },
    );
  }

  Widget _launchAtStartup() {
    final isWindows = Platform.isWindows;
    return FutureBuilder<bool>(
      future: isWindows ? LaunchAtStartup.instance.isEnabled() : Future.value(false),
      builder: (context, snapshot) {
        final v = snapshot.data ?? false;
        return _SettingRow(
          title: 'Launch on startup',
          subtitle: 'Start IRNet automatically when Windows boots',
          badge: 'Windows only',
          trailing: AppSwitch(
            value: v,
            onChanged: isWindows
                ? (next) async {
                    if (next) {
                      await LaunchAtStartup.instance.enable();
                    } else {
                      await LaunchAtStartup.instance.disable();
                    }
                    if (mounted) setState(() {});
                  }
                : null,
          ),
        );
      },
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.badge,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: AppText.ui(14, FontWeight.w500, AppColors.text)),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0x1FFBBF24),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(badge!.toUpperCase(),
                            style: AppText.ui(9, FontWeight.w600, AppColors.warn,
                                letterSpacing: 0.5)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(subtitle, style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}
