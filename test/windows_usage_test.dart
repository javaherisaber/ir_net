// The Windows ETW collector's file protocol and launch logic, with the
// PowerShell side faked (the helper itself can only run on Windows).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/data/usage.dart';
import 'package:ir_net/utils/usage_collectors.dart';
import 'package:ir_net/utils/windows_usage_helper.dart';

/// Decodes a PowerShell -EncodedCommand (base64 of UTF-16LE).
String decodeCommand(String encoded) {
  final bytes = base64.decode(encoded);
  return String.fromCharCodes([for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8]);
}

String argAfter(List<String> args, String flag) => args[args.indexOf(flag) + 1];

void main() {
  group('samples', () {
    test('flows become deltas named after the app', () {
      final deltas = parseWindowsSample({
        't': 1,
        'flows': [
          {'pid': 1, 'name': 'Google Chrome', 'exe': r'C:\Program Files\Google\Chrome\Application\chrome.exe', 'ip': '142.250.27.190', 'port': 443, 'iface': 'singbox_tun', 'kind': 'tunnel', 'rx': 1000, 'tx': 100},
          {'pid': 2, 'name': '', 'exe': r'C:\Program Files\v2rayN\bin\xray\xray.exe', 'ip': '198.51.100.16', 'port': 443, 'iface': 'Wi-Fi', 'kind': 'physical', 'rx': 5000, 'tx': 900},
          {'pid': 4, 'name': 'Windows (System)', 'exe': '', 'ip': '203.0.113.1', 'port': 445, 'iface': '', 'kind': 'other', 'rx': 0, 'tx': 0},
        ],
      });
      expect(deltas, hasLength(2), reason: 'idle flows are skipped');
      expect(deltas[0].app, 'Google Chrome');
      expect(deltas[0].iface, InterfaceKind.tunnel);
      expect(deltas[0].remotePort, 443);
      expect(deltas[1].app, 'xray', reason: 'no file description: the exe name');
      expect(deltas[1].iface, InterfaceKind.physical);
      expect(parseWindowsSample({'t': 1}), isEmpty);
    });

    test('app names', () {
      expect(windowsAppName(name: 'Microsoft Edge', exe: r'C:\x\msedge.exe'), 'Microsoft Edge');
      expect(windowsAppName(exe: r'C:\Program Files\Mozilla Firefox\firefox.EXE'), 'Firefox');
      expect(windowsAppName(exe: 'D:/apps/Telegram.exe'), 'Telegram');
      expect(windowsAppName(), 'Unknown app');
    });

    test('the helper script embeds the C# once, with the here-string closed on its own line', () {
      final script = buildWindowsHelperScript();
      expect(script, contains('public static class IrNetEtw'));
      expect(script, isNot(contains('__CSHARP__')));
      expect(RegExp(r"^'@$", multiLine: true).allMatches(script), hasLength(1));
      expect(windowsHelperCSharp, isNot(contains(r'$"')), reason: 'C# 5 has no string interpolation');
      expect(windowsHelperCSharp, isNot(contains('?.')), reason: 'C# 5 has no null-conditional operator');
    });
  });

  group('WindowsEtwCollector', () {
    late Directory dir;
    late List<List<String>> runs;
    late List<List<String>> starts;
    var elevated = false;
    var declined = false;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('irnet_win');
      runs = [];
      starts = [];
      elevated = false;
      declined = false;
    });
    tearDown(() => dir.delete(recursive: true));

    void helperBecomesReady() => File('${dir.path}/ready').writeAsStringSync('ok');

    WindowsEtwCollector collector({Duration stale = const Duration(seconds: 30)}) => WindowsEtwCollector(
          workDir: () async => dir,
          isElevated: () async => elevated,
          pollInterval: const Duration(milliseconds: 20),
          staleAfter: stale,
          readyTimeout: const Duration(seconds: 2),
          runPowerShell: (args) async {
            runs.add(args);
            if (declined) return ProcessResult(1, 1, '', 'Start-Process : This command cannot be run due to the error: The operation was canceled by the user.');
            helperBecomesReady();
            return ProcessResult(1, 0, '', '');
          },
          startPowerShell: (args) async {
            starts.add(args);
            helperBecomesReady();
          },
        );

    test('without admin rights it asks before prompting', () async {
      final c = collector();
      final setup = await c.checkSetup();
      expect(setup?.actionLabel, 'Start helper (admin)');
      expect(runs, isEmpty, reason: 'no admin prompt until the user asks');
    });

    test('the admin prompt runs exactly the script it wrote (hash-checked)', () async {
      final c = collector();
      await c.requestSetup();
      expect(await c.checkSetup(), isNull, reason: 'helper reported ready');

      final outer = decodeCommand(argAfter(runs.single, '-EncodedCommand'));
      expect(outer, startsWith("Start-Process -FilePath 'powershell.exe' -Verb RunAs"));
      final innerEncoded = RegExp(r'-EncodedCommand (\S+)').firstMatch(outer)!.group(1)!.replaceAll("'", '');
      final inner = decodeCommand(innerEncoded);
      final script = File('${dir.path}/helper.ps1').readAsStringSync();
      final hash = sha256.convert(utf8.encode(script)).toString().toUpperCase();
      expect(inner, contains("if (\$h -ne '$hash') { exit 3 }"));
      expect(inner, contains('-ParentPid $pid'));
      expect(inner, contains("-OutDir '${dir.path}'"));
      expect(script, buildWindowsHelperScript());
    });

    test('a declined prompt is explained on the next check', () async {
      declined = true;
      final c = collector();
      await c.requestSetup();
      final setup = await c.checkSetup();
      expect(setup?.message, contains('declined'));
    });

    test('when IRNet already runs as admin the helper starts without a prompt', () async {
      elevated = true;
      final c = collector();
      expect(await c.checkSetup(), isNull);
      expect(runs, isEmpty);
      expect(decodeCommand(argAfter(starts.single, '-EncodedCommand')), contains('[ScriptBlock]::Create'));
    });

    test('helper errors are reported', () async {
      elevated = true;
      final c = WindowsEtwCollector(
        workDir: () async => dir,
        isElevated: () async => true,
        readyTimeout: const Duration(seconds: 2),
        startPowerShell: (args) async =>
            File('${dir.path}/error.txt').writeAsStringSync('Starting the trace failed (error 5: administrator rights are needed)'),
      );
      final setup = await c.checkSetup();
      expect(setup?.message, contains('administrator rights are needed'));
    });

    test('reads, applies and deletes sample files; skips stale leftovers', () async {
      helperBecomesReady();
      final c = collector();
      final batches = <List<FlowDelta>>[];
      final sub = c.start().listen(batches.add);
      final fresh = DateTime.now().millisecondsSinceEpoch;
      File('${dir.path}/sample-1-1.json').writeAsStringSync(jsonEncode({
        't': fresh,
        'flows': [{'pid': 9, 'name': 'Telegram Desktop', 'exe': '', 'ip': '149.154.167.91', 'port': 443, 'kind': 'tunnel', 'rx': 300, 'tx': 30}],
      }));
      File('${dir.path}/sample-0-1.json').writeAsStringSync(jsonEncode({
        't': fresh - 600000, // from a previous run
        'flows': [{'pid': 9, 'name': 'Old', 'exe': '', 'ip': '1.1.1.1', 'port': 443, 'kind': 'tunnel', 'rx': 1, 'tx': 1}],
      }));
      File('${dir.path}/sample-2-1.tmp').writeAsStringSync('{"half written');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();
      expect(batches.expand((b) => b).map((d) => d.app), ['Telegram Desktop']);
      expect(File('${dir.path}/sample-1-1.json').existsSync(), isFalse);
      expect(File('${dir.path}/sample-0-1.json').existsSync(), isFalse);
      expect(File('${dir.path}/sample-2-1.tmp').existsSync(), isTrue, reason: 'not finished yet');
      await c.stop();
      expect(File('${dir.path}/stop').existsSync(), isTrue, reason: 'tells the helper to exit');
    });

    test('a helper that stops producing samples ends the stream with its error', () async {
      helperBecomesReady();
      File('${dir.path}/error.txt').writeAsStringSync('ProcessTrace stopped');
      final c = collector(stale: const Duration(milliseconds: 60));
      await expectLater(c.start(), emitsError(isA<Exception>().having((e) => '$e', 'message', contains('ProcessTrace stopped'))));
    });
  });
}
