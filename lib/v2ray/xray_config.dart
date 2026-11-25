import 'dart:convert';

import 'models.dart';
import 'routing_rules.dart';
import 'share_link.dart';

/// Credentials for the local HTTP inbound (Android, where the proxy is
/// reachable by every app on the device).
typedef ProxyAuth = ({String user, String pass});

/// Builds Xray-core JSON configs from [V2rayProfile]s. Field names follow
/// Xray v26 (infra/conf): RAW/XHTTP naming, no allowInsecure, REALITY
/// "publicKey"/"shortId".
class XrayConfigBuilder {
  XrayConfigBuilder._();

  /// Private, loopback, link-local and multicast ranges: what "bypass LAN"
  /// sends directly.
  static const lanCidrs = [
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '224.0.0.0/4',
    '255.255.255.255/32',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ];

  /// Local-only names (mDNS, home routers).
  static const lanDomains = [
    'full:localhost',
    'domain:localhost',
    'domain:local',
    'domain:lan',
    'domain:home.arpa',
  ];

  /// Host patterns for OS proxy bypass lists (Windows/macOS/GNOME syntax
  /// differs slightly; each platform adapts these).
  static const lanBypassHosts = [
    'localhost',
    '127.0.0.1',
    '::1',
    '*.local',
    '10.*',
    '172.16.*',
    '172.17.*',
    '172.18.*',
    '172.19.*',
    '172.20.*',
    '172.21.*',
    '172.22.*',
    '172.23.*',
    '172.24.*',
    '172.25.*',
    '172.26.*',
    '172.27.*',
    '172.28.*',
    '172.29.*',
    '172.30.*',
    '172.31.*',
    '192.168.*',
    '169.254.*',
  ];

  static const dnsServers = ['1.1.1.1', '8.8.8.8'];

  static const _fingerprints = {
    'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', //
    'random', 'randomized', 'randomizednoalpn',
  };

  static const _xhttpModes = {'auto', 'packet-up', 'stream-up', 'stream-one'};

  // ───────────────────────────── outbound ─────────────────────────────

  /// The proxy outbound for [p]. Throws [StateError] when the config isn't usable.
  /// [endpointHost] replaces a WireGuard server's name (Tunnel mode pins it).
  static Map<String, dynamic> outbound(V2rayProfile p, {String tag = 'proxy', String? endpointHost}) {
    if (p.problem != null) throw StateError(p.problem!);
    final Map<String, dynamic> settings;
    switch (p.protocol) {
      case V2rayProtocol.wireguard:
        return _wireGuard(p, tag, endpointHost ?? p.address);
      case V2rayProtocol.vless:
        settings = {
          'vnext': [
            {
              'address': p.address,
              'port': p.port,
              'users': [
                {
                  'id': p.credential,
                  'encryption': p.encryption.isEmpty ? 'none' : p.encryption,
                  if (p.flow.isNotEmpty) 'flow': p.flow,
                  'level': 8,
                }
              ],
            }
          ],
        };
      case V2rayProtocol.vmess:
        settings = {
          'vnext': [
            {
              'address': p.address,
              'port': p.port,
              'users': [
                {
                  'id': p.credential,
                  'security': p.encryption.isEmpty ? 'auto' : p.encryption,
                  'level': 8,
                }
              ],
            }
          ],
        };
      case V2rayProtocol.trojan:
        settings = {
          'servers': [
            {'address': p.address, 'port': p.port, 'password': p.credential, 'level': 8}
          ],
        };
    }
    return {
      'tag': tag,
      'protocol': p.protocol.name,
      'settings': settings,
      'streamSettings': streamSettings(p),
    };
  }

  static Map<String, dynamic> _wireGuard(V2rayProfile p, String tag, String host) {
    final wg = p.wireguard!;
    return {
      'tag': tag,
      'protocol': 'wireguard',
      'settings': {
        'secretKey': p.credential,
        'address': wg.addresses,
        'peers': [
          {
            'publicKey': wg.publicKey,
            if (wg.preSharedKey.isNotEmpty) 'preSharedKey': wg.preSharedKey,
            'endpoint': host.contains(':') ? '[$host]:${p.port}' : '$host:${p.port}',
            if (wg.keepAlive > 0) 'keepAlive': wg.keepAlive,
            if (wg.allowedIPs.isNotEmpty) 'allowedIPs': wg.allowedIPs,
          }
        ],
        if (wg.mtu != null) 'mtu': wg.mtu,
        if (wg.reserved.length == 3) 'reserved': wg.reserved,
        // Userspace WireGuard only: never a kernel interface of its own next
        // to IRNet's TUN (Xray would make one where it has the rights).
        'noKernelTun': true,
      },
    };
  }

  static Map<String, dynamic> streamSettings(V2rayProfile p) {
    final s = p.stream;
    final out = <String, dynamic>{'network': s.network, 'security': s.security};
    final path = s.path.isEmpty ? '/' : s.path;
    switch (s.network) {
      case 'raw':
        if (s.headerType == 'http') {
          out['rawSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'version': '1.1',
                'method': 'GET',
                'path': _list(s.path).isEmpty ? ['/'] : _list(s.path),
                'headers': {
                  if (_list(s.host).isNotEmpty) 'Host': _list(s.host),
                  'User-Agent': [
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
                  ],
                  'Accept-Encoding': ['gzip, deflate'],
                  'Connection': ['keep-alive'],
                  'Pragma': ['no-cache'],
                },
              },
            },
          };
        }
      case 'ws':
        out['wsSettings'] = {'path': path, if (s.host.isNotEmpty) 'host': _list(s.host).first};
      case 'httpupgrade':
        out['httpupgradeSettings'] = {'path': path, if (s.host.isNotEmpty) 'host': _list(s.host).first};
      case 'xhttp':
        final extra = _jsonObject(s.extra);
        out['xhttpSettings'] = {
          'path': path,
          if (s.host.isNotEmpty) 'host': _list(s.host).first,
          if (_xhttpModes.contains(s.mode)) 'mode': s.mode,
          if (extra != null) 'extra': extra,
        };
      case 'grpc':
        out['grpcSettings'] = {
          'serviceName': s.serviceName,
          if (s.authority.isNotEmpty) 'authority': s.authority,
          'multiMode': s.mode.toLowerCase() == 'multi',
        };
      case 'kcp':
        out['kcpSettings'] = <String, dynamic>{};
    }

    final fp = s.fingerprint.toLowerCase();
    final validFp = _fingerprints.contains(fp) || (fp.startsWith('hello') && fp != 'hellogolang');
    if (s.security == 'tls') {
      final serverName = s.sni.isNotEmpty
          ? s.sni
          : (_list(s.host).isNotEmpty && ShareLinkParser.parseIpv4(_list(s.host).first) == null
              ? _list(s.host).first
              : '');
      out['tlsSettings'] = {
        if (serverName.isNotEmpty) 'serverName': serverName,
        if (s.alpn.isNotEmpty) 'alpn': s.alpn,
        if (validFp) 'fingerprint': fp,
        if (s.pinnedPeerCertSha256.isNotEmpty) 'pinnedPeerCertSha256': s.pinnedPeerCertSha256,
        if (s.verifyPeerCertByName.isNotEmpty) 'verifyPeerCertByName': s.verifyPeerCertByName,
        if (s.echConfigList.isNotEmpty) 'echConfigList': s.echConfigList,
      };
    } else if (s.security == 'reality') {
      out['realitySettings'] = {
        if (s.sni.isNotEmpty) 'serverName': s.sni,
        'fingerprint': validFp ? fp : 'chrome',
        'publicKey': s.publicKey,
        'shortId': s.shortId,
        if (s.spiderX.isNotEmpty) 'spiderX': s.spiderX.startsWith('/') ? s.spiderX : '/${s.spiderX}',
        if (s.mldsa65Verify.isNotEmpty) 'mldsa65Verify': s.mldsa65Verify,
      };
    }
    return out;
  }

  // ───────────────────────────── full configs ─────────────────────────────

  /// Probe target for Auto's health checks (and delay tests).
  static const probeUrl = 'https://www.gstatic.com/generate_204';

  /// Whether the fragment mask can apply: it splits a TLS ClientHello sent
  /// over TCP, so TLS/REALITY configs on TCP-based transports.
  static bool fragmentApplies(V2rayProfile p) =>
      p.protocol != V2rayProtocol.wireguard &&
      const {'tls', 'reality'}.contains(p.stream.security) &&
      p.stream.network != 'kcp';

  /// The proxy outbounds: one tagged "proxy", or for Auto ([profiles] has
  /// several) "proxy-N" each, which a least-ping balancer picks from using
  /// the observatory's probes, moving off a server as soon as it fails.
  static ({List<Map<String, dynamic>> outbounds, bool balanced}) _proxies(
    List<V2rayProfile> profiles, {
    FragmentOptions? fragment,
    Map<String, List<String>> hosts = const {},
  }) {
    final balanced = profiles.length > 1;
    final outbounds = <Map<String, dynamic>>[];
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      // WireGuard dials its endpoint itself: give it the pinned address (IPv4
      // first) rather than a name to resolve.
      final pinned = hosts[p.address] ?? const <String>[];
      final pinnedHost = pinned.where((a) => !a.contains(':')).followedBy(pinned).firstOrNull;
      final out = outbound(p,
          tag: balanced ? 'proxy-$i' : 'proxy',
          endpointHost: p.protocol == V2rayProtocol.wireguard ? pinnedHost : null);
      final stream = out['streamSettings'];
      if (stream is Map<String, dynamic>) {
        if (hosts.isNotEmpty) stream['sockopt'] = {'domainStrategy': 'UseIP'};
        if (fragment != null && fragmentApplies(p)) {
          stream['finalmask'] = {
            'tcp': [
              {
                'type': 'fragment',
                'settings': {'packets': fragment.packets, 'length': fragment.length, 'delay': fragment.delay},
              }
            ],
          };
        }
      }
      outbounds.add(out);
    }
    return (outbounds: outbounds, balanced: balanced);
  }

  static List<Map<String, dynamic>> _rules({
    List<Map<String, dynamic>> lead = const [],
    required bool bypassLan,
    required CompiledRules rules,
    required List<String> bypassApps,
    required bool balanced,
  }) =>
      [
        ...lead,
        // Xray's own DNS lookups go where browsing goes.
        if (balanced) {'inboundTag': ['dns-internal'], 'balancerTag': 'auto'},
        if (bypassApps.isNotEmpty) {'process': bypassApps, 'outboundTag': 'direct'},
        if (bypassLan) {'ip': lanCidrs, 'outboundTag': 'direct'},
        if (bypassLan) {'domain': lanDomains, 'outboundTag': 'direct'},
        if (rules.domains.isNotEmpty) {'domain': rules.domains, 'outboundTag': 'direct'},
        if (rules.ips.isNotEmpty) {'ip': rules.ips, 'outboundTag': 'direct'},
        if (balanced) {'network': 'tcp,udp', 'balancerTag': 'auto'},
      ];

  static Map<String, dynamic> _routing(List<Map<String, dynamic>> rules, CompiledRules compiled, bool balanced) => {
        // IP rules (geoip:ir, CIDRs) only see IPs. With them, names that no
        // domain rule matched are resolved so e.g. an Iranian site's IP still
        // goes direct; without them, skip the lookup.
        'domainStrategy': compiled.ips.isEmpty ? 'AsIs' : 'IPIfNonMatch',
        'rules': rules,
        if (balanced)
          'balancers': [
            {
              'tag': 'auto',
              'selector': ['proxy-'],
              'strategy': {'type': 'leastPing'},
              'fallbackTag': 'proxy-0',
            }
          ],
      };

  static const _observatory = {
    'subjectSelector': ['proxy-'],
    'probeURL': probeUrl,
    'probeInterval': '1m',
    'enableConcurrency': true,
  };

  /// Config for an actual connection: a SOCKS and an HTTP inbound on
  /// [listen], the proxy (or for Auto, [balanced]'s configs behind a
  /// balancer), and direct rules for apps, LAN and exclusions.
  static Map<String, dynamic> connection(
    V2rayProfile p, {
    required int socksPort,
    required int httpPort,
    bool bypassLan = true,
    CompiledRules rules = CompiledRules.empty,
    ProxyAuth? httpAuth,
    String listen = '127.0.0.1',
    String logLevel = 'warning',
    List<V2rayProfile> balanced = const [],
    FragmentOptions? fragment,
    List<String> bypassApps = const [],
  }) {
    const sniffing = {
      'enabled': true,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': true,
    };
    final proxies = _proxies(balanced.length > 1 ? balanced : [p], fragment: fragment);
    return {
      // Auto reads the access log to show which config is in use; otherwise
      // skip it (in Tunnel mode it would log every connection on the system).
      'log': {'loglevel': logLevel, if (!proxies.balanced) 'access': 'none'},
      'inbounds': [
        {
          'tag': 'socks',
          'listen': listen,
          'port': socksPort,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': sniffing,
        },
        {
          'tag': 'http',
          'listen': listen,
          'port': httpPort,
          'protocol': 'http',
          'settings': {
            if (httpAuth != null)
              'accounts': [
                {'user': httpAuth.user, 'pass': httpAuth.pass}
              ],
          },
          'sniffing': sniffing,
        },
      ],
      'outbounds': [
        ...proxies.outbounds,
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': _routing(
        _rules(bypassLan: bypassLan, rules: rules, bypassApps: bypassApps, balanced: proxies.balanced),
        rules,
        proxies.balanced,
      ),
      if (proxies.balanced) 'observatory': _observatory,
      'dns': {
        'servers': dnsServers,
        if (proxies.balanced) 'tag': 'dns-internal',
      },
    };
  }

  /// Tunnel mode on desktop: Xray's TUN inbound routes the whole system
  /// through itself (`autoSystemRoutingTable`), keeping its own sockets on
  /// the physical interface (`autoOutboundsInterface`, "auto" by default).
  /// The system's DNS queries reaching the TUN on port 53 are answered by
  /// Xray's DNS, which asks [dnsServers] through the VPN.
  ///
  /// [hosts] pins the servers' names to addresses looked up before the
  /// tunnel came up, so resolving them never needs the tunnel itself. An
  /// HTTP inbound on [httpPort] tells IRNet the core is up (and serves its
  /// health checks).
  ///
  /// [os] is windows, macos or linux. On Windows the TUN adapter carries
  /// the DNS servers and WFP filters keep DNS from leaking past it; on Linux
  /// with systemd-resolved ([linuxResolved]) the resolver is pointed at the
  /// TUN; on macOS the helper script sets the services' DNS servers.
  static Map<String, dynamic> tunnel(
    V2rayProfile p, {
    required int httpPort,
    required String os,
    bool bypassLan = true,
    CompiledRules rules = CompiledRules.empty,
    Map<String, List<String>> hosts = const {},
    bool linuxResolved = false,
    List<V2rayProfile> balanced = const [],
    FragmentOptions? fragment,
    List<String> bypassApps = const [],
  }) {
    // Where system DNS can't be captured, let the proxy see the sniffed
    // name rather than an address a poisoned resolver may have handed out.
    final dnsCaptured = os != 'linux' || linuxResolved;
    final proxies = _proxies(balanced.length > 1 ? balanced : [p], fragment: fragment, hosts: hosts);
    final routing = _rules(
      lead: [
        {
          'inboundTag': ['tun'],
          'port': 53,
          'outboundTag': 'dns-out',
        },
      ],
      bypassLan: bypassLan,
      rules: rules,
      bypassApps: bypassApps,
      balanced: proxies.balanced,
    );
    return {
      // No "access" key: the privileged helpers refuse log paths outright.
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'tun',
          'port': 0,
          'protocol': 'tun',
          'settings': {
            if (os == 'windows') 'name': 'IRNet',
            if (os == 'linux') 'name': 'irnet0',
            'mtu': 1500,
            'gateway': tunGateway,
            'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
            if (os == 'windows') 'dns': tunDnsServers,
            if (os == 'windows') 'autoSystemWfpBlockLeak': ['dns', 'misconfigtun'],
            if (os == 'linux' && linuxResolved) 'autoSystemDnsToGateway': true,
          },
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': dnsCaptured,
          },
        },
        {
          'tag': 'http',
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
        },
      ],
      'outbounds': [
        ...proxies.outbounds,
        {
          'tag': 'direct',
          'protocol': 'freedom',
          // Names of pass-through sites resolve through Xray's DNS (via the
          // VPN), not the system's, which would loop back into the TUN.
          // (freedom's own domainStrategy/targetStrategy are deprecated.)
          'streamSettings': {
            'sockopt': {'domainStrategy': 'UseIP'},
          },
        },
        {'tag': 'block', 'protocol': 'blackhole'},
        {'tag': 'dns-out', 'protocol': 'dns'},
      ],
      'routing': _routing(routing, rules, proxies.balanced),
      if (proxies.balanced) 'observatory': _observatory,
      'dns': {
        'servers': dnsServers,
        if (proxies.balanced) 'tag': 'dns-internal',
        if (hosts.isNotEmpty) 'hosts': hosts,
      },
    };
  }

  /// The TUN's point-to-point network (Xray's own macOS/FreeBSD default).
  static const tunGateway = ['169.254.10.1/30'];

  /// System DNS servers while tunnelled; they sit behind the TUN's routes, so
  /// their queries reach Xray's DNS rather than the network.
  static const tunDnsServers = ['1.1.1.1', '8.8.8.8'];

  /// One core instance that tests many configs at once: an HTTP inbound per
  /// config on its own port, each routed to that config's outbound.
  /// [bindInterface]: in Tunnel mode, the physical interface the test
  /// connections must leave by, or they'd go through the VPN first.
  static Map<String, dynamic> tester(List<({V2rayProfile profile, int port})> entries, {String? bindInterface}) {
    Map<String, dynamic> bound(Map<String, dynamic> out) {
      if (bindInterface == null) return out;
      final stream = (out['streamSettings'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      stream['sockopt'] = {...?(stream['sockopt'] as Map<String, dynamic>?), 'interface': bindInterface};
      return {...out, 'streamSettings': stream};
    }

    return {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        for (var i = 0; i < entries.length; i++)
          {
            'tag': 'in$i',
            'listen': '127.0.0.1',
            'port': entries[i].port,
            'protocol': 'http',
            'settings': <String, dynamic>{},
          },
      ],
      'outbounds': [
        for (var i = 0; i < entries.length; i++) bound(outbound(entries[i].profile, tag: 'out$i')),
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          for (var i = 0; i < entries.length; i++)
            {
              'inboundTag': ['in$i'],
              'outboundTag': 'out$i',
            },
        ],
      },
    };
  }

  static String encode(Map<String, dynamic> config, {bool pretty = false}) =>
      pretty ? const JsonEncoder.withIndent('  ').convert(config) : jsonEncode(config);

  // ───────────────────────────── Android routes ─────────────────────────────

  /// IPv4 routes covering everything except [excluded] CIDRs (and plain
  /// IPs). Android's VpnService takes routes to include, not to skip.
  static List<String> ipv4RoutesExcluding(Iterable<String> excluded) {
    const total = 4294967296; // 2^32
    final ranges = <List<int>>[];
    for (final e in excluded) {
      final slash = e.indexOf('/');
      final ip = ShareLinkParser.parseIpv4(slash < 0 ? e : e.substring(0, slash));
      if (ip == null) continue;
      final bits = slash < 0 ? 32 : int.tryParse(e.substring(slash + 1));
      if (bits == null || bits < 0 || bits > 32) continue;
      final size = _pow2(32 - bits);
      final start = ip - ip % size;
      ranges.add([start, start + size - 1]);
    }
    ranges.sort((a, b) => a[0].compareTo(b[0]));
    final routes = <String>[];
    var next = 0;
    for (final r in ranges) {
      if (r[0] > next) routes.addAll(_cidrsBetween(next, r[0] - 1));
      if (r[1] + 1 > next) next = r[1] + 1;
    }
    if (next < total) routes.addAll(_cidrsBetween(next, total - 1));
    return routes;
  }

  static List<String> _cidrsBetween(int start, int end) {
    final out = <String>[];
    while (start <= end) {
      var size = 1;
      // Grow the block while it stays aligned and inside the gap.
      while (start % (size * 2) == 0 && start + size * 2 - 1 <= end && size < 4294967296) {
        size *= 2;
      }
      var bits = 32;
      for (var s = size; s > 1; s ~/= 2) {
        bits--;
      }
      out.add('${_ipv4String(start)}/$bits');
      start += size;
    }
    return out;
  }

  static int _pow2(int n) {
    var v = 1;
    for (var i = 0; i < n; i++) {
      v *= 2;
    }
    return v;
  }

  static String _ipv4String(int v) =>
      '${v ~/ 16777216}.${(v ~/ 65536) % 256}.${(v ~/ 256) % 256}.${v % 256}';

  static List<String> _list(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static Map<String, dynamic>? _jsonObject(String s) {
    if (s.trim().isEmpty) return null;
    try {
      final v = jsonDecode(s);
      return v is Map ? v.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }
}
