import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'bloc.dart';

final bloc = AppBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initWindowManager();
  
  // Use platform-specific initialization
  if (Platform.isWindows) {
    await initSingleInstance();
    await initWinToast();
  }
  
  await initLaunchAtStartup();
  await initSharedPreferences();
  bloc.initialize();
  runApp(const App());
}

Future<void> initWindowManager() async {
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1000, 780),
  );
  windowManager.waitUntilReadyToShow(windowOptions, () {
    windowManager.setTitle("IRNet: freedom does not have a price");
  },);
}

// Only include Windows-specific imports when needed
Future<void> initSingleInstance() async {
  if (Platform.isWindows) {
    // Import only when needed to avoid errors on Linux
    await (await import('package:windows_single_instance/windows_single_instance.dart'))
        .WindowsSingleInstance.ensureSingleInstance([], "pipeMain");
  }
}

Future<void> initWinToast() async {
  if (Platform.isWindows) {
    // Import only when needed to avoid errors on Linux
    await (await import('package:win_toast/win_toast.dart'))
        .WinToast.instance().initialize(
      appName: 'IRNet',
      productName: 'IRNet',
      companyName: 'BuildToApp',
    );
  }
}

Future<void> initSharedPreferences() async {
  if (!(await AppSharedPreferences.isLeakPrePopulated)) {
    for (var url in LeakItem.prePopulatedUrls()) {
      await AppSharedPreferences.addToLeakChecklist(url);
    }
    await AppSharedPreferences.setIsLeakPrePopulated(true);
  }
  if ((await AppSharedPreferences.kerioIP) == null) {
    await AppSharedPreferences.setKerioIP('172.18.18.1:4080');
  }
}

Future<void> initLaunchAtStartup() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  LaunchAtStartup.instance.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
  );
}
