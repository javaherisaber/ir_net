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
import 'package:rxdart/rxdart.dart';

import 'quality_bloc.dart';
import 'usage_bloc.dart';
import 'v2ray_bloc.dart';
import 'utils/kerio.dart';
import 'utils/notifier.dart';

class AppBloc with AppSystemTray {
  static const platform = MethodChannel('ir_net/system_events');

  final _latLng = StreamController<LatLng>();
  final _ipLookupResult = BehaviorSubject();
  // Broadcast so the leak-input field can re-subscribe each time the Leak
  // section is mounted (it is created/disposed on navigation).
  final _clearLeakInput = PublishSubject<void>();
  final _leakChecklist = BehaviorSubject<List<LeakItem>>();
  final _localNetwork = BehaviorSubject<LocalNetworksResult>();
  final _ping = BehaviorSubject<double?>();
  final _downloadSpeed = BehaviorSubject<double?>();
  final _uploadSpeed = BehaviorSubject<double?>();
  final _speedTestStatus = BehaviorSubject<String>();
  final _kerioBalance = BehaviorSubject<KerioBalance>();

  QualityBloc? _quality;
  UsageBloc? _usage;
  V2rayBloc? _v2ray;

  /// Network quality monitoring (probes are attributed to the public IP).
  QualityBloc get quality => _quality ??= QualityBloc(
        proxy: () => _effectiveProxy,
        onRecovered: () => _checkIpLocation(),
      );

  /// The V2Ray VPN.
  V2rayBloc get v2ray => _v2ray ??= V2rayBloc(onConnectionChanged: _onVpnChanged);

  @visibleForTesting
  set v2ray(V2rayBloc value) => _v2ray = value;

  /// IRNet's own requests follow the VPN's local proxy while it is connected
  /// (desktop proxy mode, and Android, where the tunnel excludes IRNet), else
  /// the Windows system proxy.
  String? get _effectiveProxy => _v2ray?.localProxy ?? _proxyServer;

  @visibleForTesting
  set quality(QualityBloc value) => _quality = value;

  /// Per-app / per-destination traffic.
  UsageBloc get usage => _usage ??= UsageBloc(httpClient: () => _client);

  @visibleForTesting
  set usage(UsageBloc value) => _usage = value;

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

  /// Creates the client for Kerio requests; tests swap in a fake.
  @visibleForTesting
  http.Client Function() kerioClient = http.Client.new;

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
    quality.initialize();
    usage.initialize();
    v2ray.initialize();
  }

  /// Re-checks IP, leaks and ping right after the VPN connects or drops.
  void _onVpnChanged() {
    quality.onNetworkChanged();
    _handleRefresh();
  }

  void _initializeNativeChannel() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onMacOsSleep'
          || call.method == 'onWindowsSleep'
          || call.method == 'onLinuxSleep') {
        await quality.onSleep();
      } else if (call.method == 'onMacOsWake' 
          || call.method == 'onWindowsWake' 
          || call.method == 'onLinuxWake') {
        quality.onWake();
        v2ray.onNetworkChanged();
        await Future.delayed(const Duration(seconds: 3));
        _handleRefresh();
      } else if (call.method == 'onIpChanged') {
        // Android: IpMonitor's lookups, also the ones it makes by itself when
        // the network or VPN changes.
        final args = call.arguments;
        if (args is Map && args['countryCode'] != null) {
          _applyIpLookup(Map<String, dynamic>.from(args));
        } else {
          _checkNetworkConnectivity();
        }
      } else if (call.method == 'onExitRequested') {
        // "Exit IRNet" in the Android notification.
        onExitClick();
      } else if (call.method == 'onDisconnectRequested') {
        // "Disconnect" in the Android notification while the VPN is on.
        await v2ray.disconnect();
      } else if (call.method == 'onConnectRequested') {
        // The "IRNet VPN" Quick Settings tile.
        await v2ray.connect();
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
    _clearLeakInput.add(null);
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
    await KerioUtils.login(client: kerioClient);
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
    final proxy = _effectiveProxy;
    if (proxy != null) {
      httpClient.findProxy = (uri) {
        return 'PROXY $proxy';
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
    Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> result) async {
      quality.onNetworkChanged();
      v2ray.onNetworkChanged();
      if (result.contains(ConnectivityResult.none)) {
        setSystemTrayStatusToOffline();
      } else {
        await _checkProxySettings();
        _checkIpLocation();
        _verifyLeakedSites();
        _checkPing();
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
      _checkIpLocation(force: false);
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

  /// Looks up where the traffic comes out. [force] skips a recent answer
  /// (Android reuses one under 15 s old for the periodic check).
  Future<void> _checkIpLocation({bool force = true}) async {
    if (Platform.isAndroid) return _requestAndroidIpLookup(force: force);
    http.Response response;
    try {
      final ipv4 = (await _client.get(Uri.parse("https://api.ipify.org"))).body;
      final uri = Uri.parse('http://ip-api.com/json/$ipv4?fields=8923');
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
    _applyIpLookup(jsonDecode(response.body));
  }

  void _applyIpLookup(dynamic json) {
    final lat = json['lat'], lon = json['lon'];
    if (lat is num && lon is num) {
      _latLng.sink.add(LatLng(lat.toDouble(), lon.toDouble()));
    }
    _ipLookupResult.value = json;
    quality.onIpLookup(json);
    _updateCountryTrayIcon();
  }

  /// On Android the lookup runs natively (IpMonitor.kt), which keeps the
  /// notification current even while the UI isn't running; the answer comes
  /// back as "onIpChanged". IRNet is outside its own VPN there, so lookups
  /// go through the VPN's local proxy while it's connected.
  Future<void> _requestAndroidIpLookup({required bool force}) async {
    try {
      final vpn = _v2ray?.value.connection;
      await platform.invokeMethod('lookupIp', {
        'proxy': _effectiveProxy,
        'maxAgeMs': force ? 0 : 15000,
        // Named in the notification while the VPN is connected.
        'vpnName': vpn != null && vpn.isConnected ? vpn.profileName : null,
      });
    } on PlatformException catch (e) {
      debugPrint('IP lookup request failed: $e');
    } on MissingPluginException catch (e) {
      debugPrint('IP lookup not available: $e');
    }
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
    final balance = await KerioUtils.getAccountBalance(client: kerioClient);
    if (balance == null) {
      // Not set up yet, or the server couldn't be reached.
      _kerioBalance.value = KerioBalance.none;
      return;
    }
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
      _showToast('Less than 1 GB is left in your Kerio account.', title: 'Kerio balance', id: 'kerio-low');
      await AppSharedPreferences.setKerioLowBalanceToastCount(lowBalanceToastCount + 1);
      await AppSharedPreferences.setKerioLowBalanceToastDate(today.toIso8601String());
    }

    _kerioBalance.value = balance;
  }

  void _showToast(String message, {String title = 'IRNet', String? id}) {
    AppNotifier.show(title, message, id: id);
  }

  void _checkNetworkConnectivity() async {
    final result = await (Connectivity().checkConnectivity());
    if (result.contains(ConnectivityResult.none)) {
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

  void onExitClick() async {
    destroySystemTray();
    _cancelAndroidNotification();
    _stopAndroidService();
    // Persist the last few seconds of quality / usage data, and put the
    // system proxy back (desktop) before the VPN core goes away with us.
    await Future.wait([
      Future.wait([quality.dispose(), usage.dispose()]).timeout(const Duration(seconds: 2), onTimeout: () => []),
      v2ray.dispose().timeout(const Duration(seconds: 8), onTimeout: () {}),
    ]);
    if (Platform.isAndroid) {
      // Also closes the task and the VPN's process.
      try {
        await platform.invokeMethod('exitApp');
        return;
      } catch (e) {
        debugPrint('Native exit failed: $e');
      }
    }
    exit(0);
  }

  void onRefreshButtonClick() async {
    _handleRefresh();
  }

  /// Applies a tray icon setting (country flag, leak status) right away instead
  /// of waiting for the next IP check.
  void onSysTrayIconSettingChanged() {
    _updateCountryTrayIcon();
  }

  @override
  void onSystemTrayRefreshButtonClick() {
    _handleRefresh();
  }

  @override
  void onSystemTrayExitButtonClick() => onExitClick();

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
    final countryCode = json['countryCode'];
    bool isIran = country == 'Iran';
    var tooltip = '';
    if (_foundALeakedSite) {
      tooltip = 'IRNet: $country (Leaked!)';
    } else {
      tooltip = 'IRNet: $country';
    }
    updateIconWhenCountryLoaded(_foundALeakedSite, isIran, countryCode, tooltip);
    debugPrint('Country => $country');
  }

  void _cancelAndroidNotification() {
    if (!Platform.isAndroid) return;
    try {
      platform.invokeMethod('cancelNotification');
    } on PlatformException catch (e) {
      debugPrint('Failed to cancel notification: $e');
    } on MissingPluginException catch (e) {
      debugPrint('Cancel notification plugin not available: $e');
    }
  }

  void _stopAndroidService() {
    if (!Platform.isAndroid) return;
    try {
      platform.invokeMethod('stopService');
    } on PlatformException catch (e) {
      debugPrint('Failed to stop service: $e');
    } on MissingPluginException catch (e) {
      debugPrint('Stop service plugin not available: $e');
    }
  }
}
