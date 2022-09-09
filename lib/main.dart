import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/sharedpreferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win_toast/win_toast.dart';

import 'app.dart';
import 'bloc.dart';

final bloc = MyBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeWinToast();
  await initializeLaunchAtStartup();
  await initializeSharedPreferences();
  bloc.initialize();
  runApp(const MyApp());
}

Future<void> initializeWinToast() async {
  await WinToast.instance().initialize(
    appName: 'IRNet',
    productName: 'IRNet',
    companyName: 'BuildToApp',
  );
}

Future<void> initializeSharedPreferences() async {
  if (!(await AppSharedPreferences.isLeakPrePopulated)) {
    for (var url in LeakItem.prePopulatedUrls()) {
      await AppSharedPreferences.addToLeakChecklist(url);
    }
    await AppSharedPreferences.setIsLeakPrePopulated(true);
  }
}

Future<void> initializeLaunchAtStartup() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  LaunchAtStartup.instance.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
  );
}
