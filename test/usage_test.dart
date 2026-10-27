import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/app_database.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/data/usage_store.dart';
import 'package:ir_net/utils/app_names.dart';
import 'package:ir_net/utils/ip_enricher.dart';
import 'package:ir_net/utils/ip_tools.dart';
import 'package:ir_net/utils/process_path_native.dart' as native;
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Two delta samples in the format of
/// `nettop -L 0 -d -n -x -t external -J interface,state,bytes_in,bytes_out`
/// (addresses from documentation ranges).
const nettopOutput = '''
,interface,state,bytes_in,bytes_out,
apsd.384,,,5411,11737,
tcp4 10.8.0.2:49791<->17.57.146.20:5223,utun4,Established,5411,11737,
,interface,state,bytes_in,bytes_out,
apsd.384,,,0,0,
tcp4 10.8.0.2:49791<->17.57.146.20:5223,utun4,Established,0,0,
Google Chrome H.69472,,,1362,313,
tcp4 10.8.0.2:62255<->203.0.113.10:443,utun4,Established,362,113,
quic6 2001:db8::5.60455<->2606:4700::6810:84e5.443,en0,,1000,200,
tcp4 10.8.0.2:62000<->203.0.113.11:443,utun4,Closed,,,
PacketTunnel.86340,,,621,29854,
tcp4 192.168.11.157:59753<->198.51.100.16:21019,en0,Established,35,146,
tcp4 192.168.11.157:59721<->198.51.100.16:21019,en0,Established,586,29708,
mDNSResponder.527,,,598,0,
udp6 *.5353<->*.*,en0,,116,0,
udp4 *:5353<->*:*,en0,,482,0,
Weird, Name.777,,,50,0,
,interface,state,bytes_in,bytes_out,
''';

/// `ss -tinpeH` output (one socket line + one info line per socket).
const ssOutput = '''
ESTAB 0      0      192.168.1.10:54321 142.250.74.46:443 users:(("firefox",pid=2345,fd=89)) timer:(keepalive,9min,0) uid:1000 ino:123456 sk:1 cgroup:/user.slice <->
\t cubic wscale:7,7 rto:224 rtt:22.1/4.3 ato:40 mss:1388 cwnd:10 bytes_sent:2345 bytes_acked:2346 bytes_received:56789 segs_out:30 segs_in:40 send 5.0Mbps
ESTAB 0      0      [2001:db8::10]:40000 [2606:4700::1111]:443 users:(("telegram-deskto",pid=99,fd=12)) uid:1000 ino:777 sk:2 <->
\t cubic rto:204 rtt:3.5/1.2 bytes_acked:100 bytes_received:200 segs_out:3
ESTAB 0      0      10.0.0.5:22 198.51.100.9:51000 uid:0 ino:888 sk:3 <->
\t cubic rto:204 rtt:3.5/1.2 bytes_sent:10 bytes_acked:10 bytes_received:20
TIME-WAIT 0      0      192.168.1.10:54000 142.250.74.46:80 timer:(timewait,59sec,0) ino:0 sk:4
''';

String? processPathForTest(int pid) => native.processPath(pid);

void main() {
  group('nettop parser', () {
    List<NettopSample> parse(String text) {
      final parser = NettopParser();
      return text.split('\n').map(parser.addLine).whereType<NettopSample>().toList();
    }

    test('splits samples at headers and assigns flows to processes', () {
      final samples = parse(nettopOutput);
      expect(samples, hasLength(2), reason: 'a sample completes at the next header');
      final second = samples[1];
      expect(second.processes.keys, containsAll([384, 69472, 86340, 527, 777]));
      expect(second.processes[69472]!.name, 'Google Chrome H');
      expect(second.processes[777]!.name, 'Weird, Name', reason: 'commas in names survive');

      final chrome = second.flows.where((f) => f.pid == 69472).toList();
      expect(chrome.map((f) => f.remoteIp), ['203.0.113.10', '2606:4700::6810:84e5', '203.0.113.11']);
      expect(chrome[1].protocol, 'quic');
      expect(chrome[1].remotePort, 443);
      expect(chrome[1].localPort, 60455);
      expect(chrome[2].rx, 0, reason: 'closed flows have empty counters');

      final mdns = second.flows.where((f) => f.pid == 527).toList();
      expect(mdns.map((f) => f.remoteIp), ['', '']);
      expect(mdns.map((f) => f.localPort), [5353, 5353]);
    });

    test('endpoint notation', () {
      expect(NettopParser.splitEndpoint('17.1.2.3:443', v6: false), ('17.1.2.3', 443));
      expect(NettopParser.splitEndpoint('2001:4860::8888.53', v6: true), ('2001:4860::8888', 53));
      expect(NettopParser.splitEndpoint('::ffff:192.0.2.1.8080', v6: true), ('192.0.2.1', 8080));
      expect(NettopParser.splitEndpoint('fe80::1%en0.5353', v6: true), ('fe80::1', 5353));
      expect(NettopParser.splitEndpoint('*:*', v6: false), ('', null));
      expect(NettopParser.splitEndpoint('*.*', v6: true), ('', null));
    });

    test('deltas use resolved app names and keep bytes of vanished flows', () {
      final sample = parse(nettopOutput)[1];
      final deltas = nettopDeltas(sample, {69472: 'Google Chrome', 86340: 'V2Box'});
      final byApp = <String, int>{};
      for (final d in deltas) {
        byApp[d.app] = (byApp[d.app] ?? 0) + d.rx + d.tx;
      }
      expect(byApp['Google Chrome'], 1362 + 313);
      expect(byApp['V2Box'], 621 + 29854);
      expect(byApp['macOS DNS'], 598, reason: 'friendly name for mDNSResponder');
      expect(byApp['Weird, Name'], 50, reason: 'process bytes without listed flows');
      expect(byApp.containsKey('apsd'), isFalse, reason: 'idle flows are skipped');

      final quic = deltas.firstWhere((d) => d.remotePort == 443 && d.iface == InterfaceKind.physical);
      expect(quic.remoteIp, '2606:4700::6810:84e5');
      final tunnel = deltas.firstWhere((d) => d.remoteIp == '203.0.113.10');
      expect(tunnel.iface, InterfaceKind.tunnel);
    });

    test('proc_pidpath resolves app names, once per pid', () async {
      final asked = <int>[];
      final names = MacAppNames(pathOf: (pid) {
        asked.add(pid);
        return {
          69472: '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)',
          86340: '/Applications/V2Box.app/Contents/PlugIns/PacketTunnel.appex/Contents/MacOS/PacketTunnel',
        }[pid];
      }, runPs: (_) async => throw StateError('ps must not run when proc_pidpath works'));
      expect(await names.resolve({69472: 'Google Chrome H', 86340: 'PacketTunnel', 5: 'gone'}),
          {69472: 'Google Chrome', 86340: 'V2Box'});
      await names.resolve({69472: 'Google Chrome H', 86340: 'PacketTunnel'});
      expect(asked, [69472, 86340, 5], reason: 'cached after the first answer');
    });

    test('a pid reused by another program is resolved again', () async {
      var path = '/Applications/Telegram.app/Contents/MacOS/Telegram';
      final names = MacAppNames(pathOf: (_) => path);
      expect(await names.resolve({4242: 'Telegram'}), {4242: 'Telegram'});
      path = '/usr/bin/curl';
      expect(await names.resolve({4242: 'curl'}), {4242: 'curl'});
    });

    test('proc_pidpath works for a real process on macOS', () {
      final path = processPathForTest(pid);
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
    }, skip: !Platform.isMacOS);

    test('ps output resolves full app names when proc_pidpath is unavailable', () async {
      var calls = 0;
      final names = MacAppNames(pathOf: (_) => throw UnsupportedError('no ffi'), runPs: (pids) async {
        calls++;
        return ProcessResult(0, 0, '''
  384 /System/Library/PrivateFrameworks/ApplePushService.framework/apsd
69472 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)
86340 /Applications/V2Box.app/Contents/PlugIns/PacketTunnel.appex/Contents/MacOS/PacketTunnel
''', '');
      });
      final resolved = await names.resolve({384: 'apsd', 69472: 'Google Chrome H', 86340: 'PacketTunnel', 5: 'x'});
      expect(resolved, {384: 'Apple Push Notifications', 69472: 'Google Chrome', 86340: 'V2Box'});
      await names.resolve({384: 'apsd', 69472: 'Google Chrome H'});
      expect(calls, 1);
    });

    test('a failing ps falls back to nettop names without retrying', () async {
      var calls = 0;
      final names = MacAppNames(pathOf: (_) => throw UnsupportedError('no ffi'), runPs: (_) async {
        calls++;
        throw const ProcessException('/bin/ps', [], 'denied');
      });
      expect(await names.resolve({1: 'a'}), isEmpty);
      expect(await names.resolve({2: 'b'}), isEmpty);
      expect(calls, 1);
    });

    group('lifeline', () {
      late Directory dir;
      late String fake;

      // Behaves like nettop: ignores SIGPIPE and keeps writing samples.
      setUp(() async {
        dir = await Directory.systemTemp.createTemp('irnet_nettop');
        fake = '${dir.path}/fake-nettop';
        await File(fake).writeAsString('''#!/bin/sh
trap '' PIPE
if [ -p /dev/stdin ]; then echo pipe; else echo other; fi > "${dir.path}/stdin.type"
echo \$\$ > "${dir.path}/fake.pid"
while :; do
  echo ',interface,state,bytes_in,bytes_out,'
  echo 'curl.4242,,,1500,120,'
  echo 'tcp4 10.0.0.2:5000<->203.0.113.10:443,utun4,Established,1500,120,'
  sleep 0.2
done
''');
        await Process.run('chmod', ['+x', fake]);
      });
      tearDown(() => dir.delete(recursive: true));

      Future<int> fakePid() async {
        final file = File('${dir.path}/fake.pid');
        for (var i = 0; i < 50 && !file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return int.parse(file.readAsStringSync().trim());
      }

      bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

      Future<void> waitDead(int pid) async {
        for (var i = 0; i < 40 && alive(pid); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      test('emits deltas and stop() takes nettop down', () async {
        final collector = NettopCollector(
          executable: fake,
          names: MacAppNames(pathOf: (_) => null, runPs: (_) async => ProcessResult(0, 0, '', '')),
        );
        final deltas = await collector.start().first;
        expect(deltas.single.app, 'curl');
        expect(deltas.single.remoteIp, '203.0.113.10');
        expect(deltas.single.iface, InterfaceKind.tunnel);
        final pid = await fakePid();
        expect(alive(pid), isTrue);
        expect(File('${dir.path}/stdin.type').readAsStringSync().trim(), 'pipe',
            reason: 'nettop spins at full CPU when its stdin is /dev/null');
        await collector.stop();
        await waitDead(pid);
        expect(alive(pid), isFalse);
      });

      test('nettop exiting on its own is restarted, then reported', () async {
        final runs = File('${dir.path}/runs');
        final crashing = '${dir.path}/crashing-nettop';
        await File(crashing).writeAsString('''#!/bin/sh
echo run >> "${runs.path}"
echo ',interface,state,bytes_in,bytes_out,'
exit 3
''');
        await Process.run('chmod', ['+x', crashing]);
        final collector = NettopCollector(
          executable: crashing,
          restartDelay: const Duration(milliseconds: 10),
          names: MacAppNames(pathOf: (_) => null),
        );
        await expectLater(
          collector.start(),
          emitsError(isA<Exception>().having((e) => '$e', 'message', contains('exited with code 3'))),
        );
        expect(runs.readAsLinesSync(), hasLength(4), reason: 'first run + 3 restarts');
        await collector.stop();
      });

      test('nettop dies with the process holding the pipe, even on SIGKILL', () async {
        // The wrapper reads its lifeline from a FIFO whose only writer is a
        // separate process; killing that writer stands in for the app dying.
        final shell = await Process.start('/bin/sh', [
          '-c',
          'mkfifo "\$1/life"; '
              '/bin/sh -c "\$2" "\$3" < "\$1/life" > /dev/null & '
              'sleep 1000 > "\$1/life" & echo \$! > "\$1/holder.pid"; wait',
          'sh', dir.path, NettopCollector.lifeline, fake,
        ]);
        final pid = await fakePid();
        final holder = int.parse(File('${dir.path}/holder.pid').readAsStringSync().trim());
        expect(alive(pid), isTrue);
        Process.killPid(holder, ProcessSignal.sigkill);
        await waitDead(pid);
        expect(alive(pid), isFalse, reason: 'orphaned nettop would otherwise spin forever');
        await shell.exitCode.timeout(const Duration(seconds: 5));
      });
    }, skip: Platform.isWindows);

    test('collector arguments ask for delta CSV of external interfaces', () {
      final args = NettopCollector(interval: const Duration(seconds: 5)).arguments;
      expect(args, containsAllInOrder(['-L', '0', '-d', '-n', '-x', '-s', '5', '-t', 'external']));
      expect(args.last, 'interface,state,bytes_in,bytes_out');
    });
  });

  group('ss parser', () {
    test('reads addresses, owners and byte counters', () {
      final sockets = parseSsOutput(ssOutput);
      expect(sockets, hasLength(4));
      final firefox = sockets[0];
      expect(firefox.key, 'ino:123456');
      expect(firefox.localIp, '192.168.1.10');
      expect(firefox.remoteIp, '142.250.74.46');
      expect(firefox.remotePort, 443);
      expect(firefox.process, 'firefox');
      expect(firefox.pid, 2345);
      expect(firefox.rx, 56789);
      expect(firefox.tx, 2345, reason: 'bytes_sent preferred over bytes_acked');

      final telegram = sockets[1];
      expect(telegram.remoteIp, '2606:4700::1111');
      expect(telegram.localIp, '2001:db8::10');
      expect(telegram.tx, 100, reason: 'falls back to bytes_acked on older kernels');

      expect(sockets[2].process, isNull, reason: "other users' sockets have no owner");
      expect(sockets[3].rx, 0);
      expect(sockets[3].key, '192.168.1.10:54000>142.250.74.46:80', reason: 'inode 0 → address key');
    });

    test('endpoints', () {
      expect(splitSsEndpoint('[::ffff:192.0.2.4]:80'), ('192.0.2.4', 80));
      expect(splitSsEndpoint('192.0.2.4%eth0:22'), ('192.0.2.4', 22));
      expect(splitSsEndpoint('*:*'), ('', null));
      expect(splitSsEndpoint('garbage'), isNull);
    });

    test('first snapshot is a baseline; later ones yield deltas', () {
      final tracker = SsDeltaTracker();
      SsSocket s(String key, int rx, int tx) =>
          SsSocket(key: key, localIp: '10.0.0.2', remoteIp: '192.0.2.1', remotePort: 443, rx: rx, tx: tx);
      expect(tracker.update([s('a', 1000, 100)]), isEmpty);
      final d1 = tracker.update([s('a', 1500, 100), s('b', 40, 4)]);
      expect({for (final d in d1) d.key: (d.rx, d.tx)}, {'a': (500, 0), 'b': (40, 4)});
      final d2 = tracker.update([s('a', 10, 1)]); // key reused by a new socket
      expect(d2.single.rx, 10);
    });

    test('collector maps sockets to app deltas with interface kinds', () async {
      var call = 0;
      final collector = SsCollector(
        interval: const Duration(milliseconds: 20),
        runSs: () async => ProcessResult(0, 0, call++ == 0 ? '' : ssOutput, ''),
        localInterfaces: () async => {'192.168.1.10': 'wlan0', '2001:db8::10': 'wg0'},
      );
      final batch = await collector.start().first;
      await collector.stop();
      final byApp = {for (final d in batch) d.app: d};
      expect(byApp['Firefox']!.iface, InterfaceKind.physical);
      expect(byApp['Telegram']!.iface, InterfaceKind.tunnel);
      expect(byApp['System (other users)']!.rx, 20);
    });

    test('resuming starts from a new baseline', () async {
      var counters = 1000;
      String output() => 'ESTAB 0 0 10.0.0.2:5000 203.0.113.1:443 users:(("firefox",pid=1,fd=3)) ino:9 <->\n'
          '\t cubic bytes_sent:10 bytes_received:$counters\n';
      final batches = <List<FlowDelta>>[];
      final collector = SsCollector(
        interval: const Duration(milliseconds: 30),
        runSs: () async => ProcessResult(0, 0, output(), ''),
        localInterfaces: () async => const {},
      );
      var sub = collector.start().listen(batches.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      counters += 500;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sub.cancel();
      await collector.stop();
      expect(batches.expand((b) => b).map((d) => d.rx), [500]);

      batches.clear();
      counters += 1000000; // moved while paused
      sub = collector.start().listen(batches.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      counters += 7;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sub.cancel();
      await collector.stop();
      expect(batches.expand((b) => b).map((d) => d.rx), [7], reason: 'paused traffic is not counted');
    });

    test('collector reports a failure when ss is missing', () async {
      final collector = SsCollector(runSs: () async => throw const ProcessException('ss', [], 'not found'));
      await expectLater(collector.start(), emitsError(isA<Exception>()));
    });
  });

  group('names and addresses', () {
    test('app names from executable paths', () {
      expect(appNameFromPath('/Applications/Telegram.app/Contents/MacOS/Telegram'), 'Telegram');
      expect(
          appNameFromPath('/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/'
              'com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking'),
          'Safari / WebKit');
      expect(appNameFromPath('/usr/libexec/nsurlsessiond'), 'macOS background transfers');
      expect(appNameFromPath('/opt/tool/bin/custom-daemon'), 'custom-daemon');
    });

    test('VPN client detection', () {
      for (final name in ['V2Box', 'Happ', 'PacketTunnel', 'sing-box', 'Hiddify', 'OpenVPN Connect', 'WireGuard', 'xray', 'Tor']) {
        expect(looksLikeVpnApp(name), isTrue, reason: name);
      }
      for (final name in ['Google Chrome', 'Telegram', 'Monitor', 'Editor', 'Happy Hour', 'Spotify']) {
        expect(looksLikeVpnApp(name), isFalse, reason: name);
      }
    });

    test('interface kinds', () {
      expect(interfaceKindOf('utun4'), InterfaceKind.tunnel);
      expect(interfaceKindOf('wg0'), InterfaceKind.tunnel);
      expect(interfaceKindOf('ppp0'), InterfaceKind.tunnel);
      expect(interfaceKindOf('en0'), InterfaceKind.physical);
      expect(interfaceKindOf('wlan0'), InterfaceKind.physical);
      expect(interfaceKindOf(''), InterfaceKind.other);
    });

    test('address classification', () {
      expect(classifyIp('8.8.8.8'), IpKind.public);
      expect(classifyIp('192.168.1.1'), IpKind.private);
      expect(classifyIp('172.20.0.1'), IpKind.private);
      expect(classifyIp('172.32.0.1'), IpKind.public);
      expect(classifyIp('127.0.0.1'), IpKind.loopback);
      expect(classifyIp('169.254.3.4'), IpKind.linkLocal);
      expect(classifyIp('224.0.0.251'), IpKind.multicast);
      expect(classifyIp('255.255.255.255'), IpKind.multicast);
      expect(classifyIp('198.18.0.22'), IpKind.fakeIp);
      expect(classifyIp('100.100.1.1'), IpKind.cgnat);
      expect(classifyIp('2606:4700::1111'), IpKind.public);
      expect(classifyIp('fe80::1'), IpKind.linkLocal);
      expect(classifyIp('fd00::1'), IpKind.private);
      expect(classifyIp('::1'), IpKind.loopback);
      expect(classifyIp('ff02::fb'), IpKind.multicast);
      expect(classifyIp('::ffff:10.0.0.1'), IpKind.private);
      expect(classifyIp('nonsense'), IpKind.unspecified);
      expect(isLocalTraffic(IpKind.private), isTrue);
      expect(isLocalTraffic(IpKind.fakeIp), isFalse, reason: 'fake IPs are VPN-routed internet traffic');
    });

    test('registrable domains and domain keys', () {
      expect(registrableDomain('lhr48s27-in-f14.1e100.net.'), '1e100.net');
      expect(registrableDomain('server-18-66-1-2.fra56.r.cloudfront.net'), 'cloudfront.net');
      expect(registrableDomain('host.example.co.uk'), 'example.co.uk');
      expect(registrableDomain('mail.digikala.co.ir'), 'digikala.co.ir');
      expect(registrableDomain('localhost'), isNull);
      expect(registrableDomain('1.2.3.4'), isNull);

      expect(domainKeyFor(kind: IpKind.public, host: 'a.b.example.com', org: 'X', ip: '1.1.1.1'), 'example.com');
      expect(domainKeyFor(kind: IpKind.public, org: 'Cloudflare, Inc.', ip: '1.1.1.1'), '@Cloudflare, Inc.');
      expect(domainKeyFor(kind: IpKind.public, ip: '1.1.1.1'), '1.1.1.1');
      expect(domainKeyFor(kind: IpKind.fakeIp, ip: '198.18.0.1'), DomainKeys.fakeIp);
      expect(domainKeyFor(kind: IpKind.public, ip: ''), DomainKeys.unknown);
    });
  });

  group('IpEnricher', () {
    late List<List<String>> requests;
    late List<IpDetails> resolved;
    late DateTime now;

    setUp(() {
      requests = [];
      resolved = [];
      now = DateTime.utc(2026, 10, 26);
    });

    IpEnricher enricher(Future<IpBatchResult> Function(List<String>) answer) => IpEnricher(
          lookup: (ips) {
            requests.add(ips);
            return answer(ips);
          },
          onResolved: resolved.addAll,
          minGap: const Duration(hours: 1), // tests drive batches manually
          clock: () => now,
        );

    IpBatchResult answerAll(List<String> ips) => IpBatchResult([
          for (final ip in ips)
            IpDetails.fromGeoJs({
              'ip': ip,
              'country': 'Germany',
              'country_code': 'DE',
              'organization_name': 'Hetzner Online GmbH',
            }, now),
        ]);

    test('local addresses are classified without a lookup', () {
      final e = enricher((ips) async => answerAll(ips));
      e.enqueue('192.168.1.1');
      e.enqueue('198.18.0.4');
      expect(e.pending, 0);
      expect(resolved.map((d) => d.kind), [IpKind.private, IpKind.fakeIp]);
      expect(e['198.18.0.4']!.domainKey, DomainKeys.fakeIp);
      e.dispose();
    });

    test('public addresses are batched, looked up once and cached', () async {
      final e = enricher((ips) async => answerAll(ips));
      e.enqueue('203.0.113.1');
      e.enqueue('203.0.113.2');
      e.enqueue('203.0.113.1');
      expect(e.pending, 2);
      await e.runBatch();
      expect(requests.single, ['203.0.113.1', '203.0.113.2']);
      expect(e['203.0.113.2']!.countryCode, 'DE');
      expect(e['203.0.113.2']!.domainKey, '@Hetzner Online GmbH');
      e.enqueue('203.0.113.1');
      expect(e.pending, 0, reason: 'fresh results are reused');
      e.dispose();
    });

    test('reverse DNS names become the domain key', () async {
      final e = IpEnricher(
        lookup: (ips) async => answerAll(ips),
        reverse: (ip) async => ip.endsWith('.1') ? 'lhr48s27-in-f1.1e100.net' : null,
        onResolved: resolved.addAll,
        minGap: const Duration(hours: 1),
        clock: () => now,
      );
      e.enqueue('203.0.113.1');
      e.enqueue('203.0.113.2');
      await e.runBatch();
      expect(e['203.0.113.1']!.domainKey, '1e100.net');
      expect(e['203.0.113.1']!.countryCode, 'DE', reason: 'lookup data kept');
      expect(e['203.0.113.2']!.domainKey, '@Hetzner Online GmbH', reason: 'no PTR: network owner');
      expect(resolved.map((d) => d.host), ['lhr48s27-in-f1.1e100.net', null]);
      e.dispose();
    });

    test('rate limiting keeps the batch queued', () async {
      final e = enricher((ips) async => const IpBatchResult([], retryAfter: Duration(seconds: 40)));
      e.enqueue('203.0.113.1');
      await e.runBatch();
      expect(e.pending, 1);
      expect(resolved, isEmpty);
      e.dispose();
    });

    test('failures retry later; disabled lookups send nothing', () async {
      final e = enricher((ips) async => throw const SocketException('offline'));
      e.enqueue('203.0.113.9');
      await e.runBatch();
      expect(e.pending, 1);
      e.enabled = false;
      e.enqueue('203.0.113.10');
      expect(e.pending, 1);
      e.dispose();
    });

    test('geojs placeholders ("Unknown", "nil") are not data', () {
      final d = IpDetails.fromGeoJs(
          {'ip': '203.0.113.5', 'organization_name': 'Unknown', 'latitude': 'nil', 'country_code': ''}, now);
      expect(d.countryCode, isNull);
      expect(d.org, isNull);
      expect(d.domainKey, '203.0.113.5');
    });
  });

  group('UsageStore', () {
    late Database db;
    late UsageStore store;
    final t0 = DateTime.utc(2026, 10, 26, 9).millisecondsSinceEpoch ~/ 1000;

    setUpAll(sqfliteFfiInit);
    setUp(() async {
      db = await AppDatabase.openAt(inMemoryDatabasePath, factory: databaseFactoryFfiNoIsolate);
      store = UsageStore(db);
    });
    tearDown(() => db.close());

    Future<void> seed() async {
      await store.add({
        UsageKey(t0, 'Google Chrome', '203.0.113.1', InterfaceKind.tunnel): (1000, 100),
        UsageKey(t0 + 60, 'Google Chrome', '203.0.113.1', InterfaceKind.tunnel): (500, 50),
        UsageKey(t0, 'Telegram', '198.51.100.7', InterfaceKind.tunnel): (300, 30),
        UsageKey(t0, 'Telegram', '', InterfaceKind.other): (5, 5),
        UsageKey(t0, 'V2Box', '192.0.2.200', InterfaceKind.physical): (2000, 200),
      });
      await store.saveIpDetails([
        IpDetails(ip: '203.0.113.1', kind: IpKind.public, updatedAt: DateTime.now(), host: 'edge.example.com', countryCode: 'DE', country: 'Germany', org: 'Example GmbH'),
        IpDetails(ip: '198.51.100.7', kind: IpKind.public, updatedAt: DateTime.now(), countryCode: 'NL', country: 'Netherlands', org: 'Telegram Messenger Inc'),
      ]);
    }

    test('add accumulates; records join domain and country', () async {
      await seed();
      await store.add({UsageKey(t0, 'Telegram', '198.51.100.7', InterfaceKind.tunnel): (1, 1)});
      final records = await store.records(t0, t0 + 3600);
      UsageRecord find(String app, String domain) =>
          records.firstWhere((r) => r.app == app && r.domain == domain);
      expect(find('Google Chrome', 'example.com').total, 1650);
      expect(find('Google Chrome', 'example.com').country, 'DE');
      expect(find('Telegram', '@Telegram Messenger Inc').total, 332);
      expect(find('Telegram', DomainKeys.unknown).total, 10);
      expect(find('V2Box', '192.0.2.200').country, '', reason: 'not looked up yet');
      expect(await store.countryNames(), {'DE': 'Germany', 'NL': 'Netherlands'});
      expect((await store.providerNames())['example.com'], 'Example GmbH');
    });

    test('summary hides the VPN transport copy while a tunnel is active', () async {
      await seed();
      final records = await store.records(t0, t0 + 3600);
      final summary = UsageSummary(
          range: UsageRange.today, from: t0, to: t0 + 3600, records: records, countryNames: const {}, providerNames: const {});
      expect(summary.tunnelActive, isTrue);
      expect(summary.hiddenVpnApps, {'V2Box'});
      expect(summary.hiddenVpnBytes, 2200);
      expect(summary.total, 1650 + 330 + 10);
      expect(summary.entries[UsageDimension.app]!.map((e) => e.key), ['Google Chrome', 'Telegram']);
      expect(summary.entries[UsageDimension.domain]!.first.topCountry, 'DE');

      final withVpn = UsageSummary(
          range: UsageRange.today, from: t0, to: t0 + 3600, records: records,
          countryNames: const {}, providerNames: const {}, includeVpnTransport: true);
      expect(withVpn.total, summary.total + 2200);

      final filtered = UsageSummary(
          range: UsageRange.today, from: t0, to: t0 + 3600, records: records,
          countryNames: const {}, providerNames: const {}, filters: const {UsageDimension.app: 'Telegram'});
      expect(filtered.total, 340);
      expect(filtered.entries[UsageDimension.country]!.map((e) => e.key), ['NL', '']);
    });

    test('without tunnel traffic nothing is hidden (proxy-mode VPNs)', () {
      final summary = UsageSummary(
        range: UsageRange.today, from: 0, to: 1, countryNames: const {}, providerNames: const {},
        records: const [
          UsageRecord(app: 'V2Box', domain: 'x', country: 'DE', iface: InterfaceKind.physical, rx: 10, tx: 0),
        ],
      );
      expect(summary.tunnelActive, isFalse);
      expect(summary.total, 10);
    });

    test('timeline bins with filters and VPN exclusion', () async {
      await seed();
      final all = await store.timeline(from: t0, to: t0 + 3600, binSeconds: 60);
      expect(all.map((b) => b.start), [t0, t0 + 60]);
      expect(all.first.total, 1100 + 330 + 10 + 2200);
      final noVpn = await store.timeline(from: t0, to: t0 + 3600, binSeconds: 60, excludeVpnApps: {'V2Box'});
      expect(noVpn.first.total, 1100 + 330 + 10);
      final de = await store.timeline(
          from: t0, to: t0 + 3600, binSeconds: 3600, filters: const {UsageDimension.country: 'DE'});
      expect(de.single.total, 1650);
      final domain = await store.timeline(
          from: t0, to: t0 + 3600, binSeconds: 3600, filters: const {UsageDimension.domain: DomainKeys.unknown});
      expect(domain.single.total, 10);
    });

    test('compaction rolls old minutes into hours without losing bytes', () async {
      await seed();
      final now = DateTime.fromMillisecondsSinceEpoch(t0 * 1000).add(const Duration(days: 4));
      await store.add({UsageKey(now.millisecondsSinceEpoch ~/ 1000, 'Google Chrome', '203.0.113.1', InterfaceKind.tunnel): (7, 7)});
      final before = await store.records(0, now.millisecondsSinceEpoch ~/ 1000 + 60);
      await store.compact(now);
      final minuteRows = await db.rawQuery('SELECT COUNT(*) AS n FROM usage_minute');
      expect(minuteRows.single['n'], 1, reason: 'only the recent minute stays');
      final after = await store.records(0, now.millisecondsSinceEpoch ~/ 1000 + 60);
      int total(List<UsageRecord> rs) => rs.fold(0, (s, r) => s + r.total);
      expect(total(after), total(before));
      final hourly = after.firstWhere((r) => r.app == 'Google Chrome' && r.country == 'DE');
      expect(hourly.domain, 'example.com');
      final timeline = await store.timeline(from: 0, to: now.millisecondsSinceEpoch ~/ 1000 + 60, binSeconds: 86400);
      expect(timeline.fold(0, (s, b) => s + b.total), total(before));
      await store.compact(now); // idempotent
      expect(total(await store.records(0, now.millisecondsSinceEpoch ~/ 1000 + 60)), total(before));
    });

    test('ranges', () {
      final now = DateTime(2026, 10, 26, 15, 30);
      int s(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      expect(UsageRange.today.bounds(now).$1, s(DateTime(2026, 10, 26)));
      expect(UsageRange.yesterday.bounds(now), (s(DateTime(2026, 10, 25)), s(DateTime(2026, 10, 26))));
      expect(UsageRange.yesterday.bounds(DateTime(2026, 11, 1, 1)).$1, s(DateTime(2026, 10, 31)),
          reason: 'month boundary');
      final (from, to) = UsageRange.last10m.bounds(now);
      expect(to - from, 600);
      expect(UsageRange.all.bounds(now).$1, 0);
    });
  });
}
