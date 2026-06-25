import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'components.dart';
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
      ],
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
