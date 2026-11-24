import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

class ShareLinkException implements Exception {
  const ShareLinkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What came out of a block of pasted / downloaded text.
class ParsedLinks {
  const ParsedLinks(this.profiles, {this.unsupported = 0, this.errors = const []});

  final List<V2rayProfile> profiles;

  /// Links of protocols IRNet doesn't handle (ss://, hysteria2://, …).
  final int unsupported;

  /// Links that looked like VLESS/VMess/Trojan but couldn't be read.
  final List<String> errors;
}

/// Reads vless://, vmess://, trojan:// and wireguard:// share links (the
/// v2rayN / Xray share-link conventions) and standard WireGuard configs into
/// [V2rayProfile]s.
class ShareLinkParser {
  ShareLinkParser._();

  static const supportedSchemes = ['vless', 'vmess', 'trojan', 'wireguard', 'wg'];

  /// [V2rayProfile.problem] of the placeholder entries panels use to show
  /// remaining traffic or expiry as a "server" name.
  static const infoEntryProblem = 'A note from your provider, not a server.';

  static final _anyScheme = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false);

  /// True when [line] starts like one of the supported share links.
  static bool isShareLink(String line) {
    final lower = line.trimLeft().toLowerCase();
    return supportedSchemes.any((s) => lower.startsWith('$s://'));
  }

  /// Every supported link in [text]: one per line, or a base64 blob of them
  /// (the usual subscription body).
  /// [nameHint] names WireGuard configs that carry no name (a .conf file's
  /// name, for instance).
  static ParsedLinks parseText(String text, {String? subscriptionId, String? nameHint}) {
    final profiles = <V2rayProfile>[];
    final errors = <String>[];
    var unsupported = 0;
    final seen = <String>{};

    void handleLines(String body, int depth) {
      for (final raw in const LineSplitter().convert(body)) {
        final line = _clean(raw);
        if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
        if (isShareLink(line)) {
          try {
            final profile = parse(line, subscriptionId: subscriptionId);
            if (seen.add(profile.id)) profiles.add(profile);
          } on ShareLinkException catch (e) {
            errors.add(e.message);
          }
        } else if (_anyScheme.hasMatch(line)) {
          if (!line.toLowerCase().startsWith('http')) unsupported++;
        } else if (depth == 0) {
          final decoded = decodeBase64Loose(line);
          if (decoded != null && decoded.contains('://')) handleLines(decoded, depth + 1);
        }
      }
    }

    var body = text.trim();
    var depth = 0;
    if (!body.contains('://') && !hasWireGuardConf(body)) {
      final decoded = decodeBase64Loose(body);
      if (decoded != null && (decoded.contains('://') || hasWireGuardConf(decoded))) body = decoded;
      depth = 1;
    }
    // Standard WireGuard configs ([Interface]/[Peer]) become wireguard:// links.
    final confs = extractWireGuardConfs(body, name: nameHint);
    errors.addAll(confs.errors);
    for (final link in confs.links) {
      try {
        final profile = parse(link, subscriptionId: subscriptionId);
        if (seen.add(profile.id)) profiles.add(profile);
      } on ShareLinkException catch (e) {
        errors.add(e.message);
      }
    }
    handleLines(confs.rest, depth);
    return ParsedLinks(profiles, unsupported: unsupported, errors: errors);
  }

  /// Parses a single share link. Throws [ShareLinkException] when it can't be
  /// read at all; configs the core can't use come back with a [V2rayProfile.problem].
  static V2rayProfile parse(String input, {String? subscriptionId}) {
    final link = _clean(input);
    final schemeEnd = link.indexOf('://');
    if (schemeEnd <= 0) throw const ShareLinkException('Not a share link');
    final scheme = link.substring(0, schemeEnd).toLowerCase();
    switch (scheme) {
      case 'vmess':
        return _parseVmess(link, subscriptionId);
      case 'vless':
        return _parseUri(link, V2rayProtocol.vless, subscriptionId);
      case 'trojan':
        return _parseUri(link, V2rayProtocol.trojan, subscriptionId);
      case 'wireguard':
      case 'wg':
        return _parseWireGuard(link, subscriptionId);
      default:
        throw ShareLinkException('$scheme:// links are not supported');
    }
  }

  /// Stable id for [link] inside [subscriptionId] (null = added on its own).
  static String profileId(String link, String? subscriptionId) {
    final digest = sha1.convert(utf8.encode('${subscriptionId ?? ''}\n$link'));
    return digest.toString().substring(0, 16);
  }

  /// Base64 (standard or URL-safe, padding optional, whitespace ignored) to
  /// UTF-8 text, or null when [input] isn't base64.
  static String? decodeBase64Loose(String input) {
    var s = input.replaceAll(RegExp(r'\s'), '');
    if (s.isEmpty || !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(s)) return null;
    s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
    final pad = s.length % 4;
    if (pad == 1) return null;
    if (pad > 0) s = s.padRight(s.length + 4 - pad, '=');
    try {
      return utf8.decode(base64.decode(s), allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  // ───────────────────────────── VMess ─────────────────────────────

  static V2rayProfile _parseVmess(String link, String? subscriptionId) {
    final body = link.substring('vmess://'.length);
    // Some panels write VMess in the same URI form as VLESS.
    if (body.contains('@') && decodeBase64Loose(body.split('#').first.split('?').first) == null) {
      return _parseUri(link, V2rayProtocol.vmess, subscriptionId);
    }
    final decoded = decodeBase64Loose(body.split('#').first.split('?').first);
    if (decoded == null) throw const ShareLinkException('VMess link is not valid base64');
    final Map<String, dynamic> json;
    try {
      final value = jsonDecode(decoded);
      if (value is! Map) throw const FormatException();
      json = value.cast<String, dynamic>();
    } on FormatException {
      throw const ShareLinkException('VMess link has an unknown format');
    }

    String str(String key) => (json[key] ?? '').toString().trim();

    final address = _stripBrackets(str('add'));
    final port = int.tryParse(str('port'));
    final id = str('id');
    if (address.isEmpty) throw const ShareLinkException('VMess link has no server address');
    if (port == null || port < 1 || port > 65535) {
      throw const ShareLinkException('VMess link has no valid port');
    }
    if (id.isEmpty) throw const ShareLinkException('VMess link has no user id');

    final rawNetwork = str('net').isEmpty ? 'tcp' : str('net');
    final network = _normaliseNetwork(rawNetwork);
    final type = str('type');
    final path = str('path');
    final host = str('host');
    var security = str('tls').toLowerCase();
    if (security.isEmpty || security == 'false' || security == '0') security = 'none';
    if (security == 'true' || security == '1') security = 'tls';

    final stream = StreamOptions(
      network: network ?? rawNetwork.toLowerCase(),
      security: security,
      headerType: network == 'raw' && type == 'http' ? 'http' : '',
      host: host,
      path: network == 'grpc' ? '' : path,
      serviceName: network == 'grpc' ? (str('serviceName').isNotEmpty ? str('serviceName') : path) : '',
      authority: network == 'grpc' ? (str('authority').isNotEmpty ? str('authority') : host) : '',
      mode: network == 'grpc'
          ? (str('mode').isNotEmpty ? str('mode') : type)
          : network == 'xhttp'
              ? (str('mode').isNotEmpty ? str('mode') : (type == 'none' ? '' : type))
              : '',
      extra: str('extra'),
      sni: str('sni'),
      alpn: _splitList(str('alpn')),
      fingerprint: str('fp'),
      publicKey: str('pbk'),
      shortId: str('sid'),
      spiderX: str('spx'),
      insecure: _truthy(str('allowInsecure')) || _truthy(str('insecure')),
    );
    final cipher = str('scy').isEmpty ? 'auto' : str('scy');
    final name = str('ps');
    return _finish(
      link: link,
      subscriptionId: subscriptionId,
      protocol: V2rayProtocol.vmess,
      name: name,
      address: address,
      port: port,
      credential: id,
      encryption: cipher,
      flow: '',
      stream: stream,
      rawNetwork: rawNetwork,
    );
  }

  // ─────────────────────── VLESS / Trojan / URI VMess ───────────────────────

  static V2rayProfile _parseUri(String link, V2rayProtocol protocol, String? subscriptionId) {
    var rest = link.substring(link.indexOf('://') + 3);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = _decode(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    var query = <String, String>{};
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = _parseQuery(rest.substring(q + 1));
      rest = rest.substring(0, q);
    }
    final at = rest.lastIndexOf('@');
    if (at <= 0) throw ShareLinkException('${protocol.label} link has no user id or password');
    final credential = _decode(rest.substring(0, at)).trim();
    var hostPort = rest.substring(at + 1);
    final slash = hostPort.indexOf('/');
    if (slash >= 0) hostPort = hostPort.substring(0, slash);

    String host;
    String portText;
    if (hostPort.startsWith('[')) {
      final close = hostPort.indexOf(']');
      if (close < 0) throw ShareLinkException('${protocol.label} link has a broken IPv6 address');
      host = hostPort.substring(1, close);
      portText = hostPort.substring(close + 1).replaceFirst(':', '');
    } else {
      final colon = hostPort.lastIndexOf(':');
      if (colon < 0) throw ShareLinkException('${protocol.label} link has no port');
      host = hostPort.substring(0, colon);
      portText = hostPort.substring(colon + 1);
    }
    host = _decode(host).trim();
    final port = int.tryParse(portText.trim());
    if (host.isEmpty) throw ShareLinkException('${protocol.label} link has no server address');
    if (port == null || port < 1 || port > 65535) {
      throw ShareLinkException('${protocol.label} link has no valid port');
    }
    if (credential.isEmpty) throw ShareLinkException('${protocol.label} link has no user id or password');

    String p(String key) => (query[_normKey(key)] ?? '').trim();

    final rawNetwork = p('type').isEmpty ? 'tcp' : p('type');
    final network = _normaliseNetwork(rawNetwork);
    var security = p('security').toLowerCase();
    if (security.isEmpty) {
      // Trojan is TLS unless the link says otherwise.
      security = protocol == V2rayProtocol.trojan ? 'tls' : 'none';
    }
    if (security == 'xtls') security = 'tls';
    final host2 = p('host');
    final path = p('path');
    final stream = StreamOptions(
      network: network ?? rawNetwork.toLowerCase(),
      security: security,
      headerType: network == 'raw' && p('headerType').toLowerCase() == 'http' ? 'http' : '',
      host: host2,
      path: network == 'grpc' ? '' : path,
      serviceName: network == 'grpc' ? (p('serviceName').isNotEmpty ? p('serviceName') : path) : '',
      authority: network == 'grpc' ? (p('authority').isNotEmpty ? p('authority') : '') : '',
      mode: (network == 'grpc' || network == 'xhttp') ? p('mode') : '',
      extra: p('extra'),
      sni: p('sni').isNotEmpty ? p('sni') : p('peer'),
      alpn: _splitList(p('alpn')),
      fingerprint: p('fp'),
      publicKey: p('pbk'),
      shortId: p('sid'),
      spiderX: p('spx'),
      mldsa65Verify: p('pqv'),
      pinnedPeerCertSha256: p('pcs'),
      verifyPeerCertByName: p('vcn'),
      echConfigList: p('ech'),
      insecure: _truthy(p('allowInsecure')) || _truthy(p('insecure')),
    );
    return _finish(
      link: link,
      subscriptionId: subscriptionId,
      protocol: protocol,
      name: name,
      address: host,
      port: port,
      credential: credential,
      encryption: protocol == V2rayProtocol.vless
          ? (p('encryption').isEmpty ? 'none' : p('encryption'))
          : protocol == V2rayProtocol.vmess
              ? (p('encryption').isEmpty ? 'auto' : p('encryption'))
              : '',
      flow: protocol == V2rayProtocol.trojan ? '' : p('flow'),
      stream: stream,
      rawNetwork: rawNetwork,
    );
  }

  static V2rayProfile _finish({
    required String link,
    required String? subscriptionId,
    required V2rayProtocol protocol,
    required String name,
    required String address,
    required int port,
    required String credential,
    required String encryption,
    required String flow,
    required StreamOptions stream,
    required String rawNetwork,
  }) {
    final endpoint = address.contains(':') ? '[$address]:$port' : '$address:$port';
    final cleanName = name.split(RegExp(r'[\r\n]')).first.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Panels add fake entries whose name carries "Remaining: 12 GB" etc.
    final infoEntry = const {'0.0.0.0', '127.0.0.1', '::', '::1'}.contains(address) ||
        stream.sni == 'fake_ip_for_sub_link';
    return V2rayProfile(
      id: profileId(link, subscriptionId),
      link: link,
      name: cleanName.isEmpty ? endpoint : cleanName,
      protocol: protocol,
      address: address,
      port: port,
      credential: credential,
      encryption: encryption,
      flow: flow,
      stream: stream,
      subscriptionId: subscriptionId,
      problem: infoEntry
          ? infoEntryProblem
          : _problemOf(protocol, address, encryption, flow, stream, rawNetwork),
    );
  }

  /// Why Xray 26 would reject this config, mirroring its own checks.
  static String? _problemOf(V2rayProtocol protocol, String address, String encryption, String flow,
      StreamOptions stream, String rawNetwork) {
    const transports = {'raw', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'kcp'};
    if (!transports.contains(stream.network)) {
      final n = rawNetwork.toLowerCase();
      if (n == 'h2' || n == 'http' || n == 'h3') {
        return 'Uses the HTTP/2 transport, which Xray has removed. Ask your provider for an XHTTP config.';
      }
      if (n == 'quic') {
        return 'Uses the QUIC transport, which Xray has removed. Ask your provider for an XHTTP config.';
      }
      return 'Uses the "$rawNetwork" transport, which IRNet doesn\'t support.';
    }
    if (!const {'none', 'tls', 'reality'}.contains(stream.security)) {
      return 'Uses "${stream.security}" security, which Xray doesn\'t support.';
    }
    if (stream.security == 'reality') {
      if (!const {'raw', 'xhttp', 'grpc'}.contains(stream.network)) {
        return 'REALITY only works over TCP, XHTTP or gRPC.';
      }
      if (stream.publicKey.isEmpty) return 'The REALITY public key (pbk) is missing.';
    }
    if (protocol == V2rayProtocol.vless && flow.isNotEmpty) {
      if (flow != 'xtls-rprx-vision' && flow != 'xtls-rprx-vision-udp443') {
        return 'Uses the "$flow" flow, which Xray no longer supports.';
      }
    }
    final plainVless = protocol == V2rayProtocol.vless && (encryption.isEmpty || encryption == 'none');
    if (stream.security == 'none' && (plainVless || protocol == V2rayProtocol.trojan) && !isPrivateAddress(address)) {
      return 'Has no TLS. Xray refuses unencrypted ${protocol.label} to public servers.';
    }
    return null;
  }

  /// Private / loopback / link-local IPs and local-only domains: the
  /// addresses Xray lets plain VLESS and Trojan connect to.
  static bool isPrivateAddress(String address) {
    final host = address.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final v4 = parseIpv4(host);
    if (v4 != null) {
      // Arithmetic rather than bit operators: on the web ints are 32-bit there.
      final a = v4 ~/ 16777216, b = (v4 ~/ 65536) % 256;
      return a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
          (a == 169 && b == 254);
    }
    if (host.contains(':')) {
      return host == '::1' ||
          host.startsWith('fc') ||
          host.startsWith('fd') ||
          RegExp(r'^fe[89ab][0-9a-f]?:').hasMatch(host);
    }
    return host == 'localhost' ||
        const ['.local', '.localhost', '.lan', '.internal', '.home.arpa', '.intranet', '.corp', '.private']
            .any(host.endsWith);
  }

  /// Dotted IPv4 as a 32-bit number, or null.
  static int? parseIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3 || !RegExp(r'^\d+$').hasMatch(part)) return null;
      final n = int.parse(part);
      if (n > 255) return null;
      value = value * 256 + n;
    }
    return value;
  }

  // ───────────────────────────── WireGuard ─────────────────────────────

  static final _interfaceHeader = RegExp(r'^\s*\[interface\]\s*$', caseSensitive: false, multiLine: true);

  static bool hasWireGuardConf(String text) => _interfaceHeader.hasMatch(text);

  /// `wireguard://<private key>@host:port?publickey=…&address=…#name` (the
  /// v2rayN form), and the `wg://` and parameter spellings Hiddify and
  /// sing-box use (private_key, peer_public_key, local_address, …).
  static V2rayProfile _parseWireGuard(String link, String? subscriptionId) {
    var rest = link.substring(link.indexOf('://') + 3);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = _decode(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    var query = <String, String>{};
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = _parseQuery(rest.substring(q + 1));
      rest = rest.substring(0, q);
    }
    final at = rest.lastIndexOf('@');
    var privateKey = at > 0 ? _decode(rest.substring(0, at)).trim() : '';
    var hostPort = at >= 0 ? rest.substring(at + 1) : rest;
    final slash = hostPort.indexOf('/');
    if (slash >= 0) hostPort = hostPort.substring(0, slash);
    final endpoint = _splitHostPort(_decode(hostPort));
    if (endpoint == null) throw const ShareLinkException('WireGuard link has no valid server address and port');

    String first(List<String> keys) {
      for (final k in keys) {
        final v = (query[_normKey(k)] ?? '').trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    if (privateKey.isEmpty) privateKey = first(['privatekey', 'secretkey']);
    final reserved = _parseReserved(first(['reserved']));
    final options = WireGuardOptions(
      publicKey: first(['publickey', 'peerpublickey', 'peerpk', 'serverpublickey', 'pbk']),
      preSharedKey: first(['presharedkey', 'psk']),
      addresses: _splitList(first(['address', 'localaddress', 'ip', 'ips'])).map(_withPrefix).toList(),
      mtu: int.tryParse(first(['mtu'])),
      reserved: reserved ?? const [],
      keepAlive: int.tryParse(first(['keepalive', 'persistentkeepalive'])) ?? 0,
      allowedIPs: _splitList(first(['allowedips'])),
    );
    final cleanName = name.split(RegExp(r'[\r\n]')).first.replaceAll(RegExp(r'\s+'), ' ').trim();
    final where = endpoint.host.contains(':') ? '[${endpoint.host}]:${endpoint.port}' : '${endpoint.host}:${endpoint.port}';
    final infoEntry = const {'0.0.0.0', '127.0.0.1', '::', '::1'}.contains(endpoint.host);
    return V2rayProfile(
      id: profileId(link, subscriptionId),
      link: link,
      name: cleanName.isEmpty ? 'WireGuard $where' : cleanName,
      protocol: V2rayProtocol.wireguard,
      address: endpoint.host,
      port: endpoint.port,
      credential: privateKey,
      stream: const StreamOptions(network: 'wireguard'),
      subscriptionId: subscriptionId,
      problem: infoEntry ? infoEntryProblem : _wireGuardProblem(privateKey, options, reservedValid: reserved != null),
      wireguard: options,
    );
  }

  static String? _wireGuardProblem(String privateKey, WireGuardOptions o, {required bool reservedValid}) {
    if (!isWireGuardKey(privateKey)) return 'The WireGuard private key is missing or invalid.';
    if (!isWireGuardKey(o.publicKey)) return 'The WireGuard public key of the server is missing or invalid.';
    if (o.preSharedKey.isNotEmpty && !isWireGuardKey(o.preSharedKey)) return 'The WireGuard preshared key is invalid.';
    if (o.addresses.isEmpty) return 'The WireGuard config has no Address for this device.';
    if (!reservedValid) return 'The WireGuard "reserved" value must be three bytes.';
    if (o.mtu != null && (o.mtu! < 576 || o.mtu! > 9000)) return 'The WireGuard MTU ${o.mtu} is out of range.';
    return null;
  }

  /// A 32-byte key, as base64 (with or without padding, either alphabet) or hex.
  static bool isWireGuardKey(String key) {
    final k = key.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(k)) return true;
    final decoded = _base64Bytes(k);
    return decoded != null && decoded.length == 32;
  }

  static List<int>? _base64Bytes(String s) {
    var v = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
    if (v.isEmpty || !RegExp(r'^[A-Za-z0-9+/]+$').hasMatch(v) || v.length % 4 == 1) return null;
    v = v.padRight(v.length + (4 - v.length % 4) % 4, '=');
    try {
      return base64.decode(v);
    } on FormatException {
      return null;
    }
  }

  /// "1,2,3" or base64 ("AQID"); null when it isn't three bytes.
  static List<int>? _parseReserved(String value) {
    final v = value.trim();
    if (v.isEmpty) return const [];
    if (RegExp(r'^\d+(\s*,\s*\d+)*$').hasMatch(v)) {
      final bytes = v.split(',').map((e) => int.parse(e.trim())).toList();
      return bytes.length == 3 && bytes.every((b) => b <= 255) ? bytes : null;
    }
    final bytes = _base64Bytes(v);
    return bytes != null && bytes.length == 3 ? bytes : null;
  }

  /// Tunnel addresses without a prefix length are single hosts.
  static String _withPrefix(String address) {
    if (address.contains('/')) return address;
    return address.contains(':') ? '$address/128' : '$address/32';
  }

  static ({String host, int port})? _splitHostPort(String hostPort) {
    final hp = hostPort.trim();
    String host;
    String portText;
    if (hp.startsWith('[')) {
      final close = hp.indexOf(']');
      if (close < 0) return null;
      host = hp.substring(1, close);
      portText = hp.substring(close + 1).replaceFirst(':', '');
    } else {
      final colon = hp.lastIndexOf(':');
      if (colon < 0) return null;
      host = hp.substring(0, colon);
      portText = hp.substring(colon + 1);
    }
    final port = int.tryParse(portText.trim());
    if (host.trim().isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host: host.trim(), port: port);
  }

  /// Finds standard WireGuard configs in [text] (wg-quick files, WireGuard
  /// app QR codes) and turns each into a wireguard:// link. [rest] is the
  /// text without them; [name] names a config that has no "# Name" comment.
  static ({List<String> links, String rest, List<String> errors}) extractWireGuardConfs(String text,
      {String? name}) {
    final lines = const LineSplitter().convert(text);
    final links = <String>[];
    final errors = <String>[];
    final rest = <String>[];
    final header = RegExp(r'^\s*\[(\w+)\]\s*$');
    var i = 0;
    var count = 0;
    while (i < lines.length) {
      if (!_interfaceHeader.hasMatch(lines[i])) {
        rest.add(lines[i]);
        i++;
        continue;
      }
      // One config: [Interface] and its [Peer]s, until the next [Interface]
      // or a line that isn't part of a config (a share link, say).
      final iface = <String, String>{};
      final peers = <Map<String, String>>[];
      String? confName;
      Map<String, String>? section = iface;
      i++;
      for (; i < lines.length; i++) {
        final line = lines[i].trim();
        if (_interfaceHeader.hasMatch(line)) break;
        if (line.isEmpty) continue;
        if (line.startsWith('#') || line.startsWith(';')) {
          final m = RegExp(r'^[#;]\s*name\s*[=:]\s*(.+)$', caseSensitive: false).firstMatch(line);
          if (m != null) confName ??= m.group(1)!.trim();
          // IRNet's own exports keep WARP's reserved bytes in a comment.
          final r = RegExp(r'^[#;]\s*reserved\s*[=:]\s*([0-9A-Za-z+/=,\s]+?)(\s*\(.*)?$', caseSensitive: false)
              .firstMatch(line);
          if (r != null) iface.putIfAbsent('reserved', () => r.group(1)!.trim());
          continue;
        }
        final h = header.firstMatch(line);
        if (h != null) {
          if (h.group(1)!.toLowerCase() == 'peer') {
            peers.add(section = <String, String>{});
          } else {
            section = null; // a section WireGuard doesn't know; skip its keys
          }
          continue;
        }
        final eq = line.indexOf('=');
        if (eq <= 0 || line.contains('://')) break;
        if (section == null) continue;
        final key = line.substring(0, eq).trim().toLowerCase();
        final value = line.substring(eq + 1).trim();
        // Address, DNS and AllowedIPs may repeat; the rest are single values.
        section[key] = section.containsKey(key) && const {'address', 'allowedips', 'dns'}.contains(key)
            ? '${section[key]}, $value'
            : value;
      }
      count++;
      if (iface['privatekey'] == null || peers.isEmpty || peers.first['publickey'] == null) {
        errors.add('A WireGuard config is missing its PrivateKey or [Peer] PublicKey');
        continue;
      }
      final peer = peers.first;
      final endpoint = peer['endpoint'];
      if (endpoint == null || _splitHostPort(endpoint) == null) {
        errors.add('A WireGuard config has no valid [Peer] Endpoint');
        continue;
      }
      String list(String? v) => _splitList(v ?? '').join(',');
      final params = <String, String>{
        'publickey': peer['publickey']!,
        if ((peer['presharedkey'] ?? '').isNotEmpty) 'presharedkey': peer['presharedkey']!,
        if (list(iface['address']).isNotEmpty) 'address': list(iface['address']),
        if ((iface['mtu'] ?? '').isNotEmpty) 'mtu': iface['mtu']!,
        if ((peer['persistentkeepalive'] ?? '').isNotEmpty) 'keepalive': peer['persistentkeepalive']!,
        if (list(peer['allowedips']).isNotEmpty) 'allowedips': list(peer['allowedips']),
        // Not wg-quick, but some WARP generators write it.
        if ((iface['reserved'] ?? peer['reserved'] ?? '').isNotEmpty) 'reserved': iface['reserved'] ?? peer['reserved']!,
      };
      final label = confName ?? (name != null && name.trim().isNotEmpty ? name.trim() : null);
      final query = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
      final fragment = label == null ? '' : '#${Uri.encodeComponent(count > 1 ? '$label $count' : label)}';
      links.add('wireguard://${Uri.encodeComponent(iface['privatekey']!)}@$endpoint?$query$fragment');
    }
    return (links: links, rest: rest.join('\n'), errors: errors);
  }

  /// A WireGuard profile as a standard config (WireGuard apps, wg-quick).
  /// "reserved" has no place in that format, so it goes in as a comment.
  static String wireGuardConf(V2rayProfile p) {
    final wg = p.wireguard!;
    final endpoint = p.address.contains(':') ? '[${p.address}]:${p.port}' : '${p.address}:${p.port}';
    return [
      '[Interface]',
      '# Name = ${p.name}',
      'PrivateKey = ${p.credential}',
      if (wg.addresses.isNotEmpty) 'Address = ${wg.addresses.join(', ')}',
      'DNS = 1.1.1.1, 8.8.8.8',
      if (wg.mtu != null) 'MTU = ${wg.mtu}',
      if (wg.reserved.length == 3) '# Reserved = ${wg.reserved.join(',')} (IRNet, v2rayN and Hiddify use it)',
      '',
      '[Peer]',
      'PublicKey = ${wg.publicKey}',
      if (wg.preSharedKey.isNotEmpty) 'PresharedKey = ${wg.preSharedKey}',
      'AllowedIPs = ${wg.allowedIPs.isEmpty ? '0.0.0.0/0, ::/0' : wg.allowedIPs.join(', ')}',
      'Endpoint = $endpoint',
      if (wg.keepAlive > 0) 'PersistentKeepalive = ${wg.keepAlive}',
      '',
    ].join('\n');
  }

  // ───────────────────────────── helpers ─────────────────────────────

  static String? _normaliseNetwork(String raw) {
    switch (raw.toLowerCase()) {
      case '':
      case 'tcp':
      case 'raw':
        return 'raw';
      case 'ws':
      case 'websocket':
        return 'ws';
      case 'grpc':
      case 'gun':
        return 'grpc';
      case 'httpupgrade':
        return 'httpupgrade';
      case 'xhttp':
      case 'splithttp':
        return 'xhttp';
      case 'kcp':
      case 'mkcp':
        return 'kcp';
      default:
        return null;
    }
  }

  /// Removes stray whitespace and invisible characters that messengers add.
  static String _clean(String s) =>
      s.replaceAll(RegExp('[\u200B-\u200F\u2060\uFEFF]'), '').trim();

  static String _stripBrackets(String host) =>
      host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;

  static String _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return s;
    } on FormatException {
      return s;
    }
  }

  /// "allowInsecure", "allow_insecure" and "allow-insecure" are one key.
  static String _normKey(String key) => key.toLowerCase().replaceAll(RegExp('[_-]'), '');

  static Map<String, String> _parseQuery(String query) {
    final out = <String, String>{};
    for (final part in query.replaceAll('&amp;', '&').split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = _normKey(_decode(eq < 0 ? part : part.substring(0, eq)).trim());
      final value = eq < 0 ? '' : _decode(part.substring(eq + 1));
      if (key.isNotEmpty) out.putIfAbsent(key, () => value);
    }
    return out;
  }

  static List<String> _splitList(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static bool _truthy(String s) {
    final v = s.toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }
}
