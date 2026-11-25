import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import 'v2ray/delay_tester.dart';
import 'v2ray/geo_assets.dart';
import 'utils/notifier.dart';
import 'v2ray/kill_switch.dart';
import 'v2ray/linux_tunnel_setup.dart';
import 'v2ray/mac_tunnel_helper.dart';
import 'v2ray/models.dart';
import 'v2ray/routing_rules.dart';
import 'v2ray/share_link.dart';
import 'v2ray/subscription.dart';
import 'v2ray/v2ray_store.dart';
import 'v2ray/vpn_engine.dart';
import 'v2ray/windows_tunnel_task.dart';
import 'v2ray/xray_runner.dart';

export 'v2ray/models.dart';

/// Outcome of an import (clipboard, QR code, typed link).
class ImportResult {
  ImportResult({
    this.added = 0,
    this.duplicates = 0,
    this.unsupported = 0,
    this.subscriptions = const [],
    this.errors = const [],
  });

  final int added;
  final int duplicates;
  final int unsupported;

  /// Names of subscriptions added or refreshed, with their config counts.
  final List<({String name, int configs})> subscriptions;
  final List<String> errors;

  bool get isEmpty => added == 0 && subscriptions.isEmpty;

  String get message {
    final parts = <String>[];
    for (final s in subscriptions) {
      parts.add('Added subscription “${s.name}” (${s.configs} config${s.configs == 1 ? '' : 's'})');
    }
    if (added > 0) parts.add('Added $added config${added == 1 ? '' : 's'}');
    if (duplicates > 0) parts.add('$duplicates already in the list');
    if (unsupported > 0) parts.add('$unsupported skipped (only VLESS, VMess, Trojan and WireGuard are supported)');
    if (errors.isNotEmpty) parts.add(errors.first);
    if (parts.isEmpty) return 'No VLESS, VMess, Trojan or WireGuard config or subscription link found';
    return parts.join(' · ');
  }
}

/// V2Ray (Xray) VPN: configs, subscriptions, delay tests, routing rules,
/// geo assets and the connection.
class V2rayBloc {
  V2rayBloc({
    VpnEngine? engine,
    V2rayStore? store,
    this.onConnectionChanged,
    SubscriptionClient? subscriptionClient,
    KillSwitch? Function()? killSwitch,
    Future<void> Function()? waitForNetwork,
    http.Client Function()? httpClient,
  })  : _store = store ?? V2rayStore(),
        _httpClientOverride = httpClient,
        _engineOverride = engine,
        _subscriptionClient = subscriptionClient,
        _killSwitchFactory = killSwitch ?? KillSwitch.forPlatform,
        _waitForNetwork = waitForNetwork ?? _defaultWaitForNetwork;

  final V2rayStore _store;
  final VpnEngine? _engineOverride;
  final KillSwitch? Function() _killSwitchFactory;
  final Future<void> Function() _waitForNetwork;
  KillSwitch? _killSwitchInstance;
  Map<String, dynamic>? _cutState;
  VpnEngine? _engine;
  SubscriptionClient? _subscriptionClient;

  /// Called after connecting / disconnecting, so the app re-checks its IP.
  final VoidCallback? onConnectionChanged;

  final _state = BehaviorSubject<V2rayState>.seeded(const V2rayState());
  StreamSubscription<EngineEvent>? _engineEvents;
  DelayTester? _tester;
  Timer? _refreshTimer;
  Timer? _healthTimer;
  Timer? _activeTimer;
  Timer? _reconnectTimer;
  Future<void> _queue = Future.value();
  bool _initialized = false;

  /// Health checks that failed in a row.
  int _healthFailures = 0;

  /// Reconnect attempts after the connection dropped.
  int _reconnectAttempts = 0;

  /// The configs of the current Auto connection, in outbound order.
  List<V2rayProfile> _autoProfiles = const [];

  /// Time between automatic reconnect attempts after a drop.
  @visibleForTesting
  static List<Duration> reconnectDelays = const [Duration(seconds: 3), Duration(seconds: 10), Duration(seconds: 30)];

  VpnEngine get engine => _engine ??= _engineOverride ?? VpnEngine.forPlatform(_store);

  Stream<V2rayState> get state => _state.stream;
  V2rayState get value => _state.value;

  /// HTTP proxy for IRNet's own requests while connected, else null.
  String? get localProxy => value.connection.isConnected ? value.connection.httpProxy : null;

  /// SOCKS5 proxy for IRNet's UDP probes while connected (Android Tunnel
  /// mode), so they measure the VPN's UDP path.
  String? get udpProxy => value.connection.isConnected ? value.connection.udpProxy : null;

  SubscriptionClient get _subscriptions => _subscriptionClient ??= SubscriptionClient(httpClient: _httpClient);

  final http.Client Function()? _httpClientOverride;

  http.Client _httpClient() {
    if (_httpClientOverride != null) return _httpClientOverride();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final proxy = localProxy;
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    return IOClient(client);
  }

  void _emit(V2rayState s) {
    if (!_state.isClosed) _state.add(s);
  }

  Future<void> _save() => _store.save(value);

  /// Runs [task] after any connect/disconnect in progress.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final snap = await _store.load();
    _emit(value.copyWith(
      loaded: true,
      profiles: snap.profiles,
      subscriptions: snap.subscriptions,
      selectedId: snap.selectedId,
      delays: snap.delays,
      settings: snap.settings,
      assets: snap.assets,
      unsupportedReason: engine.unsupportedReason,
      defaultMode: engine.defaultMode,
    ));
    _cutState = await _store.loadNetworkCut();
    if (_cutState != null) _emit(value.copyWith(networkCut: true));
    _engineEvents = engine.events.listen(_onEngineEvent);
    try {
      await engine.recover();
    } catch (e) {
      debugPrint('V2Ray: recovery failed: $e');
    }
    if (!kIsWeb && Platform.isAndroid) unawaited(_removePluginGeoCopies());
    final iranUpdated = await _store.loadIranRulesUpdated();
    if (iranUpdated != null) _emit(value.copyWith(iranRules: IranRulesStatus(updatedAt: iranUpdated)));
    // The VPN isn't connected at launch: the kill switch keeps the network off.
    unawaited(_serial(_enforceKillSwitch));
    if (value.settings.connectOnLaunch && value.unsupportedReason == null) {
      // After a moment, so an Android VPN that is still running reports in first.
      unawaited(Future.delayed(launchConnectDelay, () {
        if (_state.isClosed) return;
        final c = value.connection;
        if (!c.isConnected && !c.isBusy && value.profiles.isNotEmpty) connect();
      }));
    }
    // Refresh stale subscriptions (and the Iran rules, weekly) shortly after
    // launch, then hourly; warn about expiring subscriptions.
    _refreshTimer = Timer.periodic(const Duration(hours: 1), (_) => _hourly());
    unawaited(Future.delayed(const Duration(seconds: 5), _hourly));
  }

  @visibleForTesting
  static Duration launchConnectDelay = const Duration(seconds: 3);

  Future<void> _hourly() async {
    if (_state.isClosed) return;
    await refreshStaleSubscriptions();
    final updated = value.iranRules.updatedAt;
    if (value.settings.iranDirect &&
        (updated == null || DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(updated)).inDays >= 7)) {
      await updateIranRules();
    }
    await checkSubscriptionAlerts();
  }

  Future<void> dispose() async {
    _refreshTimer?.cancel();
    _healthTimer?.cancel();
    _activeTimer?.cancel();
    _reconnectTimer?.cancel();
    _tester?.cancel();
    if (value.connection.phase != ConnectionPhase.disconnected) {
      try {
        await engine.disconnect();
      } catch (_) {}
      _emit(value.copyWith(connection: V2rayConnection.idle));
    }
    // Quitting leaves no VPN running, so the kill switch turns the network off.
    await _enforceKillSwitch();
    await _engineEvents?.cancel();
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case EngineStopped(:final error):
        if (value.connection.phase == ConnectionPhase.disconnected) return;
        final dropped = value.connection;
        _stopWatching();
        _emit(value.copyWith(
          connection: V2rayConnection(
            phase: error == null ? ConnectionPhase.disconnected : ConnectionPhase.failed,
            profileId: value.connection.profileId,
            profileName: value.connection.profileName,
            error: error,
          ),
        ));
        onConnectionChanged?.call();
        unawaited(_serial(_enforceKillSwitch));
        _afterDrop(dropped, error);
      case EngineTraffic():
        if (!value.connection.isConnected) return;
        _emit(value.copyWith(
          connection: value.connection.withTraffic(
            uploadSpeed: event.uploadSpeed,
            downloadSpeed: event.downloadSpeed,
            uploaded: event.uploaded,
            downloaded: event.downloaded,
          ),
        ));
      case EngineResumed(:final profileId, :final session):
        _emit(value.copyWith(
          selectedId: profileId,
          connection: V2rayConnection(
            phase: ConnectionPhase.connected,
            profileId: profileId,
            profileName: value.profileById(profileId)?.name,
            since: DateTime.now(),
            httpProxy: session.httpProxy,
            udpProxy: session.udpProxy,
            systemProxy: session.systemProxy,
            mode: value.mode,
          ),
        ));
        _startWatching();
        onConnectionChanged?.call();
        unawaited(_serial(_enforceKillSwitch));
    }
  }

  // ───────────────────────────── health & reconnect ─────────────────────────────

  void _startWatching() {
    _healthFailures = 0;
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) => checkHealth());
    _activeTimer?.cancel();
    if (_autoProfiles.length > 1) {
      _activeTimer = Timer.periodic(const Duration(seconds: 4), (_) => refreshActive());
    }
  }

  void _stopWatching() {
    _healthTimer?.cancel();
    _activeTimer?.cancel();
  }

  /// In Auto: which config the core is on right now (where it says).
  @visibleForTesting
  void refreshActive() {
    final c = value.connection;
    if (!c.isConnected) return;
    final tag = engine.activeOutboundTag;
    final index = tag == null ? null : int.tryParse(tag.substring('proxy-'.length));
    final id = index != null && index < _autoProfiles.length ? _autoProfiles[index].id : null;
    if (id != null && id != c.activeProfileId) _emit(value.copyWith(connection: c.withActive(id)));
  }

  /// A request through the VPN; two failures in a row reconnect it.
  Future<void> checkHealth() async {
    final c = value.connection;
    if (!c.isConnected || !value.settings.autoReconnect) return;
    if (await engine.probe()) {
      _healthFailures = 0;
      return;
    }
    if (!value.connection.isConnected || ++_healthFailures < 2) return;
    _healthFailures = 0;
    _notify('VPN not responding', 'Reconnecting to ${c.profileName ?? 'the server'}…', id: 'vpn-state');
    await connect(c.profileId);
  }

  // ───────────────────────────── stop on sleep ─────────────────────────────

  /// The connection "Stop on sleep" took down, to bring back on wake.
  String? _sleepResumeId;

  @visibleForTesting
  static List<Duration> wakeRetryDelays = const [Duration(seconds: 5), Duration(seconds: 15)];

  /// The computer is going to sleep ("Stop on sleep" on): disconnect, and
  /// remember to reconnect on wake. Not a drop, so no notification.
  Future<void> stopForSleep() async {
    final c = value.connection;
    if (!c.isConnected && c.phase != ConnectionPhase.connecting) return;
    _sleepResumeId = c.profileId;
    await disconnect();
  }

  /// Woke up: reconnect what [stopForSleep] stopped, once the network is
  /// back, unless the user connected or disconnected meanwhile.
  Future<void> resumeAfterSleep() async {
    final id = _sleepResumeId;
    _sleepResumeId = null;
    if (id == null) return;
    // With the kill switch's network cut, connecting turns it back on itself.
    if (!value.networkCut) await _waitForNetwork();
    for (var attempt = 0;; attempt++) {
      final c = value.connection;
      if (c.isConnected || c.isBusy) return;
      await connect(id);
      if (value.connection.isConnected) return;
      if (attempt >= wakeRetryDelays.length) break;
      await Future<void>.delayed(wakeRetryDelays[attempt]);
      // The user dealt with it (disconnected, picked another config).
      if (value.connection.phase != ConnectionPhase.failed) return;
    }
    _notify('VPN not reconnected', 'Couldn\'t reconnect after sleep: ${value.connection.error ?? 'unknown error'}',
        id: 'vpn-state');
  }

  /// After sleep or a network change: check the connection soon, and
  /// reconnect on the first failure.
  void onNetworkChanged() {
    if (!value.connection.isConnected) return;
    _healthFailures = 1;
    Future.delayed(const Duration(seconds: 5), checkHealth);
  }

  void _afterDrop(V2rayConnection dropped, String? error) {
    final name = dropped.profileName ?? 'the VPN';
    if (!value.settings.autoReconnect || _reconnectAttempts >= reconnectDelays.length) {
      _reconnectAttempts = 0;
      _notify('VPN disconnected', error == null ? '$name stopped.' : '$name stopped: $error',
          id: 'vpn-state');
      return;
    }
    final delay = reconnectDelays[_reconnectAttempts++];
    if (_reconnectAttempts == 1) {
      _notify('VPN disconnected', 'Reconnecting to $name…', id: 'vpn-state');
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      final c = value.connection;
      if (c.isConnected || c.isBusy) return;
      await _connect(dropped.profileId, reconnecting: true);
      if (value.connection.isConnected) {
        _reconnectAttempts = 0;
        _notify('VPN reconnected', 'Connected to ${value.connection.profileName ?? name}.', id: 'vpn-state');
      } else {
        _afterDrop(dropped, value.connection.error);
      }
    });
  }

  void _notify(String title, String body, {String? id}) {
    if (value.settings.notify) unawaited(AppNotifier.show(title, body, id: id));
  }

  /// Warns (at most once a day each) when a subscription is about to expire,
  /// has expired, or is low on data.
  Future<void> checkSubscriptionAlerts() async {
    if (!value.settings.notify) return;
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    final sent = await _store.loadNotified();
    var changed = false;
    void once(String key, String title, String body) {
      if (sent[key] == today) return;
      sent[key] = today;
      changed = true;
      _notify(title, body, id: key);
    }

    for (final sub in value.subscriptions) {
      final u = sub.usage;
      if (u == null) continue;
      final left = u.timeLeft(now);
      if (u.isExpired(now)) {
        once('expired:${sub.id}', 'Subscription expired', '${sub.title} has expired. Renew it to keep using its servers.');
      } else if (left != null && left.inHours < 72) {
        final days = left.inHours < 24 ? 'less than a day' : '${(left.inHours / 24).ceil()} days';
        once('expiring:${sub.id}', 'Subscription expiring', '${sub.title} expires in $days.');
      }
      if (!u.isUnlimited && (u.remaining < 1024 * 1024 * 1024 || u.remainingFraction < 0.1)) {
        once('lowdata:${sub.id}', 'Subscription data low', 'Only ${_bytes(u.remaining)} left on ${sub.title}.');
      }
    }
    if (changed) await _store.saveNotified(sent);
  }

  static String _bytes(int b) {
    const gb = 1024 * 1024 * 1024;
    return b >= gb ? '${(b / gb).toStringAsFixed(1)} GB' : '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  // ───────────────────────────── import ─────────────────────────────

  /// Share links, base64 blobs, WireGuard configs ([Interface]/[Peer] text),
  /// subscription URLs and import deep links (hiddify://import/…,
  /// v2box://install-sub?url=…, happ://add/…). [nameHint] names a WireGuard
  /// config that has none (its .conf file's name).
  Future<ImportResult> importText(String text, {String? nameHint}) async {
    final subscriptionUrls = <({String url, String? name})>[];
    final rest = <String>[];
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final sub = subscriptionLinkOf(line);
      if (sub != null) {
        subscriptionUrls.add(sub);
      } else {
        rest.add(line);
      }
    }

    var added = 0, duplicates = 0, unsupported = 0;
    final errors = <String>[];
    if (rest.isNotEmpty) {
      final parsed = ShareLinkParser.parseText(rest.join('\n'), nameHint: nameHint);
      unsupported = parsed.unsupported;
      errors.addAll(parsed.errors);
      final known = value.profiles.map((p) => p.id).toSet();
      final fresh = <V2rayProfile>[];
      for (final p in parsed.profiles) {
        if (known.contains(p.id)) {
          duplicates++;
        } else {
          fresh.add(p);
          known.add(p.id);
        }
      }
      if (fresh.isNotEmpty) {
        added = fresh.length;
        _emit(value.copyWith(
          profiles: [...value.profiles, ...fresh],
          selectedId: value.selectedId ?? fresh.firstWhere((p) => p.isUsable, orElse: () => fresh.first).id,
        ));
        await _save();
      }
    }

    final subs = <({String name, int configs})>[];
    for (final s in subscriptionUrls) {
      try {
        final sub = await addSubscription(s.url, name: s.name);
        subs.add((name: sub.title, configs: value.profilesOf(sub.id).length));
      } on SubscriptionException catch (e) {
        errors.add(e.message);
      }
    }
    return ImportResult(
      added: added,
      duplicates: duplicates,
      unsupported: unsupported,
      subscriptions: subs,
      errors: errors,
    );
  }

  /// The subscription URL (and optional name) in [line], when it is one:
  /// a plain http(s) URL or another client's import deep link.
  static ({String url, String? name})? subscriptionLinkOf(String line) {
    final lower = line.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return Uri.tryParse(line)?.host.isNotEmpty == true ? (url: line, name: null) : null;
    }
    if (ShareLinkParser.isShareLink(line) || !line.contains('://')) return null;
    final uri = Uri.tryParse(line);
    // ?url=… (v2box/v2rayng/clash/sing-box/hiddify install-config / install-sub)
    final query = uri?.queryParameters;
    final fromQuery = query?['url'];
    if (fromQuery != null && fromQuery.startsWith('http')) {
      final name = query?['name'] ?? (uri!.fragment.isEmpty ? null : uri.fragment);
      return (url: fromQuery, name: name);
    }
    // hiddify://import/<url>#name, happ://add/<url>
    final start = lower.indexOf('http', lower.indexOf('://') + 3);
    if (start < 0) return null;
    var url = line.substring(start);
    String? name;
    final hash = url.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(url.substring(hash + 1).split('?').first);
      url = url.substring(0, hash);
    }
    if (!url.contains('://')) {
      try {
        url = Uri.decodeComponent(url);
      } catch (_) {}
    }
    return Uri.tryParse(url)?.host.isNotEmpty == true ? (url: url, name: name?.isEmpty == true ? null : name) : null;
  }

  // ───────────────────────────── subscriptions ─────────────────────────────

  /// Adds (or, for a URL already added, refreshes) a subscription.
  Future<V2raySubscription> addSubscription(String url, {String? name}) async {
    final existing = value.subscriptions.where((s) => s.url == url.trim()).firstOrNull;
    if (existing != null) {
      await updateSubscription(existing.id, rethrowErrors: true);
      return value.subscriptionById(existing.id)!;
    }
    final id = sha1.convert(utf8.encode(url.trim())).toString().substring(0, 12);
    final result = await _subscriptions.fetch(url, subscriptionId: id);
    final sub = V2raySubscription(
      id: id,
      url: url.trim(),
      name: result.meta.title ?? SubscriptionClient.fallbackName(url),
      customName: name,
      usage: result.meta.usage,
      updateIntervalHours: result.meta.updateIntervalHours,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      supportUrl: result.meta.supportUrl,
      webPageUrl: result.meta.webPageUrl,
      announce: result.meta.announce,
    );
    final profiles = result.links.profiles;
    _emit(value.copyWith(
      subscriptions: [...value.subscriptions, sub],
      profiles: [...value.profiles, ...profiles],
      selectedId: value.selectedId ??
          profiles.where((p) => p.isUsable).map((p) => p.id).firstOrNull,
    ));
    await _save();
    return sub;
  }

  Future<void> updateSubscription(String id, {bool rethrowErrors = false}) async {
    final sub = value.subscriptionById(id);
    if (sub == null || value.updating.contains(id)) return;
    _emit(value.copyWith(updating: {...value.updating, id}));
    try {
      final result = await _subscriptions.fetch(sub.url, subscriptionId: id);
      final current = value.subscriptionById(id);
      if (current == null) return; // removed meanwhile
      final fresh = result.links.profiles;
      final freshIds = fresh.map((p) => p.id).toSet();
      final others = value.profiles.where((p) => p.subscriptionId != id).toList();
      final delays = Map.of(value.delays)
        ..removeWhere((k, _) => value.profileById(k)?.subscriptionId == id && !freshIds.contains(k));
      _emit(value.copyWith(
        profiles: [...others, ...fresh],
        delays: delays,
        subscriptions: [
          for (final s in value.subscriptions)
            if (s.id == id)
              s.copyWith(
                name: result.meta.title ?? s.name,
                usage: result.meta.usage,
                clearUsage: result.meta.usage == null,
                updateIntervalHours: result.meta.updateIntervalHours,
                lastUpdated: DateTime.now().millisecondsSinceEpoch,
                clearError: true,
                supportUrl: result.meta.supportUrl,
                webPageUrl: result.meta.webPageUrl,
                announce: result.meta.announce,
              )
            else
              s,
        ],
      ));
    } on SubscriptionException catch (e) {
      _emit(value.copyWith(subscriptions: [
        for (final s in value.subscriptions) s.id == id ? s.copyWith(lastError: e.message) : s,
      ]));
      if (rethrowErrors) rethrow;
    } finally {
      _emit(value.copyWith(updating: value.updating.difference({id})));
      await _save();
    }
  }

  Future<void> updateAllSubscriptions() async {
    await Future.wait(value.subscriptions.map((s) => updateSubscription(s.id)));
  }

  Future<void> refreshStaleSubscriptions() async {
    final now = DateTime.now();
    for (final s in value.subscriptions.where((s) => s.isStale(now)).toList()) {
      await updateSubscription(s.id);
    }
  }

  Future<void> renameSubscription(String id, String name) async {
    _emit(value.copyWith(subscriptions: [
      for (final s in value.subscriptions)
        if (s.id == id)
          name.trim().isEmpty ? s.copyWith(clearCustomName: true) : s.copyWith(customName: name.trim())
        else
          s,
    ]));
    await _save();
  }

  Future<void> removeSubscription(String id) async {
    final removed = value.profilesOf(id).map((p) => p.id).toSet();
    _emit(value.copyWith(
      subscriptions: value.subscriptions.where((s) => s.id != id).toList(),
      profiles: value.profiles.where((p) => p.subscriptionId != id).toList(),
      delays: Map.of(value.delays)..removeWhere((k, _) => removed.contains(k)),
      clearSelected: removed.contains(value.selectedId) || value.selectedId == AutoSelect.idFor(id),
    ));
    await _save();
    await _store.forgetQuickConnect(removed);
  }

  Future<void> removeProfile(String id) async {
    _emit(value.copyWith(
      profiles: value.profiles.where((p) => p.id != id).toList(),
      delays: Map.of(value.delays)..remove(id),
      clearSelected: value.selectedId == id,
    ));
    await _save();
    await _store.forgetQuickConnect({id});
  }

  // ───────────────────────────── delay tests ─────────────────────────────

  Future<void> testProfiles(List<V2rayProfile> profiles, {bool all = false}) async {
    if (profiles.isEmpty) return;
    if (value.testingAll && all) return;
    final ids = profiles.map((p) => p.id).toSet();
    _emit(value.copyWith(testing: {...value.testing, ...ids}, testingAll: all || value.testingAll));
    final tester = DelayTester(runner: engine.testRunner, bindInterface: engine.testInterface);
    if (all) _tester = tester;
    try {
      await tester.run(profiles, (id, result) {
        _emit(value.copyWith(
          delays: {...value.delays, id: result},
          testing: value.testing.difference({id}),
        ));
      });
    } finally {
      _emit(value.copyWith(
        testing: value.testing.difference(ids),
        testingAll: all ? false : value.testingAll,
      ));
      if (all) _tester = null;
      await _save();
    }
  }

  Future<void> testProfile(String id) async {
    final p = value.profileById(id);
    if (p != null && !value.testing.contains(id)) await testProfiles([p]);
  }

  /// Tests every config, or those of one group ([groupId]: a subscription
  /// id, or [manualGroup] for configs added on their own).
  Future<void> testAll({String? groupId}) {
    final profiles = groupId == null
        ? value.profiles
        : value.profiles.where((p) => (p.subscriptionId ?? manualGroup) == groupId).toList();
    return testProfiles(profiles, all: true);
  }

  void cancelTests() => _tester?.cancel();

  static const manualGroup = '_manual';

  /// The lowest successful delay among [profiles] (or all), if any was tested.
  V2rayProfile? fastest([Iterable<V2rayProfile>? profiles]) {
    V2rayProfile? best;
    int? bestMs;
    for (final p in profiles ?? value.profiles) {
      final ms = value.delays[p.id]?.ms;
      if (!p.isUsable || ms == null) continue;
      if (bestMs == null || ms < bestMs) {
        best = p;
        bestMs = ms;
      }
    }
    return best;
  }

  // ───────────────────────────── connection ─────────────────────────────

  Future<void> select(String id) async {
    if (!AutoSelect.isAuto(id) && value.profileById(id) == null) return;
    final c = value.connection;
    _emit(value.copyWith(selectedId: id));
    await _save();
    if ((c.isConnected || c.phase == ConnectionPhase.connecting) && c.profileId != id) {
      await connect(id);
    }
  }

  Future<void> toggle() {
    final phase = value.connection.phase;
    if (phase == ConnectionPhase.connected || phase == ConnectionPhase.connecting) return disconnect();
    return connect();
  }

  /// The configs of a group's Auto entry: usable ones, fastest first
  /// (untested next, failed last), at most [AutoSelect.maxServers].
  List<V2rayProfile> autoCandidates(String groupId) {
    int rank(V2rayProfile p) {
      final r = value.delays[p.id];
      if (r == null) return 1 << 28;
      return r.ms ?? (1 << 29);
    }

    final list = value.profiles
        .where((p) => p.isUsable && (p.subscriptionId ?? manualGroup) == groupId)
        .toList()
      ..sort((a, b) => rank(a).compareTo(rank(b)));
    return list.take(AutoSelect.maxServers).toList();
  }

  /// "Auto · Fast VPN" for an Auto id.
  String autoName(String groupId) =>
      'Auto · ${groupId == manualGroup ? 'My configs' : (value.subscriptionById(groupId)?.title ?? 'Subscription')}';

  Future<void> connect([String? id]) => _connect(id, reconnecting: false);

  Future<void> _connect(String? id, {required bool reconnecting}) => _serial(() async {
        if (!reconnecting) {
          _reconnectTimer?.cancel();
          _reconnectAttempts = 0;
        }
        final wanted = id ?? value.selectedId;
        final String targetId;
        final String targetName;
        final List<V2rayProfile> profiles;
        final group = AutoSelect.groupOf(wanted);
        if (group != null) {
          targetId = wanted!;
          targetName = autoName(group);
          profiles = autoCandidates(group);
          if (profiles.isEmpty) {
            _fail(targetId, targetName, 'No usable configs in this group to choose from');
            return;
          }
        } else {
          final target = value.profileById(wanted) ?? fastest() ?? value.profiles.where((p) => p.isUsable).firstOrNull;
          if (target == null) {
            _fail(null, null, 'Add a config first');
            return;
          }
          if (!target.isUsable) {
            _fail(target.id, target.name, target.problem!);
            return;
          }
          targetId = target.id;
          targetName = target.name;
          profiles = [target];
        }
        if (value.unsupportedReason != null) {
          _fail(targetId, targetName, value.unsupportedReason!);
          return;
        }
        final mode = value.mode;
        _stopWatching();
        _emit(value.copyWith(
          selectedId: targetId,
          connection: V2rayConnection(
              phase: ConnectionPhase.connecting, profileId: targetId, profileName: targetName, mode: mode),
        ));
        unawaited(_save());
        try {
          // The kill switch has the network off: bring it back just to connect.
          if (value.networkCut) {
            await _restoreNetwork();
            if (value.networkCut) throw VpnException(value.killSwitchError ?? 'The network is still off');
            await _waitForNetwork();
          }
          final s = value.settings;
          final session = await engine.connect(
            profiles,
            ConnectOptions(
              mode: mode,
              bypassLan: s.bypassLan,
              rules: compiledRules,
              fragment: s.fragment ? s.fragmentOptions : null,
              bypassApps: s.bypassApps,
            ),
          );
          _autoProfiles = profiles.length > 1 ? profiles : const [];
          _emit(value.copyWith(
            connection: V2rayConnection(
              phase: ConnectionPhase.connected,
              profileId: targetId,
              profileName: targetName,
              since: DateTime.now(),
              httpProxy: session.httpProxy,
              udpProxy: session.udpProxy,
              systemProxy: session.systemProxy,
              note: session.note,
              mode: mode,
            ),
          ));
          _startWatching();
        } catch (e) {
          _fail(targetId, targetName, e is VpnException ? e.message : e.toString());
        }
        onConnectionChanged?.call();
        await _enforceKillSwitch();
      });

  void _fail(String? id, String? name, String error) {
    _emit(value.copyWith(
      connection: V2rayConnection(phase: ConnectionPhase.failed, profileId: id, profileName: name, error: error),
    ));
  }

  Future<void> disconnect() => _serial(() async {
        _reconnectTimer?.cancel();
        _reconnectAttempts = 0;
        _stopWatching();
        if (value.connection.phase == ConnectionPhase.disconnected) return;
        final c = value.connection;
        _emit(value.copyWith(
          connection: V2rayConnection(
              phase: ConnectionPhase.disconnecting, profileId: c.profileId, profileName: c.profileName),
        ));
        try {
          await engine.disconnect();
        } catch (e) {
          debugPrint('V2Ray: disconnect failed: $e');
        }
        _emit(value.copyWith(connection: V2rayConnection.idle));
        onConnectionChanged?.call();
        await _enforceKillSwitch();
      });

  /// Re-applies settings to a live connection.
  Future<void> _reconnectIfConnected() async {
    final c = value.connection;
    if (c.isConnected && c.profileId != null) await connect(c.profileId);
  }

  // ───────────────────────────── mode & kill switch ─────────────────────────────

  Future<void> setMode(VpnMode mode) async {
    if (mode == value.mode && value.settings.mode != null) return;
    _emit(value.copyWith(settings: value.settings.copyWith(mode: mode)));
    await _save();
    await _reconnectIfConnected();
  }

  /// Tunnel mode's one-time setup is in place on this computer, so it
  /// connects without a password or UAC prompt.
  bool get tunnelSetupInstalled {
    if (kIsWeb) return false;
    if (Platform.isMacOS) return MacTunnelHelper.isInstalled;
    if (Platform.isWindows) return File('${WindowsTunnelTask().programDir}\\VERSION').existsSync();
    if (Platform.isLinux) return File(LinuxTunnelSetup.xrayPath).existsSync();
    return false;
  }

  /// Undoes Tunnel mode's one-time setup (one prompt). Returns an error
  /// message, or null.
  Future<String?> removeTunnelSetup() async {
    if (value.connection.isConnected && value.connection.mode == VpnMode.tunnel) await disconnect();
    try {
      if (Platform.isMacOS) await MacTunnelHelper().uninstall();
      if (Platform.isWindows) await WindowsTunnelTask().uninstall();
      if (Platform.isLinux) await LinuxTunnelSetup().uninstall();
      return null;
    } on XrayStartException catch (e) {
      return e.message;
    }
  }

  KillSwitch? get _killSwitch => _killSwitchInstance ??= _killSwitchFactory();

  /// Whether this platform can turn the network off itself (Android has its
  /// own "Block connections without VPN" instead).
  bool get killSwitchSupported => _killSwitch != null;

  Future<void> setKillSwitch(bool enabled) async {
    _emit(value.copyWith(settings: value.settings.copyWith(killSwitch: enabled), clearKillSwitchError: true));
    await _save();
    await _serial(_enforceKillSwitch);
  }

  /// Network off while the kill switch is on and the VPN isn't up (or on its
  /// way up); back on once the kill switch is turned off.
  Future<void> _enforceKillSwitch() async {
    final c = value.connection;
    final up = c.isConnected || c.isBusy;
    if (value.settings.killSwitch && !up && !value.networkCut) {
      await _cutNetwork();
    } else if (!value.settings.killSwitch && value.networkCut) {
      await _restoreNetwork();
    }
  }

  Future<void> _cutNetwork() async {
    final ks = _killSwitch;
    if (ks == null) return;
    try {
      final state = await ks.cut();
      _cutState = state;
      await _store.saveNetworkCut(state);
      _emit(value.copyWith(networkCut: true, clearKillSwitchError: true));
    } catch (e) {
      _emit(value.copyWith(killSwitchError: 'Couldn\'t turn the network off: ${e is KillSwitchException ? e.message : e}'));
    }
  }

  Future<void> _restoreNetwork() async {
    final ks = _killSwitch;
    if (ks == null) return;
    try {
      await ks.restore(_cutState ?? const {});
      _cutState = null;
      await _store.saveNetworkCut(null);
      _emit(value.copyWith(networkCut: false, clearKillSwitchError: true));
    } catch (e) {
      _emit(value.copyWith(killSwitchError: 'Couldn\'t turn the network back on: ${e is KillSwitchException ? e.message : e}'));
    }
  }

  /// After turning adapters back on: until an interface has a routable
  /// IPv4 address (Wi-Fi joined, DHCP done), at most 25 s.
  static Future<void> _defaultWaitForNetwork() async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        final up = interfaces.any((i) => i.addresses.any((a) => !a.isLoopback && !a.isLinkLocal));
        if (up) {
          await Future<void>.delayed(const Duration(seconds: 2));
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  // ───────────────────────────── routing ─────────────────────────────

  Future<void> setBypassLan(bool bypass) async {
    _emit(value.copyWith(settings: value.settings.copyWith(bypassLan: bypass)));
    await _save();
    await _reconnectIfConnected();
  }

  /// Saves pass-through rules (one per line) and reconnects to apply them.
  Future<CompiledRules> setRules(String text) async {
    final lines = PassThroughRules.splitLines(text);
    _emit(value.copyWith(settings: value.settings.copyWith(rules: lines)));
    await _save();
    await _reconnectIfConnected();
    return _compiledUserRules;
  }

  /// The user's rules, plus the Iran preset's when it is on.
  CompiledRules get compiledRules => PassThroughRules.compile(
      [...value.settings.rules, if (value.settings.iranDirect) ...iranRuleLines], value.assets);

  Future<void> _updateSettings(V2raySettings settings, {bool reconnect = false}) async {
    _emit(value.copyWith(settings: settings));
    await _save();
    if (reconnect) await _reconnectIfConnected();
  }

  Future<void> setFragment(bool on) => _updateSettings(value.settings.copyWith(fragment: on), reconnect: true);

  Future<void> setFragmentOptions(FragmentOptions options) =>
      _updateSettings(value.settings.copyWith(fragmentOptions: options), reconnect: value.settings.fragment);

  Future<void> setBypassApps(List<String> apps) =>
      _updateSettings(value.settings.copyWith(bypassApps: apps), reconnect: true);

  Future<void> setConnectOnLaunch(bool on) => _updateSettings(value.settings.copyWith(connectOnLaunch: on));

  Future<void> setAutoReconnect(bool on) => _updateSettings(value.settings.copyWith(autoReconnect: on));

  Future<void> setNotify(bool on) => _updateSettings(value.settings.copyWith(notify: on));

  /// Earlier Android builds let flutter_v2ray copy its bundled geoip.dat and
  /// geosite.dat (27 MB) into the geo files folder on every start. IRNet
  /// never used them; remove them unless the user imported files by those
  /// names (theirs may have been replaced, but they're still theirs to keep).
  Future<void> _removePluginGeoCopies() async {
    try {
      final dir = await engine.assetDirectory();
      if (dir != null) await removeUntrackedGeoFiles(dir, value.assets.map((a) => a.fileName));
    } catch (e) {
      debugPrint('V2Ray: geo cleanup failed: $e');
    }
  }

  @visibleForTesting
  static Future<List<String>> removeUntrackedGeoFiles(Directory dir, Iterable<String> imported) async {
    final keep = imported.toSet();
    final removed = <String>[];
    for (final name in const ['geoip.dat', 'geosite.dat', 'geoip-only-cn-private.dat']) {
      if (keep.contains(name)) continue;
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        await file.delete();
        removed.add(name);
      }
    }
    return removed;
  }

  // ───────────────────────────── Iranian sites go direct ─────────────────────────────

  /// Curated Iran rule files (Chocolate4U/Iran-v2ray-rules, "lite" builds:
  /// geoip ir/private, geosite ir/category-ir/ads), saved under their own
  /// names so they never replace the user's geoip.dat / geosite.dat.
  static const iranFiles = {'iran-geoip.dat': 'geoip-lite.dat', 'iran-geosite.dat': 'geosite-lite.dat'};
  static const iranRuleLines = ['ext:iran-geosite.dat:ir', 'ext:iran-geoip.dat:ir'];
  static const _iranSources = [
    'https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/',
    'https://cdn.jsdelivr.net/gh/chocolate4u/Iran-v2ray-rules@release/',
  ];

  bool get iranRulesPresent => iranFiles.keys.every((f) => value.assets.any((a) => a.fileName == f));

  Future<void> setIranDirect(bool on) async {
    await _updateSettings(value.settings.copyWith(iranDirect: on));
    if (on && !iranRulesPresent) {
      // Without the lists there's nothing to apply: flip back, keep the error.
      if (await updateIranRules() != null && !iranRulesPresent) {
        await _updateSettings(value.settings.copyWith(iranDirect: false));
      }
    } else {
      await _reconnectIfConnected();
    }
  }

  /// Downloads (through the VPN when connected) and checks the Iran rule
  /// files. Returns an error message, or null.
  Future<String?> updateIranRules() async {
    if (value.iranRules.updating) return null;
    _emit(value.copyWith(iranRules: IranRulesStatus(updatedAt: value.iranRules.updatedAt, updating: true)));
    String? error;
    try {
      for (final entry in iranFiles.entries) {
        final bytes = await _downloadIranFile(entry.value);
        await _storeGeoAsset(entry.key, bytes, requireTag: 'ir');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await _store.saveIranRulesUpdated(now);
      _emit(value.copyWith(iranRules: IranRulesStatus(updatedAt: now)));
      await _reconnectIfConnected();
    } catch (e) {
      error = e is FormatException ? e.message : 'Couldn\'t download the Iran rules: $e';
      _emit(value.copyWith(iranRules: IranRulesStatus(updatedAt: value.iranRules.updatedAt, error: error)));
    }
    return error;
  }

  Future<Uint8List> _downloadIranFile(String name) async {
    Object? lastError;
    for (final base in _iranSources) {
      final client = _httpClient();
      try {
        final r = await client.get(Uri.parse('$base$name')).timeout(const Duration(seconds: 90));
        if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
        // The release publishes a checksum next to each file.
        try {
          final sum = await client.get(Uri.parse('$base$name.sha256sum')).timeout(const Duration(seconds: 20));
          if (sum.statusCode == 200) {
            final expected = sum.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
            if (sha256.convert(r.bodyBytes).toString() != expected) throw 'checksum mismatch';
          }
        } on TimeoutException {
          // No checksum reachable: the file is still checked as a geo list below.
        }
        return r.bodyBytes;
      } catch (e) {
        lastError = e;
      } finally {
        client.close();
      }
    }
    throw 'from GitHub and jsDelivr ($lastError)';
  }

  CompiledRules get _compiledUserRules => PassThroughRules.compile(value.settings.rules, value.assets);

  Future<void> addRule(String rule) async {
    if (value.settings.rules.contains(rule)) return;
    await setRules([...value.settings.rules, rule].join('\n'));
  }

  // ───────────────────────────── geo assets ─────────────────────────────

  /// Validates and stores a geoip/geosite .dat file. Returns the asset, or
  /// throws a [FormatException] with a user-facing message.
  Future<GeoAsset> importGeoAsset(String fileName, Uint8List bytes) async {
    final asset = await _storeGeoAsset(fileName, bytes);
    await _reconnectIfConnected();
    return asset;
  }

  Future<GeoAsset> _storeGeoAsset(String fileName, Uint8List bytes, {String? requireTag}) async {
    final dir = await engine.assetDirectory();
    if (dir == null) throw const FormatException('Geo files aren\'t supported on this platform');
    final info = await compute(inspectGeoFile, bytes);
    if (info == null) {
      throw const FormatException('That file isn\'t a geoip or geosite .dat file');
    }
    if (requireTag != null && !info.tags.contains(requireTag)) {
      throw FormatException('$fileName has no "$requireTag" list');
    }
    var name = sanitizeGeoFileName(fileName);
    // Xray's built-in prefixes expect these exact names for these kinds.
    if (name == 'geoip.dat' && info.kind == GeoKind.site) name = 'geosite.dat';
    if (name == 'geosite.dat' && info.kind == GeoKind.ip) name = 'geoip.dat';
    await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
    final asset = GeoAsset(
      fileName: name,
      kind: info.kind,
      size: bytes.length,
      tags: info.tags,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _emit(value.copyWith(assets: [
      ...value.assets.where((a) => a.fileName != name),
      asset,
    ]..sort((a, b) => a.fileName.compareTo(b.fileName))));
    await _save();
    return asset;
  }

  Future<void> removeGeoAsset(String fileName) async {
    final dir = await engine.assetDirectory();
    if (dir != null) {
      try {
        await File(p.join(dir.path, fileName)).delete();
      } catch (_) {}
    }
    _emit(value.copyWith(assets: value.assets.where((a) => a.fileName != fileName).toList()));
    // The Iran preset can't work without its files.
    if (iranFiles.containsKey(fileName) && value.settings.iranDirect) {
      _emit(value.copyWith(settings: value.settings.copyWith(iranDirect: false)));
    }
    await _save();
    // Rules that used it now drop out; apply that.
    await _reconnectIfConnected();
  }
}
