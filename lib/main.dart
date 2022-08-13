import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app.dart';
import 'bloc.dart';

final bloc = MyBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeLaunchAtStartup();
  bloc.initialize();
  runApp(const MyApp());
}

Future<void> initializeLaunchAtStartup() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  LaunchAtStartup.instance.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
  );
}
