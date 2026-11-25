import 'dart:io';

import 'package:flutter/foundation.dart';

typedef RunCommand = Future<ProcessResult> Function(String executable, List<String> arguments);

/// The network interface the default route goes out of (Wi-Fi, Ethernet),
/// skipping VPN tunnels. In Tunnel mode the delay tests bind their
/// connections to it, so they reach each server directly instead of going
/// through the VPN first.
class PhysicalInterface {
  PhysicalInterface._();

  static Future<String?> find({RunCommand run = Process.run}) async {
    try {
      if (Platform.isMacOS) {
        return parseNetstat('${(await run('/usr/sbin/netstat', ['-rn', '-f', 'inet'])).stdout}');
      }
      if (Platform.isLinux) {
        return parseIpRoute('${(await run('ip', ['-4', 'route', 'show', 'default'])).stdout}');
      }
      if (Platform.isWindows) {
        final r = await run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | "
              r"Where-Object { $_.InterfaceAlias -notlike 'IRNet*' } | "
              r'Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | '
              r'Select-Object -First 1 -ExpandProperty InterfaceAlias',
        ]);
        final name = '${r.stdout}'.trim();
        return name.isEmpty ? null : name;
      }
    } catch (e) {
      debugPrint('V2Ray: no physical interface: $e');
    }
    return null;
  }

  static bool _isTunnel(String name) {
    final n = name.toLowerCase();
    return const ['utun', 'tun', 'irnet', 'ipsec', 'ppp', 'wg', 'lo'].any(n.startsWith);
  }

  /// macOS `netstat -rn -f inet`: the first default route not on a tunnel.
  @visibleForTesting
  static String? parseNetstat(String out) {
    for (final line in out.split('\n')) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 4 || cols.first != 'default') continue;
      final iface = cols[3];
      if (!_isTunnel(iface)) return iface;
    }
    return null;
  }

  /// Linux `ip -4 route show default`: the first default route not on a tunnel.
  @visibleForTesting
  static String? parseIpRoute(String out) {
    for (final line in out.split('\n')) {
      final m = RegExp(r'\bdev\s+(\S+)').firstMatch(line);
      if (m != null && !_isTunnel(m.group(1)!)) return m.group(1);
    }
    return null;
  }
}
