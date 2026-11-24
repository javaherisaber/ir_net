import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'elevated_core.dart';
import 'system_proxy.dart';
import 'windows_tunnel_task.dart';
import 'xray_runner.dart';

class KillSwitchException implements Exception {
  const KillSwitchException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Turns the computer's network (Wi-Fi and Ethernet) off and back on.
///
/// [cut] returns what it turned off, as JSON, so [restore] (possibly after
/// a restart, the state is persisted) turns exactly that back on.
abstract class KillSwitch {
  static KillSwitch? forPlatform({CommandRunner? run}) {
    if (kIsWeb) return null;
    if (Platform.isMacOS) return MacKillSwitch(run: run);
    if (Platform.isWindows) return WindowsKillSwitch(run: run);
    if (Platform.isLinux) return LinuxKillSwitch(run: run);
    return null;
  }

  Future<Map<String, dynamic>> cut();

  Future<void> restore(Map<String, dynamic> state);
}

/// macOS: Wi-Fi radios off, other hardware services (Ethernet, USB and
/// Thunderbolt adapters, iPhone USB) disabled. networksetup asks for the
/// admin password once if the plain call is refused.
class MacKillSwitch extends KillSwitch {
  MacKillSwitch({CommandRunner? run}) : _ns = MacSystemProxy(run: run ?? Process.run);
  final MacSystemProxy _ns;

  @override
  Future<Map<String, dynamic>> cut() async {
    final services = await _ns.hardwareServices();
    final wifi = [for (final s in services) if (s.port == 'Wi-Fi' || s.port == 'AirPort') s.device];
    final others = [for (final s in services) if (s.port != 'Wi-Fi' && s.port != 'AirPort') s.service];
    await _ns.runAll([
      for (final d in wifi) ['-setairportpower', d, 'off'],
      for (final s in others) ['-setnetworkserviceenabled', s, 'off'],
    ]);
    return {'wifi': wifi, 'services': others};
  }

  @override
  Future<void> restore(Map<String, dynamic> state) async {
    await _ns.runAll([
      for (final s in (state['services'] as List? ?? const []).cast<String>()) ['-setnetworkserviceenabled', s, 'on'],
      for (final d in (state['wifi'] as List? ?? const []).cast<String>()) ['-setairportpower', d, 'on'],
    ]);
  }
}

/// Windows: disables the physical network adapters (Wi-Fi and Ethernet)
/// through PowerShell, which needs administrator rights (a UAC prompt
/// unless IRNet already runs as administrator).
class WindowsKillSwitch extends KillSwitch {
  WindowsKillSwitch({CommandRunner? run, this.useTask = true, Map<String, String>? environment})
      : _run = run ?? Process.run,
        _environment = environment;
  final CommandRunner _run;
  final bool useTask;
  final Map<String, String>? _environment;

  /// Through the Tunnel mode task when it's set up: no UAC prompt.
  Future<WindowsTunnelTask?> _task() async {
    if (!useTask) return null;
    final task = WindowsTunnelTask(run: _run, environment: _environment);
    final version = File('${task.programDir}\\VERSION');
    if (!version.existsSync()) return null;
    return (await _run('schtasks', ['/query', '/tn', WindowsTunnelTask.taskName])).exitCode == 0 ? task : null;
  }

  @override
  Future<Map<String, dynamic>> cut() async {
    final task = await _task();
    if (task != null) {
      try {
        await task.networkOff();
        return {'task': true};
      } on XrayStartException catch (e) {
        throw KillSwitchException(e.message);
      }
    }
    final out = await _elevated(r'''
$names = @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' } | ForEach-Object { $_.Name })
if ($names.Count -gt 0) { Disable-NetAdapter -Name $names -Confirm:$false }
$names -join "`n"
''');
    return {'adapters': out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList()};
  }

  @override
  Future<void> restore(Map<String, dynamic> state) async {
    if (state['task'] == true) {
      final task = await _task();
      if (task == null) throw const KillSwitchException('The Tunnel mode task is gone; turn the adapters on in Windows');
      try {
        return await task.networkOn();
      } on XrayStartException catch (e) {
        throw KillSwitchException(e.message);
      }
    }
    final names = (state['adapters'] as List? ?? const []).cast<String>();
    if (names.isEmpty) return;
    final list = names.map((n) => "'${n.replaceAll("'", "''")}'").join(', ');
    await _elevated('Enable-NetAdapter -Name @($list) -Confirm:\$false');
  }

  /// Runs [script] as administrator and returns what it printed.
  Future<String> _elevated(String script) async {
    final dir = await Directory.systemTemp.createTemp('irnet-ks');
    try {
      final out = p.join(dir.path, 'out.txt');
      final err = p.join(dir.path, 'error.txt');
      final wrapped = '''
\$ErrorActionPreference = 'Stop'
try {
  \$result = & { $script }
  Set-Content -Path '${out.replaceAll("'", "''")}' -Value (\$result -join "`n")
} catch {
  Set-Content -Path '${err.replaceAll("'", "''")}' -Value \$_.Exception.Message
}
''';
      final args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden '
          '-EncodedCommand ${ElevatedCoreLauncher.encodePowerShell(wrapped)}';
      final groups = '${(await _run('whoami', ['/groups'])).stdout}';
      final ProcessResult r;
      if (groups.contains('S-1-16-12288') || groups.contains('S-1-16-16384')) {
        r = await _run('powershell.exe', args.split(' '));
      } else {
        final outer = "Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '$args'";
        r = await _run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-EncodedCommand',
          ElevatedCoreLauncher.encodePowerShell(outer),
        ]);
      }
      if (r.exitCode != 0) {
        throw KillSwitchException('${r.stderr}'.contains('canceled by the user')
            ? 'The kill switch needs administrator rights; the Windows prompt was declined.'
            : 'The kill switch could not run: ${'${r.stderr}'.trim()}');
      }
      if (File(err).existsSync()) throw KillSwitchException(File(err).readAsStringSync().trim());
      return File(out).existsSync() ? File(out).readAsStringSync() : '';
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// Linux: NetworkManager's switch for all networking (Wi-Fi and wired).
class LinuxKillSwitch extends KillSwitch {
  LinuxKillSwitch({CommandRunner? run}) : _run = run ?? Process.run;
  final CommandRunner _run;

  Future<void> _nmcli(String state) async {
    final ProcessResult r;
    try {
      r = await _run('nmcli', ['networking', state]);
    } on ProcessException {
      throw const KillSwitchException('The kill switch needs NetworkManager (nmcli), which wasn\'t found');
    }
    if (r.exitCode != 0) throw KillSwitchException('nmcli networking $state failed: ${'${r.stderr}'.trim()}');
  }

  @override
  Future<Map<String, dynamic>> cut() async {
    await _nmcli('off');
    return {'nm': true};
  }

  @override
  Future<void> restore(Map<String, dynamic> state) => _nmcli('on');
}
