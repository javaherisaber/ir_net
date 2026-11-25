import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:path/path.dart' as p;

import 'elevated_core.dart';
import 'linux_tunnel_setup.dart';
import 'mac_tunnel_helper.dart';
import 'models.dart';
import 'physical_interface.dart';
import 'routing_rules.dart';
import 'share_link.dart';
import 'system_proxy.dart';
import 'windows_tunnel_task.dart';
import 'v2ray_store.dart';
import 'xray_config.dart';
import 'xray_runner.dart';

class VpnException implements Exception {
  const VpnException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Something the engine reports on its own.
sealed class EngineEvent {
  const EngineEvent();
}

/// The connection ended without being asked to (core crash, VPN revoked,
/// stopped from the Android notification).
class EngineStopped extends EngineEvent {
  const EngineStopped([this.error]);
  final String? error;
}

class EngineTraffic extends EngineEvent {
  const EngineTraffic({this.uploadSpeed, this.downloadSpeed, this.uploaded, this.downloaded});
  final int? uploadSpeed;
  final int? downloadSpeed;
  final int? uploaded;
  final int? downloaded;
}

/// A VPN found running at launch (Android keeps it in its own process).
class EngineResumed extends EngineEvent {
  const EngineResumed(this.profileId, this.session);
  final String profileId;
  final EngineSession session;
}

/// How to connect: the same for every platform.
class ConnectOptions {
  const ConnectOptions({
    required this.mode,
    this.bypassLan = true,
    this.rules = CompiledRules.empty,
    this.fragment,
    this.bypassApps = const [],
  });

  final VpnMode mode;
  final bool bypassLan;
  final CompiledRules rules;

  /// TLS handshake fragmentation, or null for off.
  final FragmentOptions? fragment;

  /// Apps that skip the VPN (Android packages; desktop process names/paths).
  final List<String> bypassApps;
}

class EngineSession {
  const EngineSession({this.httpProxy, this.udpProxy, required this.systemProxy, this.note});

  /// Local HTTP proxy for IRNet's own requests ("[user:pass@]127.0.0.1:port"),
  /// or null when they already go through the tunnel.
  final String? httpProxy;

  /// Local SOCKS5 proxy ("127.0.0.1:port") whose UDP takes the way the other
  /// apps' UDP takes, for IRNet's UDP probes: Android Tunnel mode, where
  /// IRNet is outside its own VPN. Null elsewhere.
  final String? udpProxy;
  final bool systemProxy;
  final String? note;
}

/// Platform side of the VPN.
abstract class VpnEngine {
  static VpnEngine forPlatform(V2rayStore store) {
    if (kIsWeb) return const UnsupportedVpnEngine('The VPN needs the desktop or Android app.');
    if (Platform.isAndroid) return AndroidVpnEngine(store);
    if (Platform.isIOS) {
      return const UnsupportedVpnEngine(
          'Connecting isn\'t available on iOS yet. You can still import configs and check that their servers answer.');
    }
    return DesktopVpnEngine(store);
  }

  /// Null when this platform can connect.
  String? get unsupportedReason;

  /// The mode used until the user picks one.
  VpnMode get defaultMode;

  /// Starts cores for delay tests; null means TCP-only tests.
  XrayRunner? get testRunner;

  /// Where imported .dat files go; null when geo assets aren't supported.
  Future<Directory?> assetDirectory();

  Stream<EngineEvent> get events;

  /// Connects to [profiles]: one config, or for Auto several, which the
  /// core switches between by latency and health.
  Future<EngineSession> connect(List<V2rayProfile> profiles, ConnectOptions options);

  Future<void> disconnect();

  /// Undoes what a crash left behind (OS proxy, orphaned core).
  Future<void> recover();

  /// Whether a request gets through the VPN right now.
  Future<bool> probe();

  /// In Auto: the outbound tag ("proxy-3") the core is using, when known.
  String? get activeOutboundTag;

  /// Tunnel mode (desktop): the physical interface delay tests bind their
  /// connections to, so they reach servers directly instead of through the
  /// VPN. Null otherwise.
  String? get testInterface;
}

class UnsupportedVpnEngine implements VpnEngine {
  const UnsupportedVpnEngine(this.unsupportedReason);

  @override
  final String unsupportedReason;

  @override
  VpnMode get defaultMode => VpnMode.proxy;

  @override
  XrayRunner? get testRunner => null;

  @override
  Future<Directory?> assetDirectory() async => null;

  @override
  Stream<EngineEvent> get events => const Stream.empty();

  @override
  Future<EngineSession> connect(List<V2rayProfile> profiles, ConnectOptions options) =>
      Future.error(VpnException(unsupportedReason));

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> recover() async {}

  @override
  Future<bool> probe() async => false;

  @override
  String? get activeOutboundTag => null;

  @override
  String? get testInterface => null;
}

// ───────────────────────────── Desktop ─────────────────────────────

/// Windows, macOS, Linux: the bundled core as a child process with SOCKS and
/// HTTP inbounds on localhost, and the OS proxy pointed at them.
class DesktopVpnEngine implements VpnEngine {
  DesktopVpnEngine(this.store, {SystemProxy? proxy, String? binary})
      : _proxy = proxy ?? SystemProxy.forPlatform(),
        _binary = binary ?? XrayBinary.locate();

  final V2rayStore store;
  final SystemProxy? _proxy;
  final String? _binary;
  final _events = StreamController<EngineEvent>.broadcast();

  XrayInstance? _instance;
  Map<String, dynamic>? _snapshot;
  bool _stopping = false;

  /// The live connection's local HTTP inbound (health checks go through it).
  int? _httpPort;

  /// Tunnel mode: the interface the default route used before the tunnel.
  String? _tunnelInterface;

  @override
  String? get testInterface => _instance == null ? null : _tunnelInterface;

  static const preferredSocksPort = 10808;
  static const preferredHttpPort = 10809;

  @override
  String? get unsupportedReason => _binary == null ? XrayBinary.missingMessage : null;

  /// No password prompt; Tunnel is one tap away in the settings.
  @override
  VpnMode get defaultMode => VpnMode.proxy;

  @override
  Future<Directory?> assetDirectory() async {
    final dir = Directory(p.join((await ProcessXrayRunner.workDir()).path, 'assets'));
    await dir.create(recursive: true);
    return dir;
  }

  @override
  XrayRunner? get testRunner => _binary == null ? null : _LazyAssetRunner(this);

  Future<ProcessXrayRunner> _runner() async =>
      ProcessXrayRunner(_binary!, assetDir: (await assetDirectory())!.path);

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Future<EngineSession> connect(List<V2rayProfile> profiles, ConnectOptions options) async {
    if (_binary == null) throw const VpnException(XrayBinary.missingMessage);
    await disconnect();
    if (options.mode == VpnMode.tunnel) {
      // Read before the tunnel takes the default route over.
      _tunnelInterface = await PhysicalInterface.find();
      return _connectTunnel(profiles, options);
    }
    final bypassLan = options.bypassLan;
    final rules = options.rules;
    final socks = await LocalPorts.pick(preferredSocksPort);
    final http = await LocalPorts.pick(preferredHttpPort, avoid: {socks});
    final config = XrayConfigBuilder.connection(profiles.first,
        socksPort: socks,
        httpPort: http,
        bypassLan: bypassLan,
        rules: rules,
        balanced: profiles,
        fragment: options.fragment,
        bypassApps: options.bypassApps);

    final XrayInstance instance;
    try {
      instance = await (await _runner()).start(XrayConfigBuilder.encode(config), label: 'vpn');
    } on XrayStartException catch (e) {
      throw VpnException(e.message);
    }
    if (!await LocalPorts.waitFor(http, instance)) {
      final tail = instance.logTail;
      await instance.stop();
      throw VpnException(tail.isEmpty ? 'The Xray core stopped right after starting' : 'Xray: $tail');
    }
    _instance = instance;
    _httpPort = http;
    unawaited(instance.exited.then((_) => _onExit(instance)));

    String? note;
    var systemProxy = false;
    final proxy = _proxy;
    if (proxy != null) {
      try {
        _snapshot = await proxy.snapshot();
        // Saved before touching anything, so a crash can be undone at next launch.
        await store.saveRecovery({'pid': instance.pid, 'httpPort': http, 'proxy': _snapshot});
        await proxy.apply(httpPort: http, socksPort: socks, bypassLan: bypassLan, rules: rules);
        systemProxy = true;
      } catch (e) {
        _snapshot = null;
        await store.saveRecovery({'pid': instance.pid});
        note = 'The system proxy wasn\'t set ($e). Apps can still use HTTP proxy 127.0.0.1:$http '
            'or SOCKS5 127.0.0.1:$socks.';
      }
    } else {
      await store.saveRecovery({'pid': instance.pid});
    }
    return EngineSession(httpProxy: '127.0.0.1:$http', systemProxy: systemProxy, note: note);
  }

  /// Tunnel mode: the core runs with admin rights (one prompt) and takes
  /// over the system's routes; nothing else needs a proxy setting.
  Future<EngineSession> _connectTunnel(List<V2rayProfile> candidates, ConnectOptions options) async {
    final binary = _binary!;
    if (Platform.isWindows && !File(p.join(File(binary).parent.path, 'wintun.dll')).existsSync()) {
      throw const VpnException('wintun.dll is missing next to xray.exe, so tunnel mode can\'t start. '
          'Run "dart run tool/fetch_xray.dart windows" and rebuild.');
    }
    final os = Platform.isWindows ? 'windows' : (Platform.isMacOS ? 'macos' : 'linux');
    final http = await LocalPorts.pick(preferredHttpPort);
    final pinned = await _pinServerAddresses(candidates);
    final profiles = pinned.profiles;
    final resolved = Platform.isLinux && await _linuxResolvedActive();
    final config = XrayConfigBuilder.tunnel(profiles.first,
        httpPort: http,
        os: os,
        bypassLan: options.bypassLan,
        rules: options.rules,
        hosts: pinned.hosts,
        linuxResolved: resolved,
        balanced: profiles,
        fragment: options.fragment,
        bypassApps: options.bypassApps);

    final work = await ProcessXrayRunner.workDir();
    await _cleanOldTunnelDirs(work);
    final dir = Directory(p.join(work.path, 'tunnel-${DateTime.now().millisecondsSinceEpoch}'));
    late final XrayInstance instance;
    final encoded = XrayConfigBuilder.encode(config);
    final assets = (await assetDirectory())!.path;
    Map<String, dynamic> recovery;
    // Each OS gets a one-time setup (one prompt) so later connects don't ask;
    // where that isn't possible, the core starts elevated with a prompt.
    Future<XrayInstance> promptEveryTime() => ElevatedCoreLauncher().start(
          binary: binary,
          config: encoded,
          assetDir: assets,
          controlDir: dir,
          dnsServers: XrayConfigBuilder.tunDnsServers,
        );
    try {
      if (Platform.isMacOS) {
        // A root helper behind a sudoers rule for this user.
        final helper = MacTunnelHelper();
        if (!await helper.isReady(binary)) await helper.install(binary);
        instance = await helper.startCore(
            config: encoded, assetDir: assets, dnsServices: await MacSystemProxy().services());
        recovery = {'macHelper': true};
      } else if (Platform.isWindows && await WindowsTunnelTask().userIsAdmin()) {
        // A scheduled task with the user's full rights, started without UAC.
        final task = WindowsTunnelTask();
        if (!await task.isReady(binary)) await task.install(binary);
        instance = await task.startCore(config: encoded, assetDir: assets);
        recovery = {'windowsTask': true};
      } else if (Platform.isLinux) {
        // No root at all: a copy of the core with just the network capabilities.
        try {
          final setup = LinuxTunnelSetup();
          if (!await setup.isReady(binary)) await setup.install(binary);
          instance = await ProcessXrayRunner(LinuxTunnelSetup.xrayPath, assetDir: assets)
              .start(encoded, label: 'tunnel');
          recovery = {'pid': instance.pid};
        } on LinuxTunnelSetupUnavailable catch (e) {
          debugPrint('V2Ray: password-free tunnel unavailable ($e); asking each time');
          instance = await promptEveryTime();
          recovery = {'tunnelDir': dir.path};
        }
      } else {
        instance = await promptEveryTime();
        recovery = {'tunnelDir': dir.path};
      }
    } on XrayStartException catch (e) {
      throw VpnException(e.message);
    } on SystemProxyException catch (e) {
      throw VpnException(e.message);
    }
    await store.saveRecovery(recovery);
    // pkexec prompts after the helper starts, so allow time to type a password.
    final timeout = Duration(seconds: Platform.isLinux ? 120 : 30);
    if (!await LocalPorts.waitFor(http, instance, timeout: timeout)) {
      final tail = instance.logTail;
      await instance.stop();
      await store.saveRecovery(null);
      throw VpnException(tail.isEmpty ? 'Tunnel mode did not start' : 'Xray: $tail');
    }
    _instance = instance;
    _httpPort = http;
    unawaited(instance.exited.then((_) => _onExit(instance)));
    return EngineSession(
      systemProxy: false,
      note: Platform.isLinux && !resolved
          ? 'System DNS isn\'t sent through the tunnel here (it needs systemd-resolved), so name lookups '
              'may go to your network\'s DNS server.'
          : null,
    );
  }

  /// The servers' addresses, looked up while DNS still works normally, so
  /// the core never needs the tunnel to find its own servers. In Auto,
  /// servers whose names don't resolve are left out.
  static Future<({List<V2rayProfile> profiles, Map<String, List<String>> hosts})> _pinServerAddresses(
      List<V2rayProfile> profiles) async {
    final hosts = <String, List<String>>{};
    final kept = <V2rayProfile>[];
    await Future.wait(profiles.map((p) async {
      if (ShareLinkParser.parseIpv4(p.address) != null || p.address.contains(':')) return;
      if (hosts.containsKey(p.address)) return;
      try {
        final found = await InternetAddress.lookup(p.address).timeout(const Duration(seconds: 8));
        if (found.isNotEmpty) hosts[p.address] = found.map((a) => a.address).toList();
      } catch (_) {}
    }));
    for (final p in profiles) {
      final literal = ShareLinkParser.parseIpv4(p.address) != null || p.address.contains(':');
      if (literal || hosts.containsKey(p.address)) kept.add(p);
    }
    if (kept.isEmpty) {
      final name = profiles.first.address;
      throw VpnException(profiles.length == 1
          ? 'Couldn\'t look up the server address $name. Check your internet connection.'
          : 'Couldn\'t look up any of the servers\' addresses. Check your internet connection.');
    }
    return (profiles: kept, hosts: hosts);
  }

  @override
  Future<bool> probe() async {
    final port = _httpPort;
    if (port == null || _instance == null || _instance!.hasExited) return false;
    return probeThroughProxy('127.0.0.1:$port');
  }

  @override
  String? get activeOutboundTag => _instance?.lastOutboundTag;

  static Future<bool> _linuxResolvedActive() async {
    try {
      final active = await Process.run('systemctl', ['is-active', 'systemd-resolved']);
      final tool = await Process.run('which', ['resolvectl']);
      return active.stdout.toString().trim() == 'active' && tool.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _cleanOldTunnelDirs(Directory work) async {
    await for (final e in work.list()) {
      if (e is Directory && p.basename(e.path).startsWith('tunnel-') && File(p.join(e.path, 'exited')).existsSync()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreProxy() async {
    final snapshot = _snapshot;
    _snapshot = null;
    if (snapshot == null || _proxy == null) return;
    try {
      await _proxy.restore(snapshot);
    } catch (e) {
      debugPrint('V2Ray: could not restore the system proxy: $e');
    }
  }

  Future<void> _onExit(XrayInstance instance) async {
    if (_stopping || !identical(_instance, instance)) return;
    _instance = null;
    await _restoreProxy();
    await store.saveRecovery(null);
    final tail = instance.logTail;
    _events.add(EngineStopped(tail.isEmpty ? 'The Xray core stopped' : 'The Xray core stopped: $tail'));
  }

  @override
  Future<void> disconnect() async {
    _stopping = true;
    _httpPort = null;
    _tunnelInterface = null;
    try {
      await _restoreProxy();
      await _instance?.stop();
    } finally {
      _instance = null;
      _stopping = false;
      await store.saveRecovery(null);
    }
  }

  @override
  Future<void> recover() async {
    final record = await store.loadRecovery();
    if (record == null) return;
    // The helpers stop the core by themselves once IRNet is gone; make sure.
    if (record['macHelper'] == true && MacTunnelHelper.isInstalled) {
      try {
        await MacTunnelHelper().stopCore();
      } catch (_) {}
    }
    if (record['windowsTask'] == true) await WindowsTunnelTask().stopCore();
    final tunnel = record['tunnelDir'] as String?;
    if (tunnel != null && Directory(tunnel).existsSync()) {
      // The privileged helper stops by itself once IRNet is gone; make sure.
      try {
        await File(p.join(tunnel, 'stop')).writeAsString('stop');
      } catch (_) {}
    }
    final snapshot = record['proxy'];
    final port = (record['httpPort'] as num?)?.toInt();
    if (snapshot is Map && _proxy != null && port != null) {
      try {
        // Only undo it if the proxy still points at the dead core.
        if (await _proxy.pointsAt(port)) await _proxy.restore(snapshot.cast<String, dynamic>());
      } catch (e) {
        debugPrint('V2Ray: proxy recovery failed: $e');
      }
    }
    final pid = (record['pid'] as num?)?.toInt();
    if (pid != null && await _isOurCore(pid)) Process.killPid(pid);
    await store.saveRecovery(null);
  }

  /// Guards against killing an unrelated process that reused the pid.
  static Future<bool> _isOurCore(int pid) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        return r.stdout.toString().toLowerCase().contains('xray.exe');
      }
      final r = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      return r.stdout.toString().toLowerCase().contains('xray');
    } catch (_) {
      return false;
    }
  }
}

/// Resolves the asset directory on first use.
class _LazyAssetRunner implements XrayRunner {
  _LazyAssetRunner(this.engine);
  final DesktopVpnEngine engine;

  @override
  Future<XrayInstance> start(String config, {String label = 'core'}) async =>
      (await engine._runner()).start(config, label: label);
}

// ───────────────────────────── Android ─────────────────────────────

/// Android: flutter_v2ray's VpnService (libv2ray + tun2socks) carries the
/// device's traffic. IRNet itself is excluded from that tunnel by the
/// plugin, so its own requests go through the core's local HTTP inbound
/// (password-protected, since any app could reach it).
class AndroidVpnEngine implements VpnEngine {
  AndroidVpnEngine(this.store);
  final V2rayStore store;

  final _events = StreamController<EngineEvent>.broadcast();
  FlutterV2ray? _plugin;
  Completer<bool>? _waitingForConnect;
  bool _running = false;
  bool _initialized = false;

  @override
  String? get unsupportedReason => null;

  @override
  VpnMode get defaultMode => VpnMode.tunnel;

  @override
  XrayRunner? get testRunner => ChannelXrayRunner();

  @override
  Future<Directory?> assetDirectory() async {
    final path = await ChannelXrayRunner.assetDir();
    if (path == null) return null;
    final dir = Directory(path);
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Stream<EngineEvent> get events => _events.stream;

  /// The VPN's status, per engine (VpnStatusStream.kt). flutter_v2ray's own
  /// status stream shares one sink between engines, and an old activity's
  /// teardown silences a new one: connects then time out on a working VPN.
  static const _statusChannel = EventChannel('ir_net/vpn_status');
  StreamSubscription<dynamic>? _status;

  void _onStatusEvent(dynamic e) {
    if (e is! Map) return;
    int n(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    _onStatus(V2RayStatus(
      duration: '${e['duration'] ?? ''}',
      uploadSpeed: n(e['uploadSpeed']),
      downloadSpeed: n(e['downloadSpeed']),
      upload: n(e['upload']),
      download: n(e['download']),
      state: '${e['state'] ?? 'DISCONNECTED'}',
    ));
  }

  Future<FlutterV2ray> _ensurePlugin() async {
    _status ??= _statusChannel.receiveBroadcastStream().listen(_onStatusEvent, onError: (Object e) {
      debugPrint('V2Ray: status stream failed: $e');
    });
    // Status comes from _statusChannel instead.
    final plugin = _plugin ??= FlutterV2ray(onStatusChanged: (_) {});
    if (!_initialized) {
      await plugin.initializeV2Ray(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
      _initialized = true;
    }
    return plugin;
  }

  void _onStatus(V2RayStatus status) {
    final connected = status.state == 'CONNECTED';
    if (connected) {
      final waiting = _waitingForConnect;
      if (waiting != null && !waiting.isCompleted) waiting.complete(true);
      if (!_running && waiting == null) unawaited(_resume());
      _events.add(EngineTraffic(
        uploadSpeed: status.uploadSpeed,
        downloadSpeed: status.downloadSpeed,
        uploaded: status.upload,
        downloaded: status.download,
      ));
    } else if (status.state == 'DISCONNECTED' && _running && _waitingForConnect == null) {
      _running = false;
      unawaited(store.saveRecovery(null));
      _events.add(const EngineStopped());
    }
  }

  /// The VPN service outlives the UI; pick it back up after a restart.
  Future<void> _resume() async {
    final record = await store.loadRecovery();
    final id = record?['profileId'] as String?;
    final proxy = record?['httpProxy'] as String?;
    if (id == null || proxy == null || _running) return;
    final udp = record?['udpProxy'] as String?;
    _running = true;
    _events.add(EngineResumed(
        id, EngineSession(httpProxy: proxy, udpProxy: udp == null || udp.isEmpty ? null : udp, systemProxy: true)));
  }

  @override
  Future<bool> probe() async {
    if (!_running || _plugin == null) return false;
    try {
      return await _plugin!.getConnectedServerDelay(url: XrayConfigBuilder.probeUrl) > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  String? get activeOutboundTag => null;

  /// IRNet is outside its own VPN on Android: tests already go direct.
  @override
  String? get testInterface => null;

  @override
  Future<EngineSession> connect(List<V2rayProfile> profiles, ConnectOptions options) async {
    final profile = profiles.first;
    final bypassLan = options.bypassLan;
    final rules = options.rules;
    final plugin = await _ensurePlugin();
    final tunnel = options.mode == VpnMode.tunnel;
    if (tunnel && !await plugin.requestPermission()) {
      throw const VpnException('Android\'s VPN permission was not granted');
    }
    if (_running) await disconnect();

    final socks = await LocalPorts.pick(10808);
    final http = await LocalPorts.pick(10809, avoid: {socks});
    final random = Random.secure();
    final pass = List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
    final config = XrayConfigBuilder.connection(profile,
        socksPort: socks,
        httpPort: http,
        bypassLan: bypassLan,
        rules: rules,
        httpAuth: (user: 'irnet', pass: pass),
        balanced: profiles,
        fragment: options.fragment);

    // Keep LAN and plain IP exclusions out of the tunnel altogether.
    final excluded = [
      if (bypassLan) ...XrayConfigBuilder.lanCidrs.where((c) => !c.contains(':')),
      ...rules.osIps.where((c) => !c.contains(':')),
    ];
    final routes = excluded.isEmpty ? null : XrayConfigBuilder.ipv4RoutesExcluding(excluded);

    final waiting = _waitingForConnect = Completer<bool>();
    try {
      await plugin.startV2Ray(
        remark: profiles.length > 1 ? 'Auto (${profiles.length} servers)' : profile.name,
        config: XrayConfigBuilder.encode(config),
        bypassSubnets: tunnel ? routes : null,
        // Apps that skip the VPN (Android's per-app exclusion).
        blockedApps: tunnel && options.bypassApps.isNotEmpty ? options.bypassApps : null,
        // Proxy mode: only the local proxy runs; apps use it if set to.
        proxyOnly: !tunnel,
        notificationDisconnectButtonName: 'Disconnect',
      );
      final ok = await waiting.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
      if (!ok) {
        await plugin.stopV2Ray();
        throw const VpnException('The VPN didn\'t come up. The server may be unreachable or the config wrong.');
      }
    } finally {
      _waitingForConnect = null;
    }
    _running = true;
    final httpProxy = 'irnet:$pass@127.0.0.1:$http';
    // The apps' UDP reaches Xray's SOCKS inbound through tun2socks; IRNet's
    // UDP probes go the same way (Tunnel mode only: in Proxy mode the apps'
    // UDP doesn't use the VPN at all).
    final udpProxy = tunnel ? '127.0.0.1:$socks' : null;
    await store.saveRecovery({'profileId': profile.id, 'httpProxy': httpProxy, 'udpProxy': udpProxy});
    // What the Quick Settings tile starts when the app isn't running
    // (VpnTileService.kt): this connection, exactly.
    await store.saveQuickConnect({
      'remark': profiles.length > 1 ? 'Auto (${profiles.length} servers)' : profile.name,
      'config': XrayConfigBuilder.encode(config),
      'blockedApps': tunnel && options.bypassApps.isNotEmpty ? options.bypassApps : null,
      'bypassSubnets': tunnel ? routes : null,
      'proxyOnly': !tunnel,
      'profileId': profile.id,
      'httpProxy': httpProxy,
      'udpProxy': udpProxy,
    });
    return EngineSession(
      httpProxy: httpProxy,
      udpProxy: udpProxy,
      systemProxy: tunnel,
      note: tunnel
          ? null
          : 'Proxy mode: only apps set to use the SOCKS5 proxy 127.0.0.1:$socks go through the VPN.',
    );
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    await store.saveRecovery(null);
    if (_plugin != null) await _plugin!.stopV2Ray();
  }

  @override
  Future<void> recover() async {
    // Registers the status receiver, so a VPN still running reports in.
    try {
      await _ensurePlugin();
    } catch (e) {
      debugPrint('V2Ray: plugin init failed: $e');
    }
  }
}

/// One request to the probe URL through the local HTTP proxy at [proxy].
Future<bool> probeThroughProxy(String proxy, {Duration timeout = const Duration(seconds: 10)}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'PROXY $proxy')
    ..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(XrayConfigBuilder.probeUrl)).timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    return response.statusCode >= 200 && response.statusCode < 400;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
