import 'dart:async';
import 'dart:io';

import 'package:ir_net/v2ray/kill_switch.dart';
import 'package:ir_net/v2ray/models.dart';
import 'package:ir_net/v2ray/routing_rules.dart';
import 'package:ir_net/v2ray/vpn_engine.dart';
import 'package:ir_net/v2ray/xray_runner.dart';

/// Records connects instead of starting a core or touching the OS proxy.
class FakeEngine implements VpnEngine {
  FakeEngine(this.assetDir);
  final Directory assetDir;
  final events$ = StreamController<EngineEvent>.broadcast();
  final connects = <FakeConnect>[];
  VpnMode defaultModeValue = VpnMode.proxy;
  int disconnects = 0;
  Object? failWith;

  /// What [probe] answers; a function so tests can count calls.
  bool Function() probeResult = () => true;
  int probes = 0;

  @override
  String? activeOutboundTag;

  @override
  String? get unsupportedReason => null;

  @override
  VpnMode get defaultMode => defaultModeValue;

  @override
  XrayRunner? get testRunner => null;

  @override
  Future<Directory?> assetDirectory() async => assetDir;

  @override
  Stream<EngineEvent> get events => events$.stream;

  @override
  Future<EngineSession> connect(List<V2rayProfile> profiles, ConnectOptions options) async {
    if (failWith != null) throw failWith!;
    connects.add(FakeConnect(profiles, options));
    return EngineSession(httpProxy: options.mode == VpnMode.tunnel ? null : '127.0.0.1:10809', systemProxy: true);
  }

  @override
  Future<bool> probe() async {
    probes++;
    return probeResult();
  }

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> recover() async {}
}


class FakeConnect {
  FakeConnect(this.profiles, this.options);
  final List<V2rayProfile> profiles;
  final ConnectOptions options;

  String get id => profiles.first.id;
  List<String> get ids => profiles.map((p) => p.id).toList();
  bool get bypassLan => options.bypassLan;
  CompiledRules get rules => options.rules;
  VpnMode get mode => options.mode;
}

/// Records cuts and restores instead of touching the network.
class FakeKillSwitch extends KillSwitch {
  final log = <String>[];
  Object? failWith;

  @override
  Future<Map<String, dynamic>> cut() async {
    if (failWith != null) throw failWith!;
    log.add('cut');
    return {'adapters': ['Wi-Fi', 'Ethernet']};
  }

  @override
  Future<void> restore(Map<String, dynamic> state) async {
    if (failWith != null) throw failWith!;
    log.add('restore ${(state['adapters'] as List?)?.join(',')}');
  }
}
