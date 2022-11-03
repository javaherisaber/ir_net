import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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
  String? _proxyServer;
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
    _foundALeakedSite = false;
    _updateCountryTrayIcon();
    final checklist = _leakChecklist.valueOrNull;
    if (checklist != null) {
      for (var item in checklist) {
        _checkLeakedSite(item);
      }
    }
  }

  IOClient get _client {
    final httpClient = HttpClient();
    if (_proxyServer != null) {
      httpClient.findProxy = (uri) {
        return 'PROXY $_proxyServer';
      };
    } else {
      httpClient.findProxy = null;
    }
    return IOClient(httpClient);
  }

  Future<void> _checkLeakedSite(LeakItem item) async {
    item.status = LeakStatus.loading;
    _replaceLeakItemInChecklist(item);
    try {
      final url = Uri.parse(item.url);
      final response = await _client.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        item.status = LeakStatus.passed;
      } else {
        item.status = LeakStatus.failed;
      }
      debugPrint('leak detection for $url => ${response.bodyBytes.length ~/ 1024} Kilobytes');
    } on Exception catch(ex) {
      item.status = LeakStatus.failed;
      _checkNetworkRefuseException(ex);
    }
    if (item.status == LeakStatus.failed) {
      _foundALeakedSite = true;
      _updateCountryTrayIcon();
    }
    _replaceLeakItemInChecklist(item);
  }

  void _replaceLeakItemInChecklist(LeakItem item) {
    _leakChecklist.value = _leakChecklist.value.map((e) => e.url == item.url ? item : e).toList();
  }

  void _subscribeConnectivityChange() {
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) async {
      if (result != ConnectivityResult.none) {
        await _checkProxySettings();
        _checkIpLocation();
        _verifyLeakedSites();
      } else {
        _setStatusToOffline();
      }
    });
  }

  void _runIpCheckInfinitely() async {
    while (true) {
      await _checkProxySettings();
      _checkIpLocation();
      await Future.delayed(const Duration(seconds: 20));
    }
  }

  void _pingGoogle() async {
    try {
      _isPingingGoogle = true;
      final url = Uri.parse('https://google.com');
      await _client.get(url).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _isPingingGoogle = false;
      _checkNetworkConnectivity();
      return;
    } on SocketException catch(ex) {
      _checkNetworkRefuseException(ex);
    }
    _isPingingGoogle = false;
  }

  void _checkNetworkRefuseException(Exception ex) {
    if (ex is SocketException && ex.message.startsWith('The remote computer refused the network connection.')) {
      _proxyServer = null;
    }
  }

  Future<void> _checkIpLocation() async {
    http.Response response;
    try {
      final ipv4 = (await _client.get(Uri.parse("https://api.ipify.org"))).body;
      final uri = Uri.parse('http://ip-api.com/json/$ipv4?fields=1060825');
      response = await _client.get(uri).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _checkNetworkConnectivity();
      return;
    } on SocketException catch (ex) {
      _checkNetworkRefuseException(ex);
      return;
    }
    final json = jsonDecode(response.body);
    if (json['lat'] != null && json['lon'] != null) {
      _latLng.sink.add(LatLng(json['lat'], json['lon']));
    }
    _ipLookupResult.value = json;
    _updateCountryTrayIcon();
  }

  Future<void> _checkProxySettings() async {
    var executable = r'reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings"';
    var result = await Process.run(executable, []);
    final stdout = result.stdout.toString();
    String? proxyServer;
    var proxyIsEnabled = false;
    if (stdout.isNotEmpty) {
      final lines = stdout.split('\r\n');
      for (var element in lines) {
        if (element.contains('ProxyEnable') && element.endsWith('0x1')) {
          proxyIsEnabled = true;
        } else if (element.contains('ProxyEnable') && element.endsWith('0x0')) {
          proxyIsEnabled = false;
        }
        if (element.contains('ProxyServer')) {
          proxyServer = element.split(' ').last;
          break;
        }
      }
    }
    var shouldRefreshLeakedSites = false;
    if ((proxyIsEnabled && _proxyServer != proxyServer) ||
        (!proxyIsEnabled && _proxyServer != null)) {
      // there was a change in proxy settings
      shouldRefreshLeakedSites = true;
    }
    if (proxyIsEnabled) {
      _proxyServer = proxyServer;
    } else {
      _proxyServer = null;
    }
    if (shouldRefreshLeakedSites) {
      _verifyLeakedSites();
    }
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

  void onRefreshButtonClick() async {
    await _checkProxySettings();
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
