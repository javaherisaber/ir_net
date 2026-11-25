import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cmd.dart';

typedef RunCommand = Future<io.ProcessResult> Function(String executable, List<String> arguments);

/// DNS servers and local IPv4 interfaces for the Connection section, on
/// every platform: Windows parses `ipconfig /all` (AppCmd), macOS asks
/// `scutil --dns`, Linux `resolvectl dns` (else /etc/resolv.conf), Android
/// the active network's link properties. iOS lists interfaces only.
class LocalNetworkReader {
  LocalNetworkReader({RunCommand? run}) : _run = run ?? io.Process.run;

  final RunCommand _run;
  static const _channel = MethodChannel('ir_net/system_events');

  /// macOS: device ("en0") → hardware port ("Wi-Fi"), refreshed when an
  /// unknown device shows up.
  Map<String, String> _ports = const {};

  Future<LocalNetworksResult?> read() async {
    if (kIsWeb) return null;
    if (io.Platform.isWindows) return AppCmd.getLocalNetworkInfo();
    final addresses = await io.NetworkInterface.list(type: io.InternetAddressType.IPv4);
    if (io.Platform.isMacOS && addresses.any((i) => !_ports.containsKey(i.name))) {
      try {
        _ports = parseHardwarePorts('${(await _run('/usr/sbin/networksetup', ['-listallhardwareports'])).stdout}');
      } catch (_) {}
    }
    final interfaces = [
      for (final i in addresses)
        for (final a in i.addresses)
          if (!a.isLoopback && !a.isLinkLocal) NetworkInterface(label(i.name, _ports), a.address),
    ];
    return LocalNetworksResult(interfaces, await _dns());
  }

  Future<List<String>> _dns() async {
    try {
      if (io.Platform.isMacOS) {
        final servers = parseScutilDns('${(await _run('/usr/sbin/scutil', ['--dns'])).stdout}');
        if (servers.isNotEmpty) return servers;
        return parseResolvConf(await io.File('/etc/resolv.conf').readAsString());
      }
      if (io.Platform.isLinux) {
        try {
          final r = await _run('resolvectl', ['dns']);
          final servers = r.exitCode == 0 ? parseResolvectl('${r.stdout}') : const <String>[];
          if (servers.isNotEmpty) return servers;
        } catch (_) {}
        return parseResolvConf(await io.File('/etc/resolv.conf').readAsString());
      }
      if (io.Platform.isAndroid) {
        return (await _channel.invokeListMethod<String>('dnsServers')) ?? const [];
      }
    } catch (e) {
      debugPrint('DNS servers unavailable: $e');
    }
    return const [];
  }

  /// "Wi-Fi (en0)": the port name where known, else a name from the device
  /// prefix (Linux, Android), else the device alone.
  @visibleForTesting
  static String label(String device, [Map<String, String> ports = const {}]) {
    final port = ports[device];
    if (port != null) return '$port ($device)';
    final d = device.toLowerCase();
    final String? kind;
    if (const ['utun', 'tun', 'wg', 'ppp', 'ipsec', 'irnet'].any(d.startsWith)) {
      kind = 'VPN tunnel';
    } else if (const ['wlan', 'wlp', 'wl'].any(d.startsWith)) {
      kind = 'Wi-Fi';
    } else if (const ['eth', 'enp', 'eno', 'ens', 'enx'].any(d.startsWith)) {
      kind = 'Ethernet';
    } else if (const ['rmnet', 'ccmni', 'pdp', 'wwan', 'wwp'].any(d.startsWith)) {
      kind = 'Mobile data';
    } else if (const ['bridge', 'ap', 'swlan'].any(d.startsWith)) {
      kind = 'Hotspot';
    } else {
      kind = null;
    }
    return kind == null ? device : '$kind ($device)';
  }

  /// `networksetup -listallhardwareports`: device → port name.
  @visibleForTesting
  static Map<String, String> parseHardwarePorts(String out) {
    final ports = <String, String>{};
    String? port;
    for (final line in out.split('\n')) {
      if (line.startsWith('Hardware Port:')) port = line.substring('Hardware Port:'.length).trim();
      if (line.startsWith('Device:') && port != null) ports[line.substring('Device:'.length).trim()] = port;
    }
    return ports;
  }

  /// `scutil --dns`: the nameservers of the default resolver (#1 of the
  /// first "DNS configuration" block; scoped and mDNS resolvers come later).
  @visibleForTesting
  static List<String> parseScutilDns(String out) {
    final servers = <String>[];
    var inFirst = false;
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.startsWith('resolver #')) {
        if (inFirst) break;
        inFirst = t == 'resolver #1';
        continue;
      }
      if (t.startsWith('DNS configuration (')) break;
      final m = RegExp(r'^nameserver\[\d+\]\s*:\s*(\S+)').firstMatch(t);
      if (inFirst && m != null && !servers.contains(m.group(1))) servers.add(m.group(1)!);
    }
    return servers;
  }

  /// `resolvectl dns`: every server, global first, then per link.
  @visibleForTesting
  static List<String> parseResolvectl(String out) {
    final servers = <String>[];
    for (final line in out.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      for (final token in line.substring(colon + 1).trim().split(RegExp(r'\s+'))) {
        final ip = token.split('#').first; // "1.1.1.1#cloudflare-dns.com"
        if (io.InternetAddress.tryParse(ip) != null && !servers.contains(ip)) servers.add(ip);
      }
    }
    return servers;
  }

  @visibleForTesting
  static List<String> parseResolvConf(String text) {
    final servers = <String>[];
    for (final line in text.split('\n')) {
      final m = RegExp(r'^\s*nameserver\s+(\S+)').firstMatch(line);
      if (m != null && !servers.contains(m.group(1))) servers.add(m.group(1)!);
    }
    return servers;
  }
}
