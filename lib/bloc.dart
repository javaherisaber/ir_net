import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speedtest/flutter_speedtest.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ir_net/data/kerio.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/utils/cmd.dart';
import 'package:ir_net/utils/http.dart';
import 'package:ir_net/utils/system_tray.dart';
import 'package:latlng/latlng.dart';
import 'package:live_event/live_event.dart';
import 'package:rxdart/rxdart.dart';
import 'package:win_toast/win_toast.dart';

import 'utils/kerio.dart';

class AppBloc with AppSystemTray {
  static const platform = MethodChannel('ir_net/system_events');

  final _latLng = StreamController<LatLng>();
  final _ipLookupResult = BehaviorSubject();
  final _clearLeakInput = LiveEvent();
  final _leakChecklist = BehaviorSubject<List<LeakItem>>();
  final _localNetwork = BehaviorSubject<LocalNetworksResult>();
  final _ping = BehaviorSubject<double?>();
  final _downloadSpeed = BehaviorSubject<double?>();
  final _uploadSpeed = BehaviorSubject<double?>();
  final _speedTestStatus = BehaviorSubject<String>();
  final _kerioBalance = BehaviorSubject<KerioBalance>();

  bool _isPingingGoogle = false;
  bool _foundALeakedSite = false;
  String? _proxyServer;
  String? _leakInput;

  Stream<LatLng> get latLng => _latLng.stream;
  Stream get ipLookupResult => _ipLookupResult.stream;
  Stream get clearLeakInput => _clearLeakInput.stream;
  Stream<List<LeakItem>> get leakChecklist => _leakChecklist.stream;
  Stream<LocalNetworksResult> get localNetwork => _localNetwork.stream;
  Stream<double?> get ping => _ping.stream;
  Stream<double?> get downloadSpeed => _downloadSpeed.stream;
  Stream<double?> get uploadSpeed => _uploadSpeed.stream;
  Stream<String> get speedTestStatus => _speedTestStatus.stream;
  Stream<KerioBalance> get kerioBalance => _kerioBalance.stream;

  final speedtest = FlutterSpeedtest(
    baseUrl: 'http://speedtest.jaosing.com:8080',
    pathDownload: '/download',
    pathUpload: '/upload',
    pathResponseTime: '/ping',
  );

  void onLeakInputChanged(String value) {
    _leakInput = value;
  }

  void initialize() {
    initSystemTray();
    _pingGoogle();
    _runIpCheckInfinitely();
    _runKerioCheckInfinitely();
    _subscribeConnectivityChange();
    _loginKerio(false);
    _initializeLeakChecklist();
    _initializeNativeChannel();
  }

  void _initializeNativeChannel() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onMacOsWake' 
          || call.method == 'onWindowsWake' 
          || call.method == 'onLinuxWake') {
        await Future.delayed(const Duration(seconds: 3));
        _handleRefresh();
      }
    });
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
      _showToast('No input entered!');
      return;
    }
    if ((await AppSharedPreferences.leakChecklist).contains(_leakInput)) {
      _showToast('Repetitive input not allowed!');
      return;
    }
    await AppSharedPreferences.addToLeakChecklist(_leakInput!);
    _updateLeakChecklist();
    _clearLeakInput.fire();
    _leakInput = null;
  }

  void onKerioLoginClick() async {
    await _loginKerio(true);
    _checkKerioBalance();
  }

  Future<void> _loginKerio(bool manual) async {
    var auto = await AppSharedPreferences.kerioAutoLogin;
    if (!manual && !auto) {
      return Future.value();
    }
    final ip = await AppSharedPreferences.kerioIP;
    final username = await AppSharedPreferences.kerioUsername;
    final password = await AppSharedPreferences.kerioPassword;
    final url = 'http://$ip/internal/dologin.php';
    await http.post(
      Uri.parse(url),
      body: {
        'kerio_username': username,
        'kerio_password': password,
      },
    );
  }

  Future<void> _updateLeakChecklist() async {
    _leakChecklist.value = (await AppSharedPreferences.leakChecklist).map((e) => LeakItem(e)).toList();
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
      final response = await _client.head(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        item.status = LeakStatus.passed;
      } else {
        item.status = LeakStatus.failed;
      }
      debugPrint('leak detection for $url => ${response.bodyBytes.length ~/ 1024} Kilobytes');
    } on Exception catch (ex) {
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
        _checkPing();
      } else {
        setSystemTrayStatusToOffline();
      }
    });
  }

  void _checkPing() async {
    _ping.value = await HttpUtils.measureHttpPing();
  }

  void _runIpCheckInfinitely() async {
    while (true) {
      await _checkProxySettings();
      _verifyLeakedSites();
      _checkIpLocation();
      await Future.delayed(const Duration(seconds: 20));
    }
  }

  void _runKerioCheckInfinitely() async {
    while (true) {
      _checkKerioBalance();
      await Future.delayed(const Duration(seconds: 20));
    }
  }

  void _pingGoogle() async {
    try {
      _isPingingGoogle = true;
      final url = Uri.parse('https://google.com');
      await _client.head(url).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _isPingingGoogle = false;
      _checkNetworkConnectivity();
      return;
    } on SocketException catch (ex) {
      _checkNetworkRefuseException(ex);
    }
    _isPingingGoogle = false;
  }

  void _checkNetworkRefuseException(Exception ex) {
    if (ex is SocketException &&
        ex.message.startsWith('The remote computer refused the network connection.')) {
      _proxyServer = null;
    }
  }

  Future<void> _checkIpLocation() async {
    http.Response response;
    try {
      final ipv4 = (await _client.get(Uri.parse("https://api.ipify.org"))).body;
      final uri = Uri.parse('http://ip-api.com/json/$ipv4?fields=1057497');
      response = await _client.get(uri).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _checkNetworkConnectivity();
      return;
    } on SocketException catch (ex) {
      _checkNetworkRefuseException(ex);
      return;
    } on Exception {
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

  Future<void> _checkProxySettings() async {
    if (Platform.isWindows == false) {
      // todo: implement other platforms
      return Future.value();
    }
    final localNetwork = await AppCmd.getLocalNetworkInfo();
    _localNetwork.value = localNetwork;
    final proxyResult = await AppCmd.getProxySettings();
    if (proxyResult.proxyEnabled) {
      _proxyServer = proxyResult.proxyServer;
    } else {
      _proxyServer = null;
    }
  }

  void _checkKerioBalance() async {
    final balance = await KerioUtils.getAccountBalance();
    var lowBalanceToastCount = await AppSharedPreferences.kerioLowBalanceToastCount;
    var lastToastDate = await AppSharedPreferences.kerioLowBalanceToastDate;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (lastToastDate == null || DateTime.parse(lastToastDate).isBefore(today)) {
      // New day, reset count
      lowBalanceToastCount = 0;
      await AppSharedPreferences.setKerioLowBalanceToastCount(0);
      await AppSharedPreferences.setKerioLowBalanceToastDate(today.toIso8601String());
    }

    if (balance.remaining < 1073741824 && lowBalanceToastCount < 2) {
      _showToast('Less than 1 GB is left in your kerio.dart account!');
      await AppSharedPreferences.setKerioLowBalanceToastCount(lowBalanceToastCount + 1);
      await AppSharedPreferences.setKerioLowBalanceToastDate(today.toIso8601String());
    }

    _kerioBalance.value = balance;
  }

  void _showToast(String title) {
    if (Platform.isWindows == false) {
      // todo: implement other platforms
      return;
    }
    WinToast.instance().showToast(type: ToastType.text01, title: title);
  }

  void _checkNetworkConnectivity() async {
    final result = await (Connectivity().checkConnectivity());
    if (result == ConnectivityResult.none) {
      setSystemTrayStatusToOffline();
    } else {
      setSystemTrayStatusToNetworkError();
      if (!_isPingingGoogle) {
        _pingGoogle();
      }
    }
  }

  void onConnectionTestClick() async {
    _downloadSpeed.value = 0;
    _uploadSpeed.value = 0;
    _speedTestStatus.value = 'Running';
    speedtest.getDataspeedtest(
      downloadOnProgress: ((percent, transferRate) {
        _downloadSpeed.value = transferRate;
      }),
      uploadOnProgress: ((percent, transferRate) {
        _uploadSpeed.value = transferRate;
      }),
      progressResponse: ((responseTime, jitter) {
        // nothing to do
      }),
      onError: ((errorMessage) {
        _downloadSpeed.value = 0;
        _uploadSpeed.value = 0;
        _speedTestStatus.value = 'Error';
      }),
      onDone: () {
        _speedTestStatus.value = 'Done';
      },
    );
  }

  void onExitClick() {
    destroySystemTray();
    exit(0);
  }

  void onRefreshButtonClick() async {
    _handleRefresh();
  }

  @override
  void onSystemTrayRefreshButtonClick() {
    _handleRefresh();
  }

  void _handleRefresh() async {
    await _checkProxySettings();
    _loginKerio(false);
    _checkPing();
    _pingGoogle();
    _checkIpLocation();
    _checkKerioBalance();
    _verifyLeakedSites();
  }

  void _updateCountryTrayIcon() async {
    final json = _ipLookupResult.valueOrNull;
    if (json == null) {
      return;
    }
    final country = json['country'];
    bool isIran = country == 'Iran';
    var tooltip = '';
    if (_foundALeakedSite) {
      tooltip = 'IRNet: $country (Leaked!)';
    } else {
      tooltip = 'IRNet: $country';
    }
    updateIconWhenCountryLoaded(_foundALeakedSite, isIran, tooltip);
    debugPrint('Country => $country');
  }
}
