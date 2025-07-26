import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win_toast/win_toast.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'bloc.dart';

final bloc = AppBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initWindowManager();
  await initSingleInstance();
  await initWinToast();
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

Future<void> initSingleInstance() async {
  await WindowsSingleInstance.ensureSingleInstance([], "pipeMain");
}

Future<void> initWinToast() async {
  if (Platform.isMacOS) {
    // todo: implement macos
    return Future.value();
  }
  await WinToast.instance().initialize(
    appName: 'IRNet',
    productName: 'IRNet',
    companyName: 'BuildToApp',
  );
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
