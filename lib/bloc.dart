import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlng/latlng.dart';
import 'package:rxdart/rxdart.dart';
import 'package:system_tray/system_tray.dart';

class MyBloc {
  final SystemTray systemTray = SystemTray();
  final AppWindow appWindow = AppWindow();
  final _latLng = StreamController<LatLng>();
  final _ipLookupResult = BehaviorSubject();

  bool _isPingingGoogle = false;

  Stream<LatLng> get latLng => _latLng.stream;
  Stream get ipLookupResult => _ipLookupResult.stream;

  void initialize() {
    initSystemTray();
    pingGoogle();
    runIpCheckInfinitely();
    subscribeConnectivityChange();
    appWindow.hide();
    systemTray.setToolTip('IRNet: NOT READY');
  }

  void subscribeConnectivityChange() {
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      if (result != ConnectivityResult.none) {
        checkIpLocation();
      } else {
        setStatusToOffline();
      }
    });
  }

  void runIpCheckInfinitely() async {
    while (true) {
      checkIpLocation();
      await Future.delayed(const Duration(seconds: 20));
    }
  }

  void pingGoogle() async {
    try {
      _isPingingGoogle = true;
      final url = Uri.parse('https://google.com');
      await http.get(url).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _isPingingGoogle = false;
      checkNetworkConnectivity();
      return;
    }
    _isPingingGoogle = false;
  }

  void checkIpLocation() async {
    http.Response response;
    try {
      final ipv4 = await Ipify.ipv4();
      final uri = Uri.parse('http://ip-api.com/json/$ipv4?fields=1060825');
      response = await http.get(uri).timeout(const Duration(seconds: 5));
    } catch (e) {
      checkNetworkConnectivity();
      return;
    }
    final json = jsonDecode(response.body);
    final country = json['country'];
    updateTrayIcon(isIran: country == 'Iran');
    systemTray.setToolTip('IRNet: $country');
    if (json['lat'] != null && json['lon'] != null) {
      _latLng.sink.add(LatLng(json['lat'], json['lon']));
    }
    _ipLookupResult.value = json;
    debugPrint('Country => $country');
  }

  void checkNetworkConnectivity() async {
    final result = await (Connectivity().checkConnectivity());
    if (result == ConnectivityResult.none) {
      setStatusToOffline();
    } else {
      setStatusToNetworkError();
      if (!_isPingingGoogle) {
        pingGoogle();
      }
    }
  }

  void setStatusToOffline() {
    systemTray.setImage('assets/offline.ico');
    systemTray.setToolTip('IRNet: OFFLINE');
  }

  void setStatusToNetworkError() {
    systemTray.setImage('assets/network_error.ico');
    systemTray.setToolTip('IRNet: Network error');
  }

  void onExitClick() {
    systemTray.destroy();
    exit(0);
  }

  void onRefreshButtonClick() {
    checkIpLocation();
  }

  void updateTrayIcon({bool isIran = false}) {
    systemTray.setImage(isIran ? 'assets/iran.ico' : 'assets/globe.ico');
  }

  Future<void> initSystemTray() async {
    // We first init the systray menu
    await systemTray.initSystemTray(
      title: "system tray",
      iconPath: 'assets/globe.ico',
    );

    // create context menu
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLable(label: 'Show', onClicked: (menuItem) => appWindow.show()),
      MenuItemLable(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
      MenuItemLable(label: 'Refresh', onClicked: (menuItem) {
        pingGoogle();
        checkIpLocation();
      }),
      MenuItemLable(
          label: 'Exit',
          onClicked: (menuItem) {
            systemTray.destroy();
            exit(0);
          }),
    ]);

    // set context menu
    await systemTray.setContextMenu(menu);

    // handle system tray event
    systemTray.registerSystemTrayEventHandler((eventName) {
      debugPrint("eventName: $eventName");
      if (eventName == kSystemTrayEventClick) {
        appWindow.show();
      } else if (eventName == kSystemTrayEventRightClick) {
        systemTray.popUpContextMenu();
      }
    });
  }
}
