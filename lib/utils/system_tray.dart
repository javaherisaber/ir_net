import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/utils/flag_tray_icon.dart';
import 'package:ir_net/utils/platform.dart';
import 'package:system_tray/system_tray.dart';

mixin AppSystemTray {
  // The tray plugin only exists on desktops: creating AppWindow already calls
  // it, so on phones there are no handles and every tray call is a no-op.
  final SystemTray? _systemTray = PlatformUtils.isDesktop ? SystemTray() : null;
  final AppWindow? _appWindow = PlatformUtils.isDesktop ? AppWindow() : null;

  void onSystemTrayRefreshButtonClick();

  void onSystemTrayExitButtonClick();

  void updateSysTrayIcon(String tooltip, String iconPath) {
    _systemTray?.setToolTip(tooltip);
    _systemTray?.setImage(iconPath);
  }

  String _getIcon(String iconPath) {
    if (Platform.isLinux) {
      return '$iconPath.png';
    } else {
      return '$iconPath.ico';
    }
  }

  void updateIconWhenCountryLoaded(
      bool foundLeak, bool isIran, String? countryCode, String tooltip) async {
    if (_systemTray == null) return;
    final showLeak = foundLeak && (await AppSharedPreferences.showLeakInSysTray);
    if (await AppSharedPreferences.showCountryFlagInSysTray) {
      final flagIcon = await FlagTrayIcon.pathFor(countryCode, leaked: showLeak);
      if (flagIcon != null) {
        updateSysTrayIcon(tooltip, flagIcon);
        return;
      }
      // Unknown country: keep the default icons below.
    }
    var globIcon = _getIcon('assets/globe');
    if (showLeak) {
      globIcon = _getIcon('assets/globe_leaked');
    }
    final iconPath = isIran ? _getIcon('assets/iran') : globIcon;
    updateSysTrayIcon(tooltip, iconPath);
  }

  void setSystemTrayStatusToOffline() {
    _systemTray?.setImage(_getIcon('assets/offline'));
    _systemTray?.setToolTip('IRNet: OFFLINE');
  }

  void setSystemTrayStatusToNetworkError() {
    _systemTray?.setImage(_getIcon('assets/network_error'));
    _systemTray?.setToolTip('IRNet: Network error');
  }

  void destroySystemTray() {
    _systemTray?.destroy();
  }

  Future<void> initSystemTray() async {
    final systemTray = _systemTray;
    final appWindow = _appWindow;
    if (systemTray == null || appWindow == null) {
      return;
    }
    await systemTray.initSystemTray(
      title: null,
      iconPath: _getIcon('assets/loading'),
    );
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show', onClicked: (menuItem) => appWindow.show()),
      MenuItemLabel(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
      MenuItemLabel(
        label: 'Refresh',
        onClicked: (menuItem) {
          onSystemTrayRefreshButtonClick();
        },
      ),
      MenuItemLabel(
        label: 'Exit',
        onClicked: (menuItem) => onSystemTrayExitButtonClick(),
      ),
    ]);

    await systemTray.setContextMenu(menu);
    systemTray.registerSystemTrayEventHandler((eventName) {
      debugPrint("eventName: $eventName");
      if (eventName == kSystemTrayEventClick) {
        appWindow.show();
      } else if (eventName == kSystemTrayEventRightClick) {
        systemTray.popUpContextMenu();
      }
    });

    appWindow.hide();
    systemTray.setToolTip('IRNet: NOT READY');
  }
}
