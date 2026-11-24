import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'elevated_core.dart';
import 'xray_runner.dart';

/// Password-free Tunnel mode (and kill switch) on Windows.
///
/// The TUN adapter needs administrator rights. Instead of a UAC prompt on
/// every connect, a one-time setup (one UAC prompt) copies a helper script
/// and the core into %ProgramData%\IRNet (writable by administrators only)
/// and registers a scheduled task that runs the helper with the user's full
/// administrator rights. Windows lets the user start their own task with
/// `schtasks /run` without a prompt.
///
/// A task takes no arguments, so IRNet leaves the request in
/// %LOCALAPPDATA%\IRNet\tunnel (request.json, plus config.json for the
/// tunnel). The helper only reads there (never writes, never follows
/// links), refuses any config IRNet wouldn't generate, and keeps everything
/// it writes in %ProgramData%\IRNet\state, which only it can write and only
/// this user can read.
class WindowsTunnelTask {
  WindowsTunnelTask({
    Future<ProcessResult> Function(String, List<String>)? run,
    Map<String, String>? environment,
  })  : _run = run ?? Process.run,
        _env = environment ?? Platform.environment;

  final Future<ProcessResult> Function(String, List<String>) _run;
  final Map<String, String> _env;

  static const taskName = 'IRNet Tunnel';

  String get programDir => p.windows.join(_env['ProgramData'] ?? r'C:\ProgramData', 'IRNet');
  String get stateDir => p.windows.join(programDir, 'state');
  String get requestDir =>
      p.windows.join(_env['LOCALAPPDATA'] ?? p.windows.join(_env['USERPROFILE'] ?? '', 'AppData', 'Local'), 'IRNet',
          'tunnel');

  static String? _hash;
  static String? _hashPath;

  static Future<String> expectedVersion(String xrayExe) async {
    if (_hash == null || _hashPath != xrayExe) {
      _hash = await compute(_hashFiles, xrayExe);
      _hashPath = xrayExe;
    }
    final scripts = sha256.convert(utf8.encode(helperScript)).toString();
    return 'helper=$scripts xray=$_hash';
  }

  static Future<String> _hashFiles(String xrayExe) async {
    final parts = <String>[];
    for (final f in [xrayExe, p.join(File(xrayExe).parent.path, 'wintun.dll')]) {
      parts.add((await sha256.bind(File(f).openRead()).first).toString());
    }
    return sha256.convert(utf8.encode(parts.join(':'))).toString();
  }

  /// The task can only run with full rights for accounts in Administrators
  /// (their filtered token still lists the group, as deny-only).
  Future<bool> userIsAdmin() async {
    final groups = '${(await _run('whoami', ['/groups'])).stdout}';
    return groups.contains('S-1-5-32-544');
  }

  Future<bool> isReady(String xrayExe) async {
    try {
      final version = File(p.windows.join(programDir, 'VERSION'));
      if (!version.existsSync() || version.readAsStringSync().trim() != await expectedVersion(xrayExe)) return false;
      return (await _run('schtasks', ['/query', '/tn', taskName])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// One UAC prompt: installs or updates the helper, core and task.
  Future<void> install(String xrayExe) async {
    final who = (await _run('whoami', ['/user', '/fo', 'csv', '/nh'])).stdout.toString().trim();
    // "DOMAIN\user","S-1-5-21-..."
    final m = RegExp(r'^"([^"]+)","(S-1-[0-9-]+)"').firstMatch(who);
    if (m == null) throw XrayStartException('Could not tell which Windows account this is ($who)');
    final script = installScript(
      source: File(xrayExe).parent.path,
      userName: m.group(1)!,
      userSid: m.group(2)!,
      version: await expectedVersion(xrayExe),
    );
    await _runElevated(script, 'tunnel-install.ps1');
    if (!await isReady(xrayExe)) {
      final err = File(p.windows.join(programDir, 'install-error.txt'));
      throw XrayStartException(err.existsSync()
          ? 'Tunnel mode setup failed: ${err.readAsStringSync().trim()}'
          : 'Tunnel mode setup did not complete');
    }
  }

  Future<void> uninstall() async {
    await _runElevated('''
\$ErrorActionPreference = 'SilentlyContinue'
Stop-ScheduledTask -TaskName '$taskName'
Unregister-ScheduledTask -TaskName '$taskName' -Confirm:\$false
Remove-Item -LiteralPath (Join-Path \$env:ProgramData 'IRNet') -Recurse -Force
''', 'tunnel-uninstall.ps1');
  }

  /// Runs [script] elevated (UAC) and waits. The script goes through a file
  /// in the request folder whose hash the elevated side checks first.
  Future<void> _runElevated(String script, String fileName) async {
    final dir = Directory(requestDir)..createSync(recursive: true);
    final file = File(p.windows.join(dir.path, fileName));
    await file.writeAsString(script, flush: true);
    final hash = sha256.convert(utf8.encode(script)).toString().toUpperCase();
    final inner = [
      '\$c = [IO.File]::ReadAllText(${_psQuote(file.path)})',
      "\$h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(\$c))).Replace('-', '')",
      "if (\$h -ne '$hash') { exit 3 }",
      '& ([ScriptBlock]::Create(\$c))',
    ].join('\n');
    final args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '
        '${ElevatedCoreLauncher.encodePowerShell(inner)}';
    final outer = "\$p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden "
        "-ArgumentList '$args'; exit \$p.ExitCode";
    try {
      final r = await _run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        ElevatedCoreLauncher.encodePowerShell(outer),
      ]);
      if ('${r.stderr}'.contains('canceled by the user')) {
        throw const XrayStartException('The Windows administrator prompt was declined.');
      }
    } finally {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  // ───────────────────────────── requests ─────────────────────────────

  /// Asks the task to do [action]; returns what it reported (`ok`,
  /// `started`, or an error message) once it has.
  Future<String> _request(String action, {Map<String, Object?> extra = const {}, String? config}) async {
    final dir = Directory(requestDir)..createSync(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    for (final name in ['stop', 'config.json']) {
      final f = File(p.windows.join(dir.path, name));
      if (f.existsSync()) f.deleteSync();
    }
    if (config != null) await File(p.windows.join(dir.path, 'config.json')).writeAsString(config, flush: true);
    final tmp = File(p.windows.join(dir.path, 'request.json.tmp'));
    await tmp.writeAsString(jsonEncode({'id': id, 'action': action, ...extra}), flush: true);
    await tmp.rename(p.windows.join(dir.path, 'request.json'));

    final r = await _run('schtasks', ['/run', '/tn', taskName]);
    if (r.exitCode != 0) throw XrayStartException('Could not start the tunnel task: ${'${r.stdout}${r.stderr}'.trim()}');
    final done = File(p.windows.join(stateDir, 'done-$id.txt'));
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (done.existsSync()) {
        final text = done.readAsStringSync().trim();
        if (text.isNotEmpty) return text;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const XrayStartException('The tunnel task did not answer');
  }

  Future<ControlDirInstance> startCore({required String config, required String assetDir, int? parentPid}) async {
    final result = await _request('tunnel', extra: {'pid': parentPid ?? pid, 'assets': assetDir}, config: config);
    if (result != 'started') throw XrayStartException(result);
    return ControlDirInstance(Directory(stateDir), pidFile: 'pid', onStop: stopCore);
  }

  Future<void> stopCore() async {
    try {
      await File(p.windows.join(requestDir, 'stop')).writeAsString('stop');
    } catch (_) {}
  }

  /// Kill switch: physical adapters off / back on, without a UAC prompt.
  Future<void> networkOff() async {
    final r = await _request('net-off');
    if (r != 'ok') throw XrayStartException(r);
  }

  Future<void> networkOn() async {
    final r = await _request('net-on');
    if (r != 'ok') throw XrayStartException(r);
  }

  static String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  // ───────────────────────────── scripts ─────────────────────────────

  @visibleForTesting
  static String installScript({
    required String source,
    required String userName,
    required String userSid,
    required String version,
  }) =>
      '''
\$ErrorActionPreference = 'Stop'
\$program = Join-Path \$env:ProgramData 'IRNet'
\$state = Join-Path \$program 'state'
try {
  New-Item -ItemType Directory -Force -Path \$program, \$state | Out-Null
  # Administrators write; users run. The state (core log, config with server
  # credentials) is readable by this user only.
  & icacls.exe \$program /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
  & icacls.exe \$state /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' ${_psQuote('*$userSid:(OI)(CI)RX')} | Out-Null
  Stop-ScheduledTask -TaskName '$taskName' -ErrorAction SilentlyContinue
  Get-Process -Name xray -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like (Join-Path \$program '*') } | Stop-Process -Force
  Copy-Item -LiteralPath (Join-Path ${_psQuote(source)} 'xray.exe') -Destination \$program -Force
  Copy-Item -LiteralPath (Join-Path ${_psQuote(source)} 'wintun.dll') -Destination \$program -Force
  \$helper = @'
$helperScript
'@
  Set-Content -LiteralPath (Join-Path \$program 'tunnel-helper.ps1') -Value \$helper -Encoding UTF8
  \$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path \$program 'tunnel-helper.ps1') + '"')
  \$principal = New-ScheduledTaskPrincipal -UserId ${_psQuote(userName)} -LogonType Interactive -RunLevel Highest
  \$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
  Register-ScheduledTask -TaskName '$taskName' -Action \$action -Principal \$principal -Settings \$settings -Force | Out-Null
  Set-Content -LiteralPath (Join-Path \$program 'VERSION') -Value ${_psQuote(version)}
  Remove-Item -LiteralPath (Join-Path \$program 'install-error.txt') -ErrorAction SilentlyContinue
} catch {
  Set-Content -LiteralPath (Join-Path \$program 'install-error.txt') -Value \$_.Exception.Message
  exit 1
}
''';

  /// Runs as the scheduled task, with the user's full administrator rights.
  @visibleForTesting
  static const helperScript = r'''
# IRNet's Tunnel mode helper. Installed by IRNet; started by its scheduled task.
$ErrorActionPreference = 'Stop'
$program = Join-Path $env:ProgramData 'IRNet'
$state = Join-Path $program 'state'
$requests = Join-Path $env:LOCALAPPDATA 'IRNet\tunnel'

function Test-Plain([string]$path) {
  # Only plain files and folders inside the user's profile: no links or
  # junctions anywhere between it and the profile folder.
  $profileDir = (Get-Item -LiteralPath $env:USERPROFILE -Force).FullName.TrimEnd('\')
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  while ($item) {
    if ($item.FullName.TrimEnd('\') -eq $profileDir) { return $true }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $item = if ($item.PSIsContainer) { $item.Parent } else { $item.Directory }
  }
  return $false
}

function Read-Request([string]$name, [int]$max) {
  $path = Join-Path $requests $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  if (-not (Test-Plain $path)) { return $null }
  if ((Get-Item -LiteralPath $path -Force).Length -gt $max) { return $null }
  return [IO.File]::ReadAllText($path)
}

function Find-Forbidden($o) {
  # Go's JSON decoder matches keys case-insensitively, and so does this.
  $forbidden = @('masterkeylog', 'certificatefile', 'keyfile', 'dir', 'masquerade', 'access', 'error')
  if ($o -is [Array]) {
    foreach ($x in $o) { $r = Find-Forbidden $x; if ($r) { return $r } }
  } elseif ($o -is [Management.Automation.PSCustomObject]) {
    foreach ($p in $o.PSObject.Properties) {
      $key = $p.Name.ToLowerInvariant()
      if ($forbidden -contains $key) { return "field $($p.Name)" }
      if (@('address', 'listen', 'redirect') -contains $key -and $p.Value -is [string] -and $p.Value -match '^[/@]') {
        return "Unix socket in $($p.Name)"
      }
      $r = Find-Forbidden $p.Value
      if ($r) { return $r }
    }
  } elseif ($o -is [string] -and $o -match '^ext:[^:]*(/|\\|\.\.)') {
    return 'geo file path'
  }
  return ''
}

function Test-Config([string]$text) {
  try { $c = $text | ConvertFrom-Json } catch { return 'not valid JSON' }
  if ($c -isnot [Management.Automation.PSCustomObject]) { return 'not a JSON object' }
  $sections = @('log', 'inbounds', 'outbounds', 'routing', 'dns', 'policy', 'stats', 'observatory')
  foreach ($p in $c.PSObject.Properties) { if ($sections -cnotcontains $p.Name) { return "unexpected section $($p.Name)" } }
  foreach ($ib in @($c.inbounds)) {
    if (@('tun', 'http', 'socks') -cnotcontains $ib.protocol) { return "inbound $($ib.protocol)" }
    if ($ib.protocol -ne 'tun' -and $ib.listen -ne '127.0.0.1') { return 'inbound not on 127.0.0.1' }
  }
  foreach ($ob in @($c.outbounds)) {
    if (@('vless', 'vmess', 'trojan', 'wireguard', 'freedom', 'blackhole', 'dns') -cnotcontains $ob.protocol) { return "outbound $($ob.protocol)" }
    $net = $null
    if ($ob.streamSettings) { $net = $ob.streamSettings.network }
    if ($net -and @('raw', 'tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'splithttp', 'kcp', 'mkcp') -cnotcontains $net) {
      return "transport $net"
    }
  }
  return (Find-Forbidden $c)
}

function Write-State([string]$name, [string]$value) {
  Set-Content -LiteralPath (Join-Path $state $name) -Value $value
}

$request = $null
try { $request = (Read-Request 'request.json' 10000) | ConvertFrom-Json } catch { }
if (-not $request -or -not ($request.id -match '^[0-9]{1,20}$')) { exit 2 }
$done = "done-$($request.id).txt"

switch ($request.action) {
  'net-off' {
    try {
      $names = @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' } | ForEach-Object { $_.Name })
      Write-State 'adapters.txt' ($names -join "`n")
      if ($names.Count -gt 0) { Disable-NetAdapter -Name $names -Confirm:$false }
      Write-State $done 'ok'
    } catch { Write-State $done "Couldn't turn the network off: $($_.Exception.Message)" }
    exit 0
  }
  'net-on' {
    try {
      $file = Join-Path $state 'adapters.txt'
      if (Test-Path -LiteralPath $file) {
        $names = @(Get-Content -LiteralPath $file | Where-Object { $_ })
        if ($names.Count -gt 0) { Enable-NetAdapter -Name $names -Confirm:$false }
        Remove-Item -LiteralPath $file
      }
      Write-State $done 'ok'
    } catch { Write-State $done "Couldn't turn the network back on: $($_.Exception.Message)" }
    exit 0
  }
  'tunnel' { }
  default { Write-State $done 'unknown request'; exit 2 }
}

# A new tunnel: clear what the last one left (not other requests' answers).
foreach ($name in @('pid', 'exited', 'xray.log', 'xray.err', 'error.txt', 'config.json')) {
  Remove-Item -LiteralPath (Join-Path $state $name) -ErrorAction SilentlyContinue
}
$parent = 0
if (-not [int]::TryParse([string]$request.pid, [ref]$parent)) { Write-State $done 'bad request'; exit 2 }
$text = Read-Request 'config.json' 1000000
if (-not $text) { Write-State $done 'The tunnel config is missing'; exit 2 }
$problem = Test-Config $text
if ($problem) { Write-State $done "IRNet's helper refused the config: $problem"; exit 2 }

$conf = Join-Path $state 'config.json'
$p = $null
try {
  [IO.File]::WriteAllText($conf, $text)
  $assets = Join-Path $state 'assets'
  Remove-Item -LiteralPath $assets -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $assets | Out-Null
  $from = [string]$request.assets
  if ($from -and (Test-Path -LiteralPath $from -PathType Container) -and (Test-Plain $from)) {
    Get-ChildItem -LiteralPath $from -Filter '*.dat' -File | Where-Object {
      -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $assets }
  }
  $env:XRAY_LOCATION_ASSET = $assets
  $p = Start-Process -FilePath (Join-Path $program 'xray.exe') -ArgumentList ('run -c "' + $conf + '"') -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $state 'xray.log') -RedirectStandardError (Join-Path $state 'xray.err')
  Write-State 'pid' $p.Id
  Write-State $done 'started'
  while ($true) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath (Join-Path $requests 'stop')) { break }
    if (-not (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { break }
    if ($p.HasExited) { break }
  }
} catch {
  Write-State 'error.txt' $_.Exception.Message
  if (-not (Test-Path -LiteralPath (Join-Path $state $done))) { Write-State $done $_.Exception.Message }
} finally {
  # Xray's WFP filters live in a dynamic session and its Wintun adapter with
  # the process, so Windows removes both even when it is stopped this way.
  if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(5000) | Out-Null }
  Remove-Item -LiteralPath $conf -ErrorAction SilentlyContinue
  Write-State 'exited' 'done'
}
''';
}
