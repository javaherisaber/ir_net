import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../data/shared_preferences.dart';

class AppOptions extends StatefulWidget {
  const AppOptions({super.key});

  @override
  State<AppOptions> createState() => _AppOptionsState();
}

class _AppOptionsState extends State<AppOptions> {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          showLeakInSysTray(),
          launchAtStartup()
        ],
      ),
    );
  }

  Widget launchAtStartup() {
    return FutureBuilder<bool>(
      future: LaunchAtStartup.instance.isEnabled(),
      builder: (context, snapshot) {
        final value = snapshot.data ?? false;
        return CheckboxListTile(
          title: const Text('Launch on windows startup?'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          value: value,
          enabled: !Platform.isMacOS, // todo: implement macos
          onChanged: (enabled) {
            if (enabled == true) {
              LaunchAtStartup.instance.enable();
            } else {
              LaunchAtStartup.instance.disable();
            }
            setState(() {});
          },
        );
      },
    );
  }

  Widget showLeakInSysTray() {
    return FutureBuilder<bool>(
      future: AppSharedPreferences.showLeakInSysTray,
      builder: (context, snapshot) {
        final value = snapshot.data ?? false;
        return CheckboxListTile(
          title: const Text('Show leak detection on system tray icon?'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          value: value,
          onChanged: (enabled) async {
            await AppSharedPreferences.setShowLeakInSysTray(enabled ?? false);
            setState(() {});
          },
        );
      },
    );
  }
}
