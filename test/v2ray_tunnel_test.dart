import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/elevated_core.dart';
import 'package:ir_net/v2ray/kill_switch.dart';
import 'package:ir_net/v2ray/routing_rules.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/system_proxy.dart';
import 'package:ir_net/v2ray/vpn_engine.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:ir_net/v2ray_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/v2ray_fakes.dart';

const _uuid = '2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60';

class _Commands {
  final calls = <List<String>>[];
  final outputs = <String, String>{};

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    return ProcessResult(0, 0, outputs[args.join(' ')] ?? '', '');
  }
}

const _order = '''
An asterisk (*) denotes that a network service is disabled.
(1) USB 10/100/1000 LAN
(Hardware Port: USB 10/100/1000 LAN, Device: en7)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(3) V2BOX
(Hardware Port: com.v2box, Device: )
''';

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final profile = ShareLinkParser.parse('vless://$_uuid@de1.example.com:443?security=tls&sni=de1.example.com#DE');

  group('tunnel config', () {
    test('routes the system through a TUN and answers its DNS', () {
      final c = XrayConfigBuilder.tunnel(profile,
          httpPort: 10809,
          os: 'macos',
          rules: PassThroughRules.compile(['geoip:ir'], [
            const GeoAsset(fileName: 'geoip.dat', kind: GeoKind.ip, size: 1, tags: ['ir'], importedAt: 0)
          ]),
          hosts: {
            'de1.example.com': ['203.0.113.10']
          });
      final tun = (c['inbounds'] as List).first;
      expect(tun['protocol'], 'tun');
      expect(tun['settings']['autoSystemRoutingTable'], ['0.0.0.0/0', '::/0']);
      expect(tun['settings'].containsKey('dns'), isFalse, reason: 'macOS ignores it; the helper sets DNS');
      expect(tun['sniffing']['routeOnly'], isTrue);
      final rules = c['routing']['rules'] as List;
      expect(rules.first, {
        'inboundTag': ['tun'],
        'port': 53,
        'outboundTag': 'dns-out'
      });
      expect(rules.last, {
        'ip': ['geoip:ir'],
        'outboundTag': 'direct'
      });
      expect(c['routing']['domainStrategy'], 'IPIfNonMatch');
      final outbounds = c['outbounds'] as List;
      expect(outbounds.map((o) => o['tag']), ['proxy', 'direct', 'block', 'dns-out']);
      expect(outbounds[0]['streamSettings']['sockopt'], {'domainStrategy': 'UseIP'});
      expect(outbounds[1]['streamSettings'], {
        'sockopt': {'domainStrategy': 'UseIP'}
      });
      expect(c['dns']['hosts'], {
        'de1.example.com': ['203.0.113.10']
      });
      jsonEncode(c);
    });

    test('Android with cloned apps: Xray reads the VPN, nothing is excluded by package', () {
      final c = XrayConfigBuilder.androidTunnel(profile,
          socksPort: 10808,
          httpPort: 10809,
          httpAuth: (user: 'irnet', pass: 'p'),
          hosts: {
            'de1.example.com': ['203.0.113.10']
          },
          bypassAppIds: ['10391', '10402']);
      final inbounds = c['inbounds'] as List;
      expect(inbounds.map((i) => i['protocol']), ['tun', 'socks', 'http'],
          reason: 'the local proxies stay for IRNet\'s own requests and probes');
      final tun = inbounds.first;
      expect(tun['settings'].containsKey('autoOutboundsInterface'), isFalse, reason: 'needs netlink, refused to apps');
      expect(tun['settings'].containsKey('autoSystemRoutingTable'), isFalse, reason: 'Android\'s VpnService routes');
      expect(c['log']['access'], 'none', reason: 'it would log every connection on the phone');
      final rules = c['routing']['rules'] as List;
      expect(rules[0], {
        'inboundTag': ['tun'],
        'process': ['10391', '10402'],
        'outboundTag': 'direct',
      }, reason: 'bypassed apps (and their clones) go direct, DNS included, so this comes first');
      expect(rules[1], {
        'inboundTag': ['tun'],
        'port': 53,
        'outboundTag': 'dns-out'
      });
      final outbounds = c['outbounds'] as List;
      expect(outbounds.map((o) => o['tag']), ['proxy', 'direct', 'block', 'dns-out']);
      expect(outbounds[0]['streamSettings']['sockopt'], {'domainStrategy': 'UseIP', 'interface': 'irnet-unbound'},
          reason: 'the server\'s name is pinned: reaching it never needs DNS through the tunnel; '
              'the VPN service binds the connections to the network, and until then to nothing');
      expect(outbounds[1]['streamSettings']['sockopt'], {'domainStrategy': 'UseIP', 'interface': 'irnet-unbound'});
      expect(outbounds[2].containsKey('streamSettings'), isFalse, reason: 'blackhole connects nowhere');
      expect(outbounds[3]['streamSettings']['sockopt'], {'interface': 'irnet-unbound'});
      expect(c['dns']['hosts'], {
        'de1.example.com': ['203.0.113.10']
      });
      expect(
          (XrayConfigBuilder.androidTunnel(profile, socksPort: 1, httpPort: 2)['routing']['rules'] as List)
              .any((r) => r.containsKey('process')),
          isFalse);
      jsonEncode(c);
    });

    test('per-OS DNS handling', () {
      final win = (XrayConfigBuilder.tunnel(profile, httpPort: 1, os: 'windows')['inbounds'] as List).first['settings'];
      expect(win['name'], 'IRNet');
      expect(win['dns'], ['1.1.1.1', '8.8.8.8']);
      expect(win['autoSystemWfpBlockLeak'], ['dns', 'misconfigtun']);

      final linux = XrayConfigBuilder.tunnel(profile, httpPort: 1, os: 'linux', linuxResolved: true);
      expect((linux['inbounds'] as List).first['settings']['autoSystemDnsToGateway'], isTrue);
      expect((linux['inbounds'] as List).first['sniffing']['routeOnly'], isTrue);

      final bare = XrayConfigBuilder.tunnel(profile, httpPort: 1, os: 'linux');
      expect((bare['inbounds'] as List).first['settings'].containsKey('autoSystemDnsToGateway'), isFalse);
      expect((bare['inbounds'] as List).first['sniffing']['routeOnly'], isFalse,
          reason: 'DNS may be poisoned here, so the proxy gets the sniffed name');
    });
  });

  group('privileged helper script', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('irnet_tun'));
    tearDown(() async => tmp.delete(recursive: true));

    /// A stand-in core that logs its arguments and environment, then waits.
    Future<String> fakeXray() async {
      final f = File('${tmp.path}/fake xray');
      await f.writeAsString('#!/bin/sh\necho "args: \$*"\necho "assets: \$XRAY_LOCATION_ASSET"\n'
          'echo "config: \$(cat "\$3")"\ntrap \'echo got TERM; exit 0\' TERM\nwhile :; do sleep 0.1; done\n');
      await Process.run('chmod', ['755', f.path]);
      return f.path;
    }

    test('is valid sh', () async {
      final script = ElevatedCoreLauncher.posixScript(
        binary: "/Applications/IRNet's.app/xray",
        config: '{"a":"it\'s \$HOME `x`"}',
        assetDir: '/tmp/a b',
        controlDir: '/tmp/c d',
        parentPid: 1,
        dnsServices: const ['Wi-Fi', 'USB 10/100/1000 LAN'],
      );
      final r = await Process.run('/bin/sh', ['-n', '-c', script]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }, skip: Platform.isWindows);

    test('runs the core with its config, then stops it on the stop file', () async {
      final control = Directory('${tmp.path}/control dir')..createSync();
      final config = jsonEncode({'log': 'it\'s "quoted" \$HOME'});
      final script = ElevatedCoreLauncher.posixScript(
        binary: await fakeXray(),
        config: config,
        assetDir: '${tmp.path}/assets dir',
        controlDir: control.path,
        parentPid: pid,
      );
      final helper = await Process.start('/bin/sh', ['-c', script]);
      final instance = ControlDirInstance(control, launcherExit: helper.exitCode);
      await _until(() => File('${control.path}/xray.log').existsSync() &&
          File('${control.path}/xray.log').readAsStringSync().contains('config:'));
      final log = File('${control.path}/xray.log').readAsStringSync();
      expect(log, contains('args: run -c '));
      expect(RegExp(r'args: run -c (\S+)').firstMatch(log)!.group(1), endsWith('.json'),
          reason: 'Xray picks the config format from the extension');
      expect(log, contains('assets: ${tmp.path}/assets dir'));
      expect(log, contains('config: $config'), reason: 'the config reaches the core byte for byte');
      expect(instance.pid, isNotNull);
      expect(instance.hasExited, isFalse);

      await instance.stop();
      expect(instance.hasExited, isTrue);
      expect(File('${control.path}/xray.log').readAsStringSync(), contains('got TERM'));
      expect(await helper.exitCode, 0);
      // The temporary config is gone.
      final conf = RegExp(r'args: run -c (\S+)').firstMatch(log)!.group(1)!;
      expect(File(conf).existsSync(), isFalse);
    }, skip: Platform.isWindows);

    test('stops the core when IRNet goes away', () async {
      final control = Directory('${tmp.path}/c')..createSync();
      final sleeper = await Process.start('sleep', ['30']);
      final script = ElevatedCoreLauncher.posixScript(
        binary: await fakeXray(),
        config: '{}',
        assetDir: tmp.path,
        controlDir: control.path,
        parentPid: sleeper.pid,
      );
      final helper = await Process.start('/bin/sh', ['-c', script]);
      final instance = ControlDirInstance(control, launcherExit: helper.exitCode);
      await _until(() => instance.pid != null);
      sleeper.kill();
      await instance.exited.timeout(const Duration(seconds: 10));
      expect(File('${control.path}/xray.log').readAsStringSync(), contains('got TERM'));
    }, skip: Platform.isWindows);

    test('a cancelled prompt reads as such', () async {
      final control = Directory('${tmp.path}/x')..createSync();
      final instance = ControlDirInstance(control, launcherExit: Future.value(126));
      await instance.exited.timeout(const Duration(seconds: 3));
      expect(instance.logTail, 'The administrator prompt was cancelled.');
    });

    test('Windows helper embeds the config and stops on the same signals', () {
      final ps = ElevatedCoreLauncher.windowsScript(
          binary: r"C:\Program Files\IRNet\xray.exe", config: '{"a":1}', assetDir: r"C:\Users\o'brien\assets");
      expect(ps, startsWith('param([int]\$ParentPid, [string]\$OutDir)'));
      expect(ps, contains("\$xray = 'C:\\Program Files\\IRNet\\xray.exe'"));
      expect(ps, contains("\$assets = 'C:\\Users\\o''brien\\assets'"));
      expect(ps, contains("@'\n{\"a\":1}\n'@"));
      expect(ps, contains("Test-Path (Join-Path \$OutDir 'stop')"));
      expect(ps, contains('Get-Process -Id \$ParentPid'));
      // UTF-16LE base64, as -EncodedCommand expects.
      expect(utf8.decode(base64.decode(ElevatedCoreLauncher.encodePowerShell('ab')).where((b) => b != 0).toList()),
          'ab');
    });
  });

  group('kill switch commands', () {
    test('macOS turns Wi-Fi radios off and other hardware services off, then back on', () async {
      final cmds = _Commands()..outputs['-listnetworkserviceorder'] = _order;
      final ks = MacKillSwitch(run: cmds.call);
      final state = await ks.cut();
      expect(state, {
        'wifi': ['en0'],
        'services': ['USB 10/100/1000 LAN']
      });
      expect(cmds.calls.skip(1).map((c) => c.sublist(1)), [
        ['-setairportpower', 'en0', 'off'],
        ['-setnetworkserviceenabled', 'USB 10/100/1000 LAN', 'off'],
      ]);
      cmds.calls.clear();
      await ks.restore(state);
      expect(cmds.calls.map((c) => c.sublist(1)), [
        ['-setnetworkserviceenabled', 'USB 10/100/1000 LAN', 'on'],
        ['-setairportpower', 'en0', 'on'],
      ]);
    });

    test('Linux uses NetworkManager', () async {
      final cmds = _Commands();
      final ks = LinuxKillSwitch(run: cmds.call);
      await ks.restore(await ks.cut());
      expect(cmds.calls, [
        ['nmcli', 'networking', 'off'],
        ['nmcli', 'networking', 'on'],
      ]);
    });

    test('macOS hardware services keep port and device', () {
      expect(MacSystemProxy.parseHardwareServices(_order), [
        (service: 'USB 10/100/1000 LAN', port: 'USB 10/100/1000 LAN', device: 'en7'),
        (service: 'Wi-Fi', port: 'Wi-Fi', device: 'en0'),
      ]);
    });
  });

  group('V2rayBloc mode and kill switch', () {
    late Directory tmp;
    late FakeEngine engine;
    late FakeKillSwitch ks;
    late V2rayBloc bloc;
    var waits = 0;

    Future<V2rayBloc> make() async {
      final b = V2rayBloc(engine: engine, killSwitch: () => ks, waitForNetwork: () async => waits++);
      await b.initialize();
      await Future<void>.delayed(Duration.zero);
      return b;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('irnet_ks');
      engine = FakeEngine(tmp);
      ks = FakeKillSwitch();
      waits = 0;
      bloc = await make();
      await bloc.importText('trojan://pw@t.example.com:443#T');
    });

    tearDown(() async => tmp.delete(recursive: true));

    test('the platform default applies until a mode is picked', () async {
      expect(bloc.value.mode, VpnMode.proxy);
      await bloc.connect();
      expect(engine.connects.last.mode, VpnMode.proxy);
      expect(bloc.localProxy, '127.0.0.1:10809');

      await bloc.setMode(VpnMode.tunnel);
      expect(engine.connects.last.mode, VpnMode.tunnel, reason: 'reconnects in the new mode');
      expect(bloc.value.connection.mode, VpnMode.tunnel);
      expect(bloc.localProxy, isNull, reason: "IRNet's own traffic is already in the tunnel");
    });

    test('network off whenever the VPN is down, back on to connect', () async {
      await bloc.setKillSwitch(true);
      expect(ks.log, ['cut']);
      expect(bloc.value.networkCut, isTrue);

      await bloc.connect();
      expect(ks.log, ['cut', 'restore Wi-Fi,Ethernet']);
      expect(waits, 1);
      expect(bloc.value.connection.isConnected, isTrue);
      expect(bloc.value.networkCut, isFalse);

      // The connection drops.
      engine.events$.add(const EngineStopped('The Xray core stopped'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ks.log.last, 'cut');

      // A failed attempt leaves it off again.
      engine.failWith = const VpnException('boom');
      await bloc.connect();
      expect(ks.log.sublist(ks.log.length - 2), ['restore Wi-Fi,Ethernet', 'cut']);

      engine.failWith = null;
      await bloc.connect();
      await bloc.disconnect();
      expect(ks.log.last, 'cut');

      await bloc.setKillSwitch(false);
      expect(ks.log.last, 'restore Wi-Fi,Ethernet');
      expect(bloc.value.networkCut, isFalse);
    });

    test('stays off across a restart and on quit', () async {
      await bloc.setKillSwitch(true);
      final again = await make();
      expect(again.value.networkCut, isTrue);
      expect(ks.log, ['cut'], reason: 'already off: not cut twice');

      await again.connect();
      expect(ks.log.last, 'restore Wi-Fi,Ethernet');
      await again.dispose();
      expect(ks.log.last, 'cut', reason: 'quitting leaves no VPN, so the network goes off');
    });

    test('failures are reported, not thrown', () async {
      ks.failWith = const KillSwitchException('nmcli missing');
      await bloc.setKillSwitch(true);
      expect(bloc.value.networkCut, isFalse);
      expect(bloc.value.killSwitchError, contains('nmcli missing'));
    });
  });
}
