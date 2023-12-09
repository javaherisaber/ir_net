import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win_toast/win_toast.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app.dart';
import 'bloc.dart';

final bloc = AppBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSingleInstance();
  await initWinToast();
  await initLaunchAtStartup();
  await initSharedPreferences();
  bloc.initialize();
  runApp(const App());
}

Future<void> initSingleInstance() async {
  await WindowsSingleInstance.ensureSingleInstance([], "pipeMain");
}

Future<void> initWinToast() async {
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
}

Future<void> initLaunchAtStartup() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  LaunchAtStartup.instance.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
  );
}
