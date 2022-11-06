import 'dart:io';

import 'package:flutter/material.dart';
import 'package:system_tray/system_tray.dart';

mixin AppSystemTray {
  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();

  void onSystemTrayRefreshButtonClick();

  void updateSysTrayIcon(String tooltip, String iconPath) {
    _systemTray.setToolTip(tooltip);
    _systemTray.setImage(iconPath);
  }

  void setSystemTrayStatusToOffline() {
    _systemTray.setImage('assets/offline.ico');
    _systemTray.setToolTip('IRNet: OFFLINE');
  }

  void setSystemTrayStatusToNetworkError() {
    _systemTray.setImage('assets/network_error.ico');
    _systemTray.setToolTip('IRNet: Network error');
  }

  void destroySystemTray() {
    _systemTray.destroy();
  }

  Future<void> initSystemTray() async {
    await _systemTray.initSystemTray(
      title: "system tray",
      iconPath: 'assets/loading.ico',
    );
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLable(label: 'Show', onClicked: (menuItem) => _appWindow.show()),
      MenuItemLable(label: 'Hide', onClicked: (menuItem) => _appWindow.hide()),
      MenuItemLable(
        label: 'Refresh',
        onClicked: (menuItem) {
          onSystemTrayRefreshButtonClick();
        },
      ),
      MenuItemLable(
        label: 'Exit',
        onClicked: (menuItem) {
          _systemTray.destroy();
          exit(0);
        },
      ),
    ]);

    await _systemTray.setContextMenu(menu);
    _systemTray.registerSystemTrayEventHandler((eventName) {
      debugPrint("eventName: $eventName");
      if (eventName == kSystemTrayEventClick) {
        _appWindow.show();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });

    _appWindow.hide();
    _systemTray.setToolTip('IRNet: NOT READY');
  }
}