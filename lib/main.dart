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
import 'package:sentry_flutter/sentry_flutter.dart';

final bloc = AppBloc();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initWindowManager();
  await initSingleInstance();
  await initWinToast();
  await initLaunchAtStartup();
  await initSharedPreferences();
  await initSentry();
  bloc.initialize();
}

Future<void> initSentry() async {
  await SentryFlutter.init((options) {
      options.dsn = 'https://7bba19233fbc2fa1f5a7a6c7770aa571@o4510396075409408.ingest.de.sentry.io/4510396076654672';
      // Set tracesSampleRate to 1.0 to capture 100% of transactions for tracing.
      // We recommend adjusting this value in production.
      options.tracesSampleRate = 1.0;
      // Enable logs to be sent to Sentry
      options.enableLogs = true;
      // Record session replays for 100% of errors and 10% of sessions
      options.replay.onErrorSampleRate = 1.0;
      options.replay.sessionSampleRate = 0.1;
      // The sampling rate for profiling is relative to tracesSampleRate
      // Setting to 1.0 will profile 100% of sampled transactions:
      options.profilesSampleRate = 1.0;
    },
    appRunner: () => runApp(SentryWidget(child: const App())),
  );
}

class MacWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    // On macOS, hide the window instead of closing it
    if (Platform.isMacOS) {
      await windowManager.hide();
    }
  }
}

Future<void> initWindowManager() async {
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1000, 780),
  );
  windowManager.waitUntilReadyToShow(
    windowOptions,
    () async {
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        final version = packageInfo.version;
        await windowManager.setTitle("IRNet V$version - freedom does not have a price");
      } catch (e) {
        // Fallback to default title if PackageInfo fails
        await windowManager.setTitle("IRNet - freedom does not have a price");
      }
      // On macOS, add window listener to handle close button
      if (Platform.isMacOS) {
        windowManager.addListener(MacWindowListener());
      }
    },
  );
}

Future<void> initSingleInstance() async {
  await WindowsSingleInstance.ensureSingleInstance([], "pipeMain");
}

Future<void> initWinToast() async {
  if (Platform.isWindows == false) {
    // todo: implement other platforms
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
