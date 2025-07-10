import 'dart:io';

import 'package:flutter/material.dart';
import 'package:system_tray/system_tray.dart';
import 'package:ir_net/utils/platform_icons.dart';

mixin AppSystemTray {
  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();

  void onSystemTrayRefreshButtonClick();

  void updateSysTrayIcon(String tooltip, String iconPath) {
    _systemTray.setToolTip(tooltip);
    _systemTray.setImage(iconPath);
  }

  void setSystemTrayStatusToOffline() {
    _systemTray.setImage(PlatformIcons.offlineIcon);
    _systemTray.setToolTip('IRNet: OFFLINE');
  }

  void setSystemTrayStatusToNetworkError() {
    _systemTray.setImage(PlatformIcons.networkErrorIcon);
    _systemTray.setToolTip('IRNet: Network error');
  }

  void destroySystemTray() {
    _systemTray.destroy();
  }

  Future<void> initSystemTray() async {
    await _systemTray.initSystemTray(
      title: "system tray",
      iconPath: PlatformIcons.loadingIcon,
    );
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show', onClicked: (menuItem) => _appWindow.show()),
      MenuItemLabel(label: 'Hide', onClicked: (menuItem) => _appWindow.hide()),
      MenuItemLabel(
        label: 'Refresh',
        onClicked: (menuItem) {
          onSystemTrayRefreshButtonClick();
        },
      ),
      MenuItemLabel(
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