import 'dart:io';

/// What kind of address a remote endpoint is.
enum IpKind {
  public,
  private,
  loopback,
  linkLocal,
  multicast,
  unspecified,

  /// 198.18.0.0/15: the "fake IP" pool VPN clients (Clash, sing-box, Surge…)
  /// hand out from their DNS so they can route by domain. The real
  /// destination is hidden behind it.
  fakeIp,

  /// 100.64.0.0/10: carrier-grade NAT, also used by Tailscale.
  cgnat,
}

/// Classifies a textual IPv4/IPv6 address. Unparseable input is [IpKind.unspecified].
IpKind classifyIp(String ip) {
  final address = InternetAddress.tryParse(ip);
  if (address == null) return IpKind.unspecified;
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) return _classifyV4(b);

  // IPv4-mapped (::ffff:a.b.c.d).
  final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _classifyV4(b.sublist(12));
  if (b.every((x) => x == 0)) return IpKind.unspecified;
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return IpKind.loopback;
  if (b[0] == 0xff) return IpKind.multicast;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return IpKind.linkLocal;
  if ((b[0] & 0xfe) == 0xfc) return IpKind.private; // unique local fc00::/7
  return IpKind.public;
}

IpKind _classifyV4(List<int> b) {
  final a0 = b[0], a1 = b[1];
  if (a0 == 0) return IpKind.unspecified;
  if (a0 == 127) return IpKind.loopback;
  if (a0 == 10) return IpKind.private;
  if (a0 == 172 && a1 >= 16 && a1 <= 31) return IpKind.private;
  if (a0 == 192 && a1 == 168) return IpKind.private;
  if (a0 == 169 && a1 == 254) return IpKind.linkLocal;
  if (a0 == 100 && a1 >= 64 && a1 <= 127) return IpKind.cgnat;
  if (a0 == 198 && (a1 == 18 || a1 == 19)) return IpKind.fakeIp;
  if (a0 >= 224) return IpKind.multicast; // multicast, reserved and broadcast
  return IpKind.public;
}

/// Traffic to these never leaves the machine or the LAN, so it is not
/// internet usage.
bool isLocalTraffic(IpKind kind) =>
    kind == IpKind.loopback ||
    kind == IpKind.linkLocal ||
    kind == IpKind.multicast ||
    kind == IpKind.private ||
    kind == IpKind.unspecified;

/// Remote ports of LAN service discovery (mDNS, NetBIOS, SSDP, LLMNR) that
/// shows up on unconnected UDP sockets.
const localDiscoveryPorts = {5353, 137, 138, 1900, 5355};

/// Two-label public suffixes common enough to matter for reverse-DNS names.
const _secondLevelSuffixes = {
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'ltd.uk', 'plc.uk', 'me.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'co.nz', 'net.nz', 'org.nz',
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'co.kr', 'or.kr', 'ne.kr',
  'com.br', 'net.br', 'com.cn', 'net.cn', 'org.cn', 'com.hk', 'net.hk',
  'com.tw', 'net.tw', 'com.sg', 'com.my', 'net.my', 'co.id', 'net.id',
  'co.in', 'net.in', 'co.il', 'net.il', 'com.tr', 'net.tr', 'co.za',
  'com.mx', 'com.ar', 'com.ua', 'net.ua', 'com.ru', 'net.ru', 'org.ru',
  'co.ir', 'ac.ir', 'org.ir', 'net.ir', 'gov.ir', 'id.ir', 'com.sa',
  'com.eg', 'com.pk', 'net.pk', 'com.ng', 'com.vn', 'net.vn', 'co.th',
  'in.th', 'com.ph', 'com.pl', 'net.pl', 'com.es', 'com.co', 'com.pe',
};

/// "lhr48s27-in-f14.1e100.net" → "1e100.net". Returns null for input that
/// isn't a host name.
String? registrableDomain(String? host) {
  if (host == null) return null;
  var h = host.trim().toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty || InternetAddress.tryParse(h) != null) return null;
  final labels = h.split('.').where((l) => l.isNotEmpty).toList();
  if (labels.length < 2) return null;
  final lastTwo = '${labels[labels.length - 2]}.${labels.last}';
  if (_secondLevelSuffixes.contains(lastTwo) && labels.length >= 3) {
    return '${labels[labels.length - 3]}.$lastTwo';
  }
  return lastTwo;
}

/// Keys of the "domain" dimension that are not real domains.
class DomainKeys {
  DomainKeys._();

  /// Destination unknown: unconnected sockets, or the remote end never seen.
  static const unknown = '#unknown';
  static const fakeIp = '#fakeip';
  static const cgnat = '#cgnat';

  /// Prefix for "network owner" keys used when an IP has no reverse DNS,
  /// e.g. "@Cloudflare, Inc.".
  static const providerPrefix = '@';

  static bool isProvider(String key) => key.startsWith(providerPrefix);
  static bool isSpecial(String key) => key.startsWith('#');
}

/// The "domain" bucket an address is counted under: its reverse-DNS domain,
/// else its network owner, else the address itself.
String domainKeyFor({
  required IpKind kind,
  String? host,
  String? org,
  String? ip,
}) {
  switch (kind) {
    case IpKind.fakeIp:
      return DomainKeys.fakeIp;
    case IpKind.cgnat:
      return DomainKeys.cgnat;
    default:
      break;
  }
  final domain = registrableDomain(host);
  if (domain != null) return domain;
  if (org != null && org.trim().isNotEmpty) return '${DomainKeys.providerPrefix}${org.trim()}';
  return (ip == null || ip.isEmpty) ? DomainKeys.unknown : ip;
}
