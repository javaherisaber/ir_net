import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/utils/flag_tray_icon.dart';
import 'package:ir_net/utils/platform.dart';
import 'package:system_tray/system_tray.dart';

mixin AppSystemTray {
  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();

  void onSystemTrayRefreshButtonClick();

  void updateSysTrayIcon(String tooltip, String iconPath) {
    _systemTray.setToolTip(tooltip);
    _systemTray.setImage(iconPath);
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
    _systemTray.setImage(_getIcon('assets/offline'));
    _systemTray.setToolTip('IRNet: OFFLINE');
  }

  void setSystemTrayStatusToNetworkError() {
    _systemTray.setImage(_getIcon('assets/network_error'));
    _systemTray.setToolTip('IRNet: Network error');
  }

  void destroySystemTray() {
    _systemTray.destroy();
  }

  Future<void> initSystemTray() async {
    if (!PlatformUtils.isDesktop) {
      return;
    }
    await _systemTray.initSystemTray(
      title: null,
      iconPath: _getIcon('assets/loading'),
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
