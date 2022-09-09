import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/sharedpreferences.dart';
import 'package:latlng/latlng.dart';
import 'package:live_event/live_event.dart';
import 'package:rxdart/rxdart.dart';
import 'package:system_tray/system_tray.dart';
import 'package:win_toast/win_toast.dart';

class MyBloc {
  final SystemTray systemTray = SystemTray();
  final AppWindow appWindow = AppWindow();
  final _latLng = StreamController<LatLng>();
  final _ipLookupResult = BehaviorSubject();
  final _clearLeakInput = LiveEvent();
  final _leakChecklist = BehaviorSubject<List<LeakItem>>();

  bool _isPingingGoogle = false;
  bool _foundALeakedSite = false;
  String? _leakInput;

  Stream<LatLng> get latLng => _latLng.stream;
  Stream get ipLookupResult => _ipLookupResult.stream;
  Stream get clearLeakInput => _clearLeakInput.stream;
  Stream<List<LeakItem>> get leakChecklist => _leakChecklist.stream;

  void onLeakInputChanged(String value) {
    _leakInput = value;
  }

  void initialize() {
    _initSystemTray();
    _pingGoogle();
    _runIpCheckInfinitely();
    _subscribeConnectivityChange();
    appWindow.hide();
    systemTray.setToolTip('IRNet: NOT READY');
    _initializeLeakChecklist();
  }

  void _initializeLeakChecklist() async {
    await _updateLeakChecklist();
    _verifyLeakedSites();
  }

  void onDeleteLeakItemClick(LeakItem item) async {
    await AppSharedPreferences.removeFromLeakChecklist(item.url);
    _updateLeakChecklist();
  }

  void onAddLeakItemClick() async {
    if (_leakInput == null || _leakInput?.trim().isEmpty == true) {
      WinToast.instance().showToast(type: ToastType.text01, title: 'No input entered!');
      return;
    }
    if ((await AppSharedPreferences.leakChecklist).contains(_leakInput)) {
      WinToast.instance().showToast(type: ToastType.text01, title: 'Repetitive input not allowed!');
      return;
    }
    await AppSharedPreferences.addToLeakChecklist(_leakInput!);
    _updateLeakChecklist();
    _clearLeakInput.fire();
    _leakInput = null;
  }

  Future<void> _updateLeakChecklist() async {
    _leakChecklist.value =
        (await AppSharedPreferences.leakChecklist).map((e) => LeakItem(e)).toList();
  }

  void _verifyLeakedSites() async {
    final checklist = _leakChecklist.valueOrNull;
    if (checklist != null) {
      for (var item in checklist) {
        await _checkLeakedSite(item);
      }
      _foundALeakedSite = checklist.any((element) => element.status == LeakStatus.failed);
      _updateCountryTrayIcon();
    }
  }

  Future<void> _checkLeakedSite(LeakItem item) async {
    item.status = LeakStatus.loading;
    _replaceLeakItemInChecklist(item);
    try {
      final url = Uri.parse(item.url);
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        item.status = LeakStatus.passed;
      } else {
        item.status = LeakStatus.failed;
      }
      debugPrint('leak detection for $url => ${response.bodyBytes.length ~/ 1024} Kilobytes');
    } on Exception {
      item.status = LeakStatus.failed;
    }
    _replaceLeakItemInChecklist(item);
  }

  void _replaceLeakItemInChecklist(LeakItem item) {
    _leakChecklist.value = _leakChecklist.value.map((e) => e.url == item.url ? item : e).toList();
  }

  void _subscribeConnectivityChange() {
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      if (result != ConnectivityResult.none) {
        _checkIpLocation();
        _verifyLeakedSites();
      } else {
        _setStatusToOffline();
      }
    });
  }

  void _runIpCheckInfinitely() async {
    while (true) {
      _checkIpLocation();
      await Future.delayed(const Duration(seconds: 20));
    }
  }

  void _pingGoogle() async {
    try {
      _isPingingGoogle = true;
      final url = Uri.parse('https://google.com');
      await http.get(url).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _isPingingGoogle = false;
      _checkNetworkConnectivity();
      return;
    }
    _isPingingGoogle = false;
  }

  void _checkIpLocation() async {
    http.Response response;
    try {
      final ipv4 = await Ipify.ipv4();
      final uri = Uri.parse('http://ip-api.com/json/$ipv4?fields=1060825');
      response = await http.get(uri).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _checkNetworkConnectivity();
      return;
    }
    final json = jsonDecode(response.body);
    if (json['lat'] != null && json['lon'] != null) {
      _latLng.sink.add(LatLng(json['lat'], json['lon']));
    }
    _ipLookupResult.value = json;
    _updateCountryTrayIcon();
  }

  void _checkNetworkConnectivity() async {
    final result = await (Connectivity().checkConnectivity());
    if (result == ConnectivityResult.none) {
      _setStatusToOffline();
    } else {
      _setStatusToNetworkError();
      if (!_isPingingGoogle) {
        _pingGoogle();
      }
    }
  }

  void _setStatusToOffline() {
    systemTray.setImage('assets/offline.ico');
    systemTray.setToolTip('IRNet: OFFLINE');
  }

  void _setStatusToNetworkError() {
    systemTray.setImage('assets/network_error.ico');
    systemTray.setToolTip('IRNet: Network error');
  }

  void onExitClick() {
    systemTray.destroy();
    exit(0);
  }

  void onRefreshButtonClick() {
    _pingGoogle();
    _checkIpLocation();
    _verifyLeakedSites();
  }

  void _updateCountryTrayIcon() async {
    final json = _ipLookupResult.valueOrNull;
    if (json == null) {
      return;
    }
    final country = json['country'];
    bool isIran = country == 'Iran';
    if (_foundALeakedSite) {
      systemTray.setToolTip('IRNet: $country (Leaked!)');
    } else {
      systemTray.setToolTip('IRNet: $country');
    }
    var globIcon = 'assets/globe.ico';
    if (_foundALeakedSite && (await AppSharedPreferences.showLeakInSysTray)) {
      globIcon = 'assets/globe_leaked.ico';
    }
    systemTray.setImage(isIran ? 'assets/iran.ico' : globIcon);
    debugPrint('Country => $country');
  }

  Future<void> _initSystemTray() async {
    // We first init the systray menu
    await systemTray.initSystemTray(
      title: "system tray",
      iconPath: 'assets/loading.ico',
    );

    // create context menu
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLable(label: 'Show', onClicked: (menuItem) => appWindow.show()),
      MenuItemLable(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
      MenuItemLable(
        label: 'Refresh',
        onClicked: (menuItem) {
          onRefreshButtonClick();
        },
      ),
      MenuItemLable(
        label: 'Exit',
        onClicked: (menuItem) {
          systemTray.destroy();
          exit(0);
        },
      ),
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
