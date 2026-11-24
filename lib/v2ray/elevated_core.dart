import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'xray_runner.dart';

typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Runs the Xray core with administrator/root rights, which Tunnel mode's
/// TUN device and routes need: one password prompt (macOS), polkit prompt
/// (Linux) or UAC prompt (Windows) per connect.
///
/// The privileged side is a small script with the config embedded in it
/// (so it never reads a file another process could have changed). It writes
/// the core's log and pid into [controlDir] and keeps the core running until
/// a "stop" file appears there, IRNet's process goes away, or the core
/// exits; then it stops the core (which removes its routes), puts DNS back
/// and writes "exited".
class ElevatedCoreLauncher {
  ElevatedCoreLauncher({
    Future<ProcessResult> Function(String, List<String>)? run,
    ProcessStarter? start,
    int? parentPid,
  })  : _run = run ?? Process.run,
        _start = start ?? Process.start,
        _parentPid = parentPid ?? pid;

  final Future<ProcessResult> Function(String, List<String>) _run;
  final ProcessStarter _start;
  final int _parentPid;

  /// [dnsServices]: macOS network services whose DNS servers point into
  /// the tunnel while it runs.
  Future<ControlDirInstance> start({
    required String binary,
    required String config,
    required String assetDir,
    required Directory controlDir,
    List<String> dnsServices = const [],
    List<String> dnsServers = const ['1.1.1.1', '8.8.8.8'],
  }) async {
    await controlDir.create(recursive: true);
    if (Platform.isWindows) {
      return _startWindows(binary, config, assetDir, controlDir);
    }
    final script = posixScript(
      binary: binary,
      config: config,
      assetDir: assetDir,
      controlDir: controlDir.path,
      parentPid: _parentPid,
      dnsServices: dnsServices,
      dnsServers: dnsServers,
    );
    final isRoot = (await _run('id', ['-u'])).stdout.toString().trim() == '0';
    if (isRoot) {
      final process = await _start('/bin/sh', ['-c', script]);
      return ControlDirInstance(controlDir, launcherExit: process.exitCode);
    }
    if (Platform.isMacOS) {
      // Backgrounded with its output redirected, so the prompt call returns.
      final command = "/bin/sh -c ${_shellQuote(script)} irnet-tunnel > /dev/null 2>&1 &";
      final apple = 'do shell script "${_appleEscape(command)}" with prompt '
          '"IRNet needs your password to send all traffic through the VPN." with administrator privileges';
      final r = await _run('/usr/bin/osascript', ['-e', apple]);
      if (r.exitCode != 0) {
        final err = r.stderr.toString();
        throw XrayStartException(err.contains('-128')
            ? 'Tunnel mode needs an administrator password; the prompt was cancelled.'
            : 'Could not start tunnel mode: ${err.trim()}');
      }
      return ControlDirInstance(controlDir);
    }
    // Linux: polkit's graphical prompt.
    final which = await _run('which', ['pkexec']);
    if (which.exitCode != 0) {
      throw const XrayStartException('Tunnel mode needs root rights: install pkexec (polkit) or run IRNet as root.');
    }
    final process = await _start('pkexec', ['/bin/sh', '-c', script]);
    return ControlDirInstance(controlDir, launcherExit: process.exitCode);
  }

  Future<ControlDirInstance> _startWindows(String binary, String config, String assetDir, Directory dir) async {
    final script = windowsScript(binary: binary, config: config, assetDir: assetDir);
    final scriptFile = File(p.join(dir.path, 'tunnel.ps1'));
    await scriptFile.writeAsString(script, flush: true);
    // The elevated side runs the script only if it still has this hash, so
    // nothing can swap it between writing it and the UAC prompt.
    final hash = sha256.convert(utf8.encode(script)).toString().toUpperCase();
    final inner = [
      '\$c = [IO.File]::ReadAllText(${_psQuote(scriptFile.path)})',
      "\$h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(\$c))).Replace('-', '')",
      "if (\$h -ne '$hash') { exit 3 }",
      '& ([ScriptBlock]::Create(\$c)) -ParentPid $_parentPid -OutDir ${_psQuote(dir.path)}',
    ].join('\n');
    final args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ${encodePowerShell(inner)}';
    final groups = '${(await _run('whoami', ['/groups'])).stdout}';
    if (groups.contains('S-1-16-12288') || groups.contains('S-1-16-16384')) {
      final process = await _start('powershell.exe', args.split(' '));
      return ControlDirInstance(dir, launcherExit: process.exitCode);
    }
    final outer = "Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList '$args'";
    final r = await _run('powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encodePowerShell(outer)]);
    if (r.exitCode != 0) {
      throw XrayStartException('${r.stderr}'.contains('canceled by the user')
          ? 'Tunnel mode needs administrator rights; the Windows prompt was declined.'
          : 'Could not start tunnel mode: ${'${r.stderr}'.trim()}');
    }
    return ControlDirInstance(dir);
  }

  // ───────────────────────────── scripts ─────────────────────────────

  @visibleForTesting
  static String posixScript({
    required String binary,
    required String config,
    required String assetDir,
    required String controlDir,
    required int parentPid,
    List<String> dnsServices = const [],
    List<String> dnsServers = const ['1.1.1.1', '8.8.8.8'],
  }) {
    final services = dnsServices.join('\n');
    return '''
DIR=${_shellQuote(controlDir)}
XRAY=${_shellQuote(binary)}
ASSETS=${_shellQuote(assetDir)}
PARENT=$parentPid
SERVICES=${_shellQuote(services)}
DNS=${_shellQuote(dnsServers.join(' '))}
# Xray picks the config format from the file extension, hence config.json.
CDIR="\$(mktemp -d "\${TMPDIR:-/tmp}/irnet-xray.XXXXXX")" || exit 1
chmod 700 "\$CDIR"
CONF="\$CDIR/config.json"
cat > "\$CONF" <<'IRNET_XRAY_CONFIG'
$config
IRNET_XRAY_CONFIG
SAVED="\$CDIR/dns.saved"
flush_dns() { dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; }
if [ -n "\$SERVICES" ]; then
  printf '%s\\n' "\$SERVICES" | while IFS= read -r svc; do
    [ -n "\$svc" ] || continue
    cur="\$(networksetup -getdnsservers "\$svc" | tr '\\n' ' ')"
    case "\$cur" in *" any "*|*"aren't"*) cur="Empty";; esac
    printf '%s\\t%s\\n' "\$svc" "\$cur" >> "\$SAVED"
    networksetup -setdnsservers "\$svc" \$DNS
  done
  flush_dns
fi
XRAY_LOCATION_ASSET="\$ASSETS" "\$XRAY" run -c "\$CONF" > "\$DIR/xray.log" 2>&1 &
XPID=\$!
echo "\$XPID" > "\$DIR/pid"
chmod 644 "\$DIR/xray.log" "\$DIR/pid" 2>/dev/null
while :; do
  sleep 1
  [ -f "\$DIR/stop" ] && break
  kill -0 "\$PARENT" 2>/dev/null || break
  kill -0 "\$XPID" 2>/dev/null || break
done
kill -TERM "\$XPID" 2>/dev/null
i=0
while kill -0 "\$XPID" 2>/dev/null && [ "\$i" -lt 50 ]; do sleep 0.1; i=\$((i + 1)); done
kill -KILL "\$XPID" 2>/dev/null
if [ -f "\$SAVED" ]; then
  while IFS="\$(printf '\\t')" read -r svc servers; do
    [ -n "\$svc" ] || continue
    networksetup -setdnsservers "\$svc" \$servers
  done < "\$SAVED"
  rm -f "\$SAVED"
  flush_dns
fi
rm -rf "\$CDIR"
echo done > "\$DIR/exited"
chmod 644 "\$DIR/exited" 2>/dev/null
''';
  }

  @visibleForTesting
  static String windowsScript({required String binary, required String config, required String assetDir}) => '''
param([int]\$ParentPid, [string]\$OutDir)
\$ErrorActionPreference = 'Stop'
\$xray = ${_psQuote(binary)}
\$assets = ${_psQuote(assetDir)}
\$config = @'
$config
'@
\$conf = \$null
\$p = \$null
try {
  \$conf = Join-Path \$env:TEMP ('irnet-xray-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText(\$conf, \$config)
  \$env:XRAY_LOCATION_ASSET = \$assets
  \$p = Start-Process -FilePath \$xray -ArgumentList ('run -c "' + \$conf + '"') -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path \$OutDir 'xray.log') -RedirectStandardError (Join-Path \$OutDir 'xray.err')
  Set-Content -Path (Join-Path \$OutDir 'pid') -Value \$p.Id
  while (\$true) {
    Start-Sleep -Milliseconds 500
    if (Test-Path (Join-Path \$OutDir 'stop')) { break }
    if (-not (Get-Process -Id \$ParentPid -ErrorAction SilentlyContinue)) { break }
    if (\$p.HasExited) { break }
  }
} catch {
  Set-Content -Path (Join-Path \$OutDir 'error.txt') -Value \$_.Exception.Message
} finally {
  # Xray's WFP filters live in a dynamic session and its Wintun adapter with
  # the process, so Windows removes both even when it is stopped this way.
  if (\$p -and -not \$p.HasExited) { Stop-Process -Id \$p.Id -Force -ErrorAction SilentlyContinue; \$p.WaitForExit(5000) | Out-Null }
  if (\$conf) { Remove-Item -Path \$conf -Force -ErrorAction SilentlyContinue }
  Set-Content -Path (Join-Path \$OutDir 'exited') -Value 'done'
}
''';

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  static String _appleEscape(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  static String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  /// UTF-16LE base64 for `powershell -EncodedCommand`.
  static String encodePowerShell(String command) {
    final units = command.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xff;
      bytes[i * 2 + 1] = units[i] >> 8;
    }
    return base64.encode(bytes);
  }
}

/// A privileged core, seen through the files its helper writes.
class ControlDirInstance implements XrayInstance {
  /// [onStop] replaces the "stop" file where IRNet can't write into [dir]
  /// (the macOS helper's root-owned state folder).
  ControlDirInstance(this.dir, {Future<int>? launcherExit, this.pidFile = 'pid', this.onStop}) {
    launcherExit?.then((code) => _launcherCode = code);
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _check());
  }

  final Directory dir;
  final String pidFile;
  final Future<void> Function()? onStop;
  final _exited = Completer<void>();
  Timer? _timer;
  int? _launcherCode;

  File _file(String name) => File(p.join(dir.path, name));

  void _check() {
    final launcherGone = _launcherCode != null && !_file(pidFile).existsSync();
    if (_file('exited').existsSync() || launcherGone) {
      _timer?.cancel();
      if (!_exited.isCompleted) _exited.complete();
    }
  }

  @override
  Future<void> get exited => _exited.future;

  @override
  bool get hasExited {
    _check();
    return _exited.isCompleted;
  }

  @override
  int? get pid {
    try {
      return int.tryParse(_file(pidFile).readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  @override
  String? get lastOutboundTag {
    try {
      final file = File(p.join(dir.path, 'xray.log'));
      final length = file.lengthSync();
      final raf = file.openSync();
      try {
        // The access log grows; the last 16 KB hold the latest connections.
        raf.setPositionSync(length > 16384 ? length - 16384 : 0);
        final tail = utf8.decode(raf.readSync(16384), allowMalformed: true);
        String? tag;
        for (final line in tail.split('\n')) {
          tag = outboundTagIn(line) ?? tag;
        }
        return tag;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  String get logTail {
    final lines = <String>[];
    for (final name in ['error.txt', 'xray.err', 'xray.log']) {
      try {
        lines.addAll(_file(name).readAsLinesSync().where((l) => l.trim().isNotEmpty));
      } catch (_) {}
    }
    if (lines.isEmpty && _launcherCode != null && _launcherCode != 0) {
      // pkexec: 126 = dialog dismissed, 127 = not authorised.
      return _launcherCode == 126 || _launcherCode == 127
          ? 'The administrator prompt was cancelled.'
          : 'The tunnel helper exited with code $_launcherCode.';
    }
    final errors = lines.where((l) => RegExp(r'error|failed|invalid|unknown|denied|permission', caseSensitive: false).hasMatch(l));
    final source = errors.isNotEmpty ? errors.toList() : lines;
    return source.skip(source.length > 3 ? source.length - 3 : 0).join('\n');
  }

  @override
  Future<void> stop() async {
    if (hasExited) return;
    if (onStop != null) {
      try {
        await onStop!();
      } catch (_) {}
    } else {
      try {
        await _file('stop').writeAsString('stop');
      } catch (_) {}
    }
    await exited.timeout(const Duration(seconds: 12), onTimeout: () {});
    _timer?.cancel();
  }
}
