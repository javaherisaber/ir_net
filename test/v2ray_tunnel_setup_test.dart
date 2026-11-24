import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/v2ray/kill_switch.dart';
import 'package:ir_net/v2ray/linux_tunnel_setup.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/windows_tunnel_task.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:ir_net/v2ray/xray_runner.dart';
import 'package:path/path.dart' as p;

/// Counts (), [] and {} outside quotes and comments in a PowerShell script,
/// and checks every @' here-string is closed: a cheap structural check where
/// PowerShell itself isn't available.
String? _psStructure(String script) {
  final stack = <String>[];
  const pairs = {')': '(', ']': '[', '}': '{'};
  var inHere = false;
  for (final line in script.split('\n')) {
    if (inHere) {
      if (line.startsWith("'@")) inHere = false;
      continue;
    }
    var i = 0;
    String? quote;
    while (i < line.length) {
      final ch = line[i];
      if (quote != null) {
        if (ch == quote) {
          if (quote == "'" && i + 1 < line.length && line[i + 1] == "'") {
            i += 2;
            continue;
          }
          quote = null;
        } else if (quote == '"' && ch == '`') {
          i++;
        }
      } else if (ch == '#') {
        break;
      } else if (ch == '@' && i + 1 < line.length && line[i + 1] == "'" && line.trim().endsWith("@'")) {
        inHere = true;
        break;
      } else if (ch == "'" || ch == '"') {
        quote = ch;
      } else if ('([{'.contains(ch)) {
        stack.add(ch);
      } else if (pairs.containsKey(ch)) {
        if (stack.isEmpty || stack.removeLast() != pairs[ch]) return 'unbalanced "$ch" in: $line';
      }
      i++;
    }
    if (quote != null) return 'unterminated string in: $line';
  }
  if (inHere) return 'unterminated here-string';
  return stack.isEmpty ? null : 'unclosed ${stack.join()}';
}

void main() {
  group('Linux', () {
    test('the TUN gets a fixed name so DNS can be cleaned up by it', () {
      final profile = ShareLinkParser.parse('trojan://pw@t.example.com:443#T');
      final c = XrayConfigBuilder.tunnel(profile, httpPort: 1, os: 'linux', linuxResolved: true);
      expect((c['inbounds'] as List).first['settings']['name'], 'irnet0');
    });

    test('the installer gives a group-only copy of the core just the network capabilities', () async {
      final script = LinuxTunnelSetup.installScript(
          user: 'mehdi', group: 'mehdi', source: "/opt/IR Net/xray", version: 'xray=abc');
      final r = await Process.run('/bin/sh', ['-n', '-c', script]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(script, contains("install -o root -g 'mehdi' -m 750 '/opt/IR Net/xray' \"\$D/xray.new\""));
      expect(script, contains('setcap cap_net_admin,cap_net_raw,cap_net_bind_service+ep "\$D/xray.new"'));
      expect(script.indexOf('setcap'), lessThan(script.indexOf('mv -f')), reason: 'never a capable binary half-written');
      expect(script, contains('Identity=unix-user:mehdi'));
      expect(script, contains('ResultActive=yes'));
    });

    test('the polkit rule allows exactly the DNS changes, for this user, in an active local session', () async {
      final script = LinuxTunnelSetup.installScript(user: 'mehdi', group: 'mehdi', source: '/x', version: 'v');
      final rule = RegExp(r"<<'IRNET_POLKIT_EOF'\n([\s\S]*?)\nIRNET_POLKIT_EOF").firstMatch(script)!.group(1)!;
      final js = '''
var rules = [];
var polkit = { addRule: function (f) { rules.push(f); }, Result: { YES: 'yes' } };
$rule
function ask(id, user, local, active) { return String(rules[0]({ id: id }, { user: user, local: local, active: active })); }
[ask('org.freedesktop.resolve1.set-dns-servers', 'mehdi', true, true),
 ask('org.freedesktop.resolve1.revert', 'mehdi', true, true),
 ask('org.freedesktop.resolve1.set-dns-servers', 'eve', true, true),
 ask('org.freedesktop.resolve1.set-dns-servers', 'mehdi', false, true),
 ask('org.freedesktop.NetworkManager.settings.modify.system', 'mehdi', true, true)].join(',')
''';
      final r = await Process.run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', js]);
      expect(r.stdout.toString().trim(), 'yes,yes,undefined,undefined,undefined', reason: '${r.stderr}');
    }, skip: !Platform.isMacOS);

    test('setup reports when it cannot be done, and a cancelled prompt', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> run(String exe, List<String> args, {int code = 0, bool setcap = true}) async {
        calls.add([exe, ...args]);
        if (exe == 'sh') return ProcessResult(0, setcap ? 0 : 1, '', '');
        if (exe == 'id') return ProcessResult(0, 0, args.first == '-un' ? 'mehdi\n' : 'staff\n', '');
        if (exe == 'pkexec') return ProcessResult(0, code, '', '');
        return ProcessResult(0, 0, '', '');
      }

      final noSetcap = LinuxTunnelSetup(run: (e, a) => run(e, a, setcap: false));
      expect(noSetcap.install('/x'), throwsA(isA<LinuxTunnelSetupUnavailable>()));

      final tmp = await Directory.systemTemp.createTemp('irnet_linux');
      final core = File('${tmp.path}/xray')..writeAsStringSync('core');
      final cancelled = LinuxTunnelSetup(run: (e, a) => run(e, a, code: 126));
      await expectLater(cancelled.install(core.path),
          throwsA(isA<XrayStartException>().having((e) => e.message, 'message', contains('cancelled'))));
      final pk = calls.lastWhere((c) => c.first == 'pkexec');
      expect(pk.sublist(0, 3), ['pkexec', '/bin/sh', '-c']);
      expect(pk[3], contains("install -o root -g 'staff' -m 750 '${core.path}'"));
      await tmp.delete(recursive: true);
    });
  });

  group('Windows', () {
    late Directory tmp;
    late Map<String, String> env;
    late WindowsTunnelTask task;
    final runs = <List<String>>[];

    /// Answers like the scheduled task would: reads request.json and writes
    /// done-<id>.txt into the state folder.
    Future<ProcessResult> fakeRun(String exe, List<String> args) async {
      runs.add([exe, ...args]);
      if (exe == 'schtasks' && args.first == '/run') {
        final request = jsonDecode(File(p.windows.join(task.requestDir, 'request.json')).readAsStringSync()) as Map;
        final state = Directory(task.stateDir)..createSync(recursive: true);
        final answer = switch (request['action']) {
          'tunnel' => File(p.windows.join(task.requestDir, 'config.json')).existsSync() ? 'started' : 'missing',
          _ => 'ok',
        };
        // (The instance reads it with the host's separator.)
        if (request['action'] == 'tunnel') File(p.join(state.path, 'pid')).writeAsStringSync('4242');
        File(p.windows.join(state.path, 'done-${request['id']}.txt')).writeAsStringSync(answer);
        return ProcessResult(0, 0, 'SUCCESS', '');
      }
      if (exe == 'schtasks' && args.first == '/query') return ProcessResult(0, 0, '', '');
      return ProcessResult(0, 0, '', '');
    }

    setUp(() async {
      runs.clear();
      tmp = await Directory.systemTemp.createTemp('irnet_win');
      env = {'ProgramData': '${tmp.path}/pd', 'LOCALAPPDATA': '${tmp.path}/la'};
      task = WindowsTunnelTask(run: fakeRun, environment: env);
    });
    tearDown(() async => tmp.delete(recursive: true));

    test('a tunnel request carries the config, IRNet\'s pid and the geo folder', () async {
      final instance = await task.startCore(config: '{"a":1}', assetDir: r'C:\Users\me\AppData\Roaming\ir\assets', parentPid: 77);
      final request = jsonDecode(File(p.windows.join(task.requestDir, 'request.json')).readAsStringSync()) as Map;
      expect(request['action'], 'tunnel');
      expect(request['pid'], 77);
      expect(request['assets'], r'C:\Users\me\AppData\Roaming\ir\assets');
      expect(File(p.windows.join(task.requestDir, 'config.json')).readAsStringSync(), '{"a":1}');
      expect(runs.where((r) => r.first == 'schtasks').single, ['schtasks', '/run', '/tn', 'IRNet Tunnel']);
      expect(instance.pid, 4242);
      await task.stopCore();
      expect(File(p.windows.join(task.requestDir, 'stop')).existsSync(), isTrue);
    });

    test('the kill switch goes through the task once it is set up', () async {
      final ks = WindowsKillSwitch(run: fakeRun, environment: env);
      Directory(task.programDir).createSync(recursive: true);
      File(p.windows.join(task.programDir, 'VERSION')).writeAsStringSync('v');
      final state = await ks.cut();
      expect(state, {'task': true});
      expect(jsonDecode(File(p.windows.join(task.requestDir, 'request.json')).readAsStringSync())['action'], 'net-off');
      await ks.restore(state);
      expect(jsonDecode(File(p.windows.join(task.requestDir, 'request.json')).readAsStringSync())['action'], 'net-on');
      expect(runs.where((r) => r.first == 'powershell.exe'), isEmpty, reason: 'no UAC prompt');
    });

    test('the scripts are well formed', () {
      expect(_psStructure(WindowsTunnelTask.helperScript), isNull);
      final install = WindowsTunnelTask.installScript(
          source: r"C:\Program Files\IRNet", userName: r"DESKTOP-1\o'brien", userSid: 'S-1-5-21-1-2-3-1001', version: 'v');
      expect(_psStructure(install), isNull);
      expect(WindowsTunnelTask.helperScript.split('\n').where((l) => l.startsWith("'@")), isEmpty,
          reason: 'it is embedded in a here-string');
      expect(install, contains("-UserId 'DESKTOP-1\\o''brien' -LogonType Interactive -RunLevel Highest"));
      expect(install, contains("'*S-1-5-21-1-2-3-1001:(OI)(CI)RX'"));
      expect(install, contains('-ExecutionTimeLimit ([TimeSpan]::Zero)'));
    });
  });
}
