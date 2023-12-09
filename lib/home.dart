import 'package:flutter/material.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/views/ip_stat.dart';
import 'package:ir_net/views/leak.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'main.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  LeakView(),
                  SizedBox(width: 64),
                  IpStatView(),
                ],
              ),
              const SizedBox(height: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 400,
                    child: showLeakInSysTray(),
                  ),
                  SizedBox(
                    width: 300,
                    child: launchAtStartup(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  exitButton(),
                  const SizedBox(width: 16),
                  refreshButton(),
                ],
              ),
            ],
          ),
        ),
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
          value: value,
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
          value: value,
          onChanged: (enabled) async {
            await AppSharedPreferences.setShowLeakInSysTray(enabled ?? false);
            setState(() {});
          },
        );
      },
    );
  }

  Widget exitButton() {
    return ElevatedButton(
      style: ButtonStyle(minimumSize: MaterialStateProperty.all(const Size(80, 56))),
      onPressed: bloc.onExitClick,
      child: const Text('Exit'),
    );
  }

  Widget refreshButton() {
    return ElevatedButton(
      style: ButtonStyle(minimumSize: MaterialStateProperty.all(const Size(80, 56))),
      onPressed: bloc.onRefreshButtonClick,
      child: const Text('Refresh'),
    );
  }
}
