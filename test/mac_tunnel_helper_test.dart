import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/mac_tunnel_helper.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:ir_net/v2ray/xray_runner.dart';

// Runs the real helper script unprivileged against a test folder
// (IRNET_HELPER_TEST_ROOT), with stand-ins for xray and networksetup, and
// drives it through MacTunnelHelper the way IRNet does (minus sudo).

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the core is identified by its code hash, which re-signing keeps', () {
    const out = 'Executable=/Applications/IRNet.app/Contents/MacOS/xray\n'
        'Hash type=sha256 size=32\n'
        'CandidateCDHash sha256=578b9cc4ea0685ca716922f7479b5c8eef51ea97\n'
        'CDHash=578b9cc4ea0685ca716922f7479b5c8eef51ea97\n'
        'Signed Time=Nov 24, 2026 at 18:00:58\n';
    expect(MacTunnelHelper.cdHashIn(out), '578b9cc4ea0685ca716922f7479b5c8eef51ea97');
    expect(MacTunnelHelper.cdHashIn('code object is not signed at all'), isNull);
  });

  late Directory root;
  late String helper;
  late File calls;
  late Map<String, String> env;

  final profile = ShareLinkParser.parse(
      'vless://2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60@de1.example.com:443?security=tls&sni=de1.example.com#DE');
  String tunnelConfig() => XrayConfigBuilder.encode(XrayConfigBuilder.tunnel(profile, httpPort: 10809, os: 'macos'));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('irnet helper');
    final dir = Directory('${root.path}/helper')..createSync();
    helper = '${dir.path}/irnet-helper';
    File(helper).writeAsStringSync(MacTunnelHelper.helperScript);
    File('${dir.path}/validate.js').writeAsStringSync(MacTunnelHelper.validatorScript);
    calls = File('${root.path}/networksetup.calls');
    File('${dir.path}/networksetup').writeAsStringSync('#!/bin/sh\necho "\$*" >> "${calls.path}"\n'
        'case "\$1" in -getdnsservers) echo "There aren\'t any DNS Servers set on \$2.";; esac\n');
    File('${dir.path}/xray').writeAsStringSync('#!/bin/sh\necho "args: \$*"\necho "assets: \$XRAY_LOCATION_ASSET"\n'
        'echo "config: \$(cat "\$3")"\ntrap \'echo got TERM; exit 0\' TERM\nwhile :; do sleep 0.1; done\n');
    for (final f in ['irnet-helper', 'networksetup', 'xray']) {
      await Process.run('chmod', ['755', '${dir.path}/$f']);
    }
    env = {'IRNET_HELPER_TEST_ROOT': root.path};
  });

  tearDown(() async {
    await Process.run('/bin/sh', [helper, 'stop'], environment: env);
    await root.delete(recursive: true);
  });

  /// MacTunnelHelper with "sudo -n <helper>" replaced by "sh <test helper>".
  MacTunnelHelper tunnelHelper() {
    List<String> unsudo(List<String> args) => [helper, ...args.sublist(2)];
    return MacTunnelHelper(
      run: (exe, args) => exe == '/usr/bin/sudo'
          ? Process.run('/bin/sh', unsudo(args), environment: env)
          : Process.run(exe, args),
      start: (exe, args) => Process.start('/bin/sh', unsudo(args), environment: env),
      statePath: '${root.path}/state',
    );
  }

  test('starts the core from stdin, points DNS into the tunnel, and undoes it on stop', () async {
    final assets = Directory('${root.path}/assets')..createSync();
    File('${assets.path}/geoip.dat').writeAsStringSync('geo');
    Link('${assets.path}/link.dat').createSync('/etc/hosts');

    final instance = await tunnelHelper().startCore(
      config: tunnelConfig(),
      assetDir: assets.path,
      dnsServices: const ['Wi-Fi', 'USB 10/100/1000 LAN'],
    );
    final state = '${root.path}/state';
    await _until(() => File('$state/xray.log').readAsStringSync().contains('config:'));
    final log = File('$state/xray.log').readAsStringSync();
    expect(log, contains('args: run -c $state/config.json'));
    expect(log, contains('assets: $state/assets'));
    final config = jsonDecode(log.split('config: ').last.split('\n').first) as Map;
    expect(config['log'], {'loglevel': 'warning'}, reason: 'the helper rewrites the log section');
    expect(config['inbounds'][0]['protocol'], 'tun');
    expect(File('$state/assets/geoip.dat').existsSync(), isTrue);
    expect(File('$state/assets/link.dat').existsSync(), isFalse, reason: 'symlinks are not followed');
    expect(calls.readAsLinesSync(), [
      '-getdnsservers Wi-Fi',
      '-setdnsservers Wi-Fi 1.1.1.1 8.8.8.8',
      '-getdnsservers USB 10/100/1000 LAN',
      '-setdnsservers USB 10/100/1000 LAN 1.1.1.1 8.8.8.8',
    ]);
    expect(instance.pid, isNotNull);
    expect(instance.hasExited, isFalse);

    await instance.stop();
    expect(instance.hasExited, isTrue);
    expect(File('$state/xray.log').readAsStringSync(), contains('got TERM'));
    expect(calls.readAsLinesSync().skip(4), [
      '-setdnsservers Wi-Fi Empty',
      '-setdnsservers USB 10/100/1000 LAN Empty',
    ]);
    expect(File('$state/config.json').existsSync(), isFalse);
  });

  test('stops the core when IRNet goes away, and a new start replaces an old one', () async {
    final sleeper = await Process.start('sleep', ['30']);
    final first = await tunnelHelper().startCore(
        config: tunnelConfig(), assetDir: root.path, dnsServices: const [], parentPid: sleeper.pid);
    await _until(() => first.pid != null);
    sleeper.kill();
    await first.exited.timeout(const Duration(seconds: 10));

    final second =
        await tunnelHelper().startCore(config: tunnelConfig(), assetDir: root.path, dnsServices: const []);
    await _until(() => second.pid != null);
    final secondPid = second.pid;
    final third =
        await tunnelHelper().startCore(config: tunnelConfig(), assetDir: root.path, dnsServices: const []);
    await _until(() => third.pid != null);
    expect(third.pid, isNot(secondPid));
    // Starting again stopped the earlier core (allow a moment for it to be reaped).
    await _until(() => !Process.killPid(secondPid!, ProcessSignal.sigcont));
    await third.stop();
  });

  test('refuses configs IRNet would never send', () async {
    final base = jsonDecode(tunnelConfig()) as Map<String, dynamic>;
    Future<String> attempt(void Function(Map<String, dynamic> c) change) async {
      final c = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      change(c);
      try {
        await tunnelHelper().startCore(config: jsonEncode(c), assetDir: root.path, dnsServices: const []);
        return 'started';
      } on XrayStartException catch (e) {
        return e.message;
      }
    }

    expect(await attempt((c) => c['api'] = {'tag': 'api'}), contains('unexpected section "api"'));
    expect(await attempt((c) => (c['inbounds'] as List)[1]['listen'] = '0.0.0.0'), contains('not on 127.0.0.1'));
    expect(await attempt((c) => (c['inbounds'] as List).add({'protocol': 'dokodemo-door', 'listen': '127.0.0.1'})),
        contains('inbound "dokodemo-door"'));
    expect(
        await attempt((c) => (c['outbounds'] as List)[0]['streamSettings']['tlsSettings']['masterKeyLog'] = '/etc/x'),
        contains('field "masterKeyLog"'));
    expect(
        await attempt((c) => (c['routing']['rules'] as List).add({
              'domain': ['ext:../../etc/x.dat:a'],
              'outboundTag': 'direct'
            })),
        contains('geo file path'));
    expect(
        await attempt((c) =>
            (c['outbounds'] as List)[0]['streamSettings']['tlsSettings']['MasterKeyLog'] = '/etc/x'),
        contains('field "MasterKeyLog"'),
        reason: "Go's JSON decoder would read it as masterKeyLog");
    expect(await attempt((c) => c['LOG'] = {'loglevel': 'debug'}), contains('unexpected section "LOG"'));
    expect(await attempt((c) => (c['outbounds'] as List)[0]['settings']['vnext'][0]['address'] = '/var/run/docker.sock'),
        contains('Unix socket in "address"'));
    expect(await attempt((c) => (c['outbounds'] as List)[1]['settings'] = {'redirect': '@abstract'}),
        contains('Unix socket in "redirect"'));
    expect(await attempt((c) => c['log'] = {'access': '/etc/passwd'}), 'started',
        reason: 'log files are dropped, not refused');
    expect(File('${root.path}/state/config.json').readAsStringSync(), isNot(contains('/etc/passwd')));
  });

  test('accepts a WireGuard tunnel', () async {
    const priv = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
    const pub = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';
    final wg = ShareLinkParser.parse('wireguard://${Uri.encodeComponent(priv)}@162.159.192.1:2408'
        '?publickey=${Uri.encodeComponent(pub)}&address=172.16.0.2%2F32&reserved=1,2,3#W');
    final instance = await tunnelHelper().startCore(
      config: XrayConfigBuilder.encode(XrayConfigBuilder.tunnel(wg, httpPort: 10809, os: 'macos')),
      assetDir: root.path,
      dnsServices: const [],
    );
    await _until(() => instance.pid != null);
    expect(File('${root.path}/state/config.json').readAsStringSync(), contains('"protocol":"wireguard"'));
    await instance.stop();
  });

  test('passes on only the networksetup commands IRNet uses', () async {
    final h = tunnelHelper();
    expect(await h.networksetup(['-setairportpower', 'en0', 'off']), isTrue);
    expect(calls.readAsLinesSync(), ['-setairportpower en0 off']);
    final r = await Process.run('/bin/sh', [helper, 'net', '-removenetworkservice', 'Wi-Fi'], environment: env);
    expect(r.exitCode, 2);
    expect('${r.stderr}', contains('not allowed'));
    expect((await Process.run('/bin/sh', [helper, 'ping'], environment: env)).stdout, 'ok\n');
  });

  test('the installer is valid sh and checks the sudoers rule before installing it', () async {
    final script = MacTunnelHelper.installScript(
        user: 'mehdi', xrayPath: '/Applications/IRNet.app/Contents/MacOS/xray', version: 'helper=a xray=b');
    final r = await Process.run('/bin/sh', ['-n', '-c', script]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(script.indexOf('visudo -cf'), lessThan(script.indexOf('install -o root -g wheel -m 440')));
    expect(script, contains("'mehdi' 'mehdi' \"\$D/irnet-helper\""));
  });
}
