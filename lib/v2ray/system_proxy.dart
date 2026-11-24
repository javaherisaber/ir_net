import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mac_tunnel_helper.dart';
import 'routing_rules.dart';
import 'wininet_stub.dart' if (dart.library.ffi) 'wininet_native.dart';
import 'xray_config.dart';

/// Runs a command; tests swap in a fake so nothing touches the real OS.
typedef CommandRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

Future<ProcessResult> _run(String executable, List<String> arguments) => Process.run(executable, arguments);

class SystemProxyException implements Exception {
  const SystemProxyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Points the OS-wide proxy at the local core and puts it back afterwards.
///
/// [snapshot] records the user's own settings before [apply], as JSON, so
/// they can be restored even after a crash (the snapshot is persisted).
abstract class SystemProxy {
  static SystemProxy? forPlatform({CommandRunner run = _run}) {
    if (kIsWeb) return null;
    if (Platform.isWindows) return WindowsSystemProxy(run: run);
    if (Platform.isMacOS) return MacSystemProxy(run: run);
    if (Platform.isLinux) return LinuxSystemProxy(run: run);
    return null;
  }

  Future<Map<String, dynamic>> snapshot();

  Future<void> apply({
    required int httpPort,
    required int socksPort,
    required bool bypassLan,
    CompiledRules rules = CompiledRules.empty,
  });

  Future<void> restore(Map<String, dynamic> snapshot);

  /// Whether the OS proxy still points at our local [httpPort]. After a
  /// crash, settings are only put back if nobody changed them since.
  Future<bool> pointsAt(int httpPort);
}

// ───────────────────────────── Windows ─────────────────────────────

class WindowsSystemProxy extends SystemProxy {
  WindowsSystemProxy({this.run = _run, this.notify = notifyWinInetProxyChanged});
  final CommandRunner run;

  /// Makes running apps re-read the settings (WinINet); swapped in tests.
  final void Function() notify;

  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _values = ['ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL'];

  @override
  Future<Map<String, dynamic>> snapshot() async {
    final result = await run('reg', ['query', _key]);
    return parseRegQuery(result.stdout.toString());
  }

  /// `reg query` output to {name: {type, data}} for the proxy values.
  @visibleForTesting
  static Map<String, dynamic> parseRegQuery(String output) {
    final out = <String, dynamic>{};
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^\s+(\S+)\s+(REG_\w+)\s*(.*)$').firstMatch(line);
      if (m == null || !_values.contains(m.group(1))) continue;
      out[m.group(1)!] = {'type': m.group(2), 'data': m.group(3)!.trim()};
    }
    return out;
  }

  /// ProxyOverride: semicolon list with WinINet wildcards; `<local>` covers
  /// dotless intranet names.
  @visibleForTesting
  static String overrideList({required bool bypassLan, CompiledRules rules = CompiledRules.empty}) {
    final hosts = <String>['localhost', '127.*', '::1'];
    if (bypassLan) {
      hosts.addAll(XrayConfigBuilder.lanBypassHosts.where((h) => !hosts.contains(h)));
    }
    for (final d in rules.osDomains) {
      hosts.addAll([d, '*.$d']);
    }
    hosts.addAll(rules.osIps.map(_cidrToWildcard).whereType<String>());
    hosts.add('<local>');
    return hosts.join(';');
  }

  @override
  Future<bool> pointsAt(int httpPort) async {
    final now = await snapshot();
    final enabled = (now['ProxyEnable'] as Map?)?['data']?.toString() ?? '';
    final server = (now['ProxyServer'] as Map?)?['data']?.toString() ?? '';
    return enabled.endsWith('1') && server.contains('127.0.0.1:$httpPort');
  }

  @override
  Future<void> apply({
    required int httpPort,
    required int socksPort,
    required bool bypassLan,
    CompiledRules rules = CompiledRules.empty,
  }) async {
    await _set('ProxyServer', 'REG_SZ', '127.0.0.1:$httpPort');
    await _set('ProxyOverride', 'REG_SZ', overrideList(bypassLan: bypassLan, rules: rules));
    await _set('ProxyEnable', 'REG_DWORD', '1');
    // A PAC script would take precedence over the manual proxy.
    await _delete('AutoConfigURL');
    notify();
  }

  @override
  Future<void> restore(Map<String, dynamic> snapshot) async {
    for (final name in _values) {
      final v = snapshot[name];
      if (v is Map) {
        var data = v['data'].toString();
        if (v['type'] == 'REG_DWORD' && data.startsWith('0x')) data = int.parse(data.substring(2), radix: 16).toString();
        await _set(name, v['type'].toString(), data);
      } else if (name == 'ProxyEnable') {
        await _set(name, 'REG_DWORD', '0');
      } else {
        await _delete(name);
      }
    }
    notify();
  }

  Future<void> _set(String name, String type, String data) async {
    final r = await run('reg', ['add', _key, '/v', name, '/t', type, '/d', data, '/f']);
    if (r.exitCode != 0) throw SystemProxyException('Could not write $name: ${r.stderr}'.trim());
  }

  Future<void> _delete(String name) async {
    await run('reg', ['delete', _key, '/v', name, '/f']);
  }

  static String? _cidrToWildcard(String entry) {
    if (!entry.contains('/')) return entry;
    final parts = entry.split('/');
    final octets = parts[0].split('.');
    if (octets.length != 4) return null;
    switch (parts[1]) {
      case '8':
        return '${octets[0]}.*';
      case '16':
        return '${octets[0]}.${octets[1]}.*';
      case '24':
        return '${octets[0]}.${octets[1]}.${octets[2]}.*';
      case '32':
        return parts[0];
    }
    return null;
  }
}

// ───────────────────────────── macOS ─────────────────────────────

class MacSystemProxy extends SystemProxy {
  MacSystemProxy({this.run = _run, this.useHelper = true});
  final CommandRunner run;

  /// Route commands that need admin rights through the Tunnel mode helper
  /// when it is installed (tests turn this off).
  final bool useHelper;

  static const _ns = '/usr/sbin/networksetup';
  static const _kinds = ['webproxy', 'securewebproxy', 'socksfirewallproxy'];

  /// Once a plain call is refused, the rest go through one admin prompt.
  bool _needsAdmin = false;

  /// Enabled services with a hardware device (Wi-Fi, Ethernet, USB/Thunderbolt
  /// adapters); VPN services have none and keep their own settings.
  @visibleForTesting
  static List<String> parseServices(String output) => [for (final s in parseHardwareServices(output)) s.service];

  /// Enabled hardware services with their hardware port ("Wi-Fi") and device ("en0").
  static List<({String service, String port, String device})> parseHardwareServices(String output) {
    final services = <({String service, String port, String device})>[];
    final lines = output.split('\n');
    for (var i = 0; i < lines.length - 1; i++) {
      final m = RegExp(r'^\((\d+|\*)\)\s+(.+)$').firstMatch(lines[i].trim());
      if (m == null || m.group(1) == '*') continue;
      final hw = RegExp(r'Hardware Port:\s*([^,]*),\s*Device:\s*([^)\s]*)\)').firstMatch(lines[i + 1]);
      if (hw != null && hw.group(2)!.isNotEmpty) {
        services.add((service: m.group(2)!.trim(), port: hw.group(1)!.trim(), device: hw.group(2)!));
      }
    }
    return services;
  }

  Future<List<({String service, String port, String device})>> hardwareServices() async =>
      parseHardwareServices((await run(_ns, ['-listnetworkserviceorder'])).stdout.toString());

  /// Runs networksetup commands, asking for the admin password once if needed.
  Future<void> runAll(List<List<String>> commands) => _runAll(commands);

  /// Enabled services with a hardware device (also used for tunnel DNS).
  Future<List<String>> services() => _services();

  Future<List<String>> _services() async {
    final r = await run(_ns, ['-listnetworkserviceorder']);
    final services = parseServices(r.stdout.toString());
    if (services.isEmpty) throw const SystemProxyException('No network service found to set the proxy on');
    return services;
  }

  @visibleForTesting
  static Map<String, dynamic> parseProxyGet(String output) {
    String field(String name) =>
        RegExp('^$name:\\s*(.*)\$', multiLine: true).firstMatch(output)?.group(1)?.trim() ?? '';
    return {
      'enabled': field('Enabled').toLowerCase() == 'yes',
      'server': field('Server'),
      'port': int.tryParse(field('Port')) ?? 0,
    };
  }

  @override
  Future<Map<String, dynamic>> snapshot() async {
    final out = <String, dynamic>{};
    for (final service in await _services()) {
      final entry = <String, dynamic>{};
      for (final kind in _kinds) {
        final r = await run(_ns, ['-get$kind', service]);
        entry[kind] = parseProxyGet(r.stdout.toString());
      }
      final bypass = (await run(_ns, ['-getproxybypassdomains', service])).stdout.toString();
      entry['bypass'] = bypass.contains("aren't any") || bypass.contains('There are no')
          ? <String>[]
          : bypass.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      out[service] = entry;
    }
    return out;
  }

  @visibleForTesting
  static List<String> bypassList({required bool bypassLan, CompiledRules rules = CompiledRules.empty}) {
    final hosts = <String>['localhost', '127.0.0.1', '::1'];
    if (bypassLan) {
      hosts.addAll(['*.local', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16']);
    }
    for (final d in rules.osDomains) {
      hosts.addAll([d, '*.$d']);
    }
    hosts.addAll(rules.osIps);
    return hosts;
  }

  @override
  Future<bool> pointsAt(int httpPort) async {
    for (final service in await _services()) {
      final r = await run(_ns, ['-getwebproxy', service]);
      final s = parseProxyGet(r.stdout.toString());
      if (s['enabled'] == true && s['server'] == '127.0.0.1' && s['port'] == httpPort) return true;
    }
    return false;
  }

  @override
  Future<void> apply({
    required int httpPort,
    required int socksPort,
    required bool bypassLan,
    CompiledRules rules = CompiledRules.empty,
  }) async {
    final commands = <List<String>>[];
    for (final service in await _services()) {
      commands.addAll([
        ['-setwebproxy', service, '127.0.0.1', '$httpPort'],
        ['-setsecurewebproxy', service, '127.0.0.1', '$httpPort'],
        ['-setsocksfirewallproxy', service, '127.0.0.1', '$socksPort'],
        ['-setproxybypassdomains', service, ...bypassList(bypassLan: bypassLan, rules: rules)],
      ]);
    }
    await _runAll(commands);
  }

  @override
  Future<void> restore(Map<String, dynamic> snapshot) async {
    final commands = <List<String>>[];
    snapshot.forEach((service, value) {
      if (value is! Map) return;
      for (final kind in _kinds) {
        final s = value[kind];
        if (s is Map && s['enabled'] == true && (s['server'] as String? ?? '').isNotEmpty) {
          commands.add(['-set$kind', service, s['server'] as String, '${s['port']}']);
        } else {
          commands.add(['-set${kind}state', service, 'off']);
        }
      }
      final bypass = (value['bypass'] as List?)?.cast<String>() ?? const [];
      commands.add(['-setproxybypassdomains', service, ...(bypass.isEmpty ? ['Empty'] : bypass)]);
    });
    await _runAll(commands);
  }

  Future<void> _runAll(List<List<String>> commands) async {
    if (!_needsAdmin) {
      for (var i = 0; i < commands.length; i++) {
        final r = await run(_ns, commands[i]);
        final text = '${r.stdout}${r.stderr}';
        // networksetup can print "** Error: …" and still exit 0.
        if (r.exitCode == 0 && !text.contains('** Error')) continue;
        if (RegExp(r'admin|privilege|permission|not authorized|requires root', caseSensitive: false).hasMatch(text)) {
          _needsAdmin = true;
          await _runAsAdmin(commands.sublist(i));
          return;
        }
        throw SystemProxyException(text.trim());
      }
      return;
    }
    await _runAsAdmin(commands);
  }

  /// Through IRNet's Tunnel mode helper when it's set up (no prompt), else
  /// one "IRNet wants to make changes" password prompt for all commands.
  Future<void> _runAsAdmin(List<List<String>> commands) async {
    if (useHelper && MacTunnelHelper.isInstalled) {
      final helper = MacTunnelHelper(run: run);
      var ok = true;
      for (final c in commands) {
        if (!await helper.networksetup(c)) {
          ok = false;
          break;
        }
      }
      if (ok) return;
    }
    final script = commands.map((c) => [_ns, ...c].map(_shellQuote).join(' ')).join(' && ');
    final apple = 'do shell script "${script.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}" '
        'with administrator privileges';
    final r = await run('/usr/bin/osascript', ['-e', apple]);
    if (r.exitCode != 0) {
      final err = r.stderr.toString();
      throw SystemProxyException(err.contains('-128')
          ? 'The system proxy was not changed (password prompt cancelled)'
          : 'Could not change the system proxy: ${err.trim()}');
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}

// ───────────────────────────── Linux ─────────────────────────────

/// GNOME-family desktops (GNOME, Ubuntu, Cinnamon, Budgie, MATE via
/// gsettings) and KDE Plasma (kioslaverc).
class LinuxSystemProxy extends SystemProxy {
  LinuxSystemProxy({this.run = _run});
  final CommandRunner run;

  static const _schema = 'org.gnome.system.proxy';

  bool get _isKde => (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('KDE');

  Future<String?> _kdeTool(String base) async {
    for (final v in ['6', '5']) {
      final r = await run('which', ['$base$v']);
      if (r.exitCode == 0) return '$base$v';
    }
    return null;
  }

  Future<bool> _hasGsettings() async {
    try {
      return (await run('gsettings', ['get', _schema, 'mode'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> snapshot() async {
    final out = <String, dynamic>{};
    if (await _hasGsettings()) {
      Future<String> get(String schema, String key) async =>
          (await run('gsettings', ['get', schema, key])).stdout.toString().trim();
      out['gnome'] = {
        'mode': await get(_schema, 'mode'),
        'ignore-hosts': await get(_schema, 'ignore-hosts'),
        for (final kind in ['http', 'https', 'socks']) ...{
          '$kind.host': await get('$_schema.$kind', 'host'),
          '$kind.port': await get('$_schema.$kind', 'port'),
        },
      };
    }
    if (_isKde) {
      final read = await _kdeTool('kreadconfig');
      if (read != null) {
        final kde = <String, String>{};
        for (final key in const ['ProxyType', 'httpProxy', 'httpsProxy', 'socksProxy', 'NoProxyFor']) {
          final r = await run(read, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', key]);
          kde[key] = r.stdout.toString().trim();
        }
        out['kde'] = kde;
      }
    }
    return out;
  }

  @override
  Future<bool> pointsAt(int httpPort) async {
    if (await _hasGsettings()) {
      final mode = (await run('gsettings', ['get', _schema, 'mode'])).stdout.toString();
      final port = (await run('gsettings', ['get', '$_schema.http', 'port'])).stdout.toString().trim();
      if (mode.contains('manual') && port == '$httpPort') return true;
    }
    if (_isKde) {
      final read = await _kdeTool('kreadconfig');
      if (read != null) {
        final r = await run(read, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', 'httpProxy']);
        if (r.stdout.toString().contains('127.0.0.1 $httpPort')) return true;
      }
    }
    return false;
  }

  @override
  Future<void> apply({
    required int httpPort,
    required int socksPort,
    required bool bypassLan,
    CompiledRules rules = CompiledRules.empty,
  }) async {
    final hosts = <String>['localhost', '127.0.0.0/8', '::1'];
    if (bypassLan) {
      hosts.addAll(['*.local', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16']);
    }
    hosts.addAll([for (final d in rules.osDomains) ...[d, '*.$d'], ...rules.osIps]);
    var applied = false;
    if (await _hasGsettings()) {
      final gs = <List<String>>[
        ['set', _schema, 'mode', 'manual'],
        ['set', _schema, 'ignore-hosts', '[${hosts.map((h) => "'$h'").join(', ')}]'],
        for (final kind in ['http', 'https']) ...[
          ['set', '$_schema.$kind', 'host', '127.0.0.1'],
          ['set', '$_schema.$kind', 'port', '$httpPort'],
        ],
        ['set', '$_schema.socks', 'host', '127.0.0.1'],
        ['set', '$_schema.socks', 'port', '$socksPort'],
      ];
      for (final c in gs) {
        final r = await run('gsettings', c);
        if (r.exitCode != 0) throw SystemProxyException('gsettings failed: ${r.stderr}'.trim());
      }
      applied = true;
    }
    if (_isKde) {
      final write = await _kdeTool('kwriteconfig');
      if (write != null) {
        await _kdeWrite(write, {
          'ProxyType': '1',
          'httpProxy': 'http://127.0.0.1 $httpPort',
          'httpsProxy': 'http://127.0.0.1 $httpPort',
          'socksProxy': 'socks://127.0.0.1 $socksPort',
          'NoProxyFor': hosts.join(','),
        });
        applied = true;
      }
    }
    if (!applied) {
      throw const SystemProxyException('This desktop has no proxy setting IRNet knows how to change');
    }
  }

  @override
  Future<void> restore(Map<String, dynamic> snapshot) async {
    final gnome = snapshot['gnome'];
    if (gnome is Map) {
      for (final e in gnome.entries) {
        final key = e.key as String;
        final dot = key.indexOf('.');
        final schema = dot < 0 ? _schema : '$_schema.${key.substring(0, dot)}';
        final name = dot < 0 ? key : key.substring(dot + 1);
        // `gsettings get` prints GVariant text ("'none'", "@as []"), which
        // `gsettings set` accepts back unchanged.
        final value = e.value as String;
        if (value.isNotEmpty) await run('gsettings', ['set', schema, name, value]);
      }
    }
    final kde = snapshot['kde'];
    if (kde is Map) {
      final write = await _kdeTool('kwriteconfig');
      if (write != null) {
        await _kdeWrite(write, {
          for (final e in kde.entries)
            e.key as String: e.key == 'ProxyType' && (e.value as String).isEmpty ? '0' : e.value as String,
        });
      }
    }
  }

  Future<void> _kdeWrite(String tool, Map<String, String> values) async {
    for (final e in values.entries) {
      await run(tool, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', e.key, e.value]);
    }
    await run('dbus-send', [
      '--type=signal',
      '/KIO/Scheduler',
      'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
      'string:',
    ]);
  }
}
