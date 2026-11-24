import 'geo_assets.dart';
import 'share_link.dart';

/// A rule line that was left out, and why.
class RuleIssue {
  const RuleIssue(this.rule, this.message);
  final String rule;
  final String message;
}

/// Pass-through rules turned into Xray routing entries (sent to "direct"),
/// plus the plain domains/IPs the OS proxy bypass list can carry too.
class CompiledRules {
  const CompiledRules({
    this.domains = const [],
    this.ips = const [],
    this.osDomains = const [],
    this.osIps = const [],
    this.issues = const [],
  });

  /// Xray `domain` matchers: "domain:x", "full:x", "keyword:x",
  /// "regexp:x", "geosite:tag", "ext:file:tag".
  final List<String> domains;

  /// Xray `ip` matchers: IPs, CIDRs, "geoip:tag", "ext:file:tag".
  final List<String> ips;

  /// Plain domains (subdomains included) for OS bypass lists.
  final List<String> osDomains;

  /// Plain IPs and CIDRs for OS bypass lists and Android routes.
  final List<String> osIps;
  final List<RuleIssue> issues;

  bool get isEmpty => domains.isEmpty && ips.isEmpty;

  static const empty = CompiledRules();
}

/// User-written "pass through" (direct) rules, one per line:
///
/// ```
/// example.com           the domain and its subdomains
/// *.example.com         same
/// full:www.example.com  that exact name
/// keyword:bank          names containing "bank"
/// regexp:\.ir$          a regular expression
/// 192.168.50.0/24       an IP range (or a single IP)
/// geosite:category-ir   a category from geosite.dat
/// geoip:ir              a country from geoip.dat
/// ext:iran.dat:ir       a tag from another imported .dat file
/// # comment
/// ```
class PassThroughRules {
  PassThroughRules._();

  static const examples = [
    'geosite:category-ir',
    'geoip:ir',
    'ext:iran.dat:ir',
    'example.com',
    'keyword:bank',
    '192.168.50.0/24',
  ];

  static List<String> splitLines(String text) =>
      text.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  static CompiledRules compile(List<String> lines, List<GeoAsset> assets) {
    final domains = <String>[];
    final ips = <String>[];
    final osDomains = <String>[];
    final osIps = <String>[];
    final issues = <RuleIssue>[];

    void addUnique(List<String> list, String v) {
      if (!list.contains(v)) list.add(v);
    }

    GeoAsset? asset(String file) {
      for (final a in assets) {
        if (a.fileName == file) return a;
      }
      return null;
    }

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
      final lower = line.toLowerCase();

      if (lower.startsWith('geosite:') || lower.startsWith('geoip:')) {
        final isIp = lower.startsWith('geoip:');
        final rest = line.substring(line.indexOf(':') + 1).trim();
        final file = isIp ? 'geoip.dat' : 'geosite.dat';
        final tag = rest.replaceFirst('!', '').split('@').first.toLowerCase();
        final a = asset(file);
        if (tag.isEmpty) {
          issues.add(RuleIssue(line, 'Missing a tag after "${isIp ? 'geoip' : 'geosite'}:"'));
        } else if (a == null) {
          issues.add(RuleIssue(line, 'Import $file to use this rule'));
        } else if ((a.kind == GeoKind.ip) != isIp) {
          issues.add(RuleIssue(line, '$file holds ${a.kind.label} data, not ${isIp ? 'GeoIP' : 'GeoSite'}'));
        } else if (!a.hasTag(tag)) {
          issues.add(RuleIssue(line, '"$tag" is not in $file'));
        } else {
          addUnique(isIp ? ips : domains, '${isIp ? 'geoip' : 'geosite'}:${rest.toLowerCase()}');
        }
        continue;
      }

      if (lower.startsWith('ext:')) {
        final parts = line.substring(4).split(':');
        if (parts.length != 2 || parts[0].trim().isEmpty || parts[1].trim().isEmpty) {
          issues.add(RuleIssue(line, 'Write it as ext:<file>.dat:<tag>'));
          continue;
        }
        final file = parts[0].trim().toLowerCase();
        final tag = parts[1].trim().replaceFirst('!', '').split('@').first.toLowerCase();
        final a = asset(file);
        if (a == null) {
          issues.add(RuleIssue(line, 'Import $file to use this rule'));
        } else if (!a.hasTag(tag)) {
          issues.add(RuleIssue(line, '"$tag" is not in $file'));
        } else {
          addUnique(a.kind == GeoKind.ip ? ips : domains, 'ext:$file:${parts[1].trim().toLowerCase()}');
        }
        continue;
      }

      final prefix = RegExp(r'^(domain|full|keyword|regexp|dotless):(.*)$', caseSensitive: false).firstMatch(line);
      if (prefix != null) {
        final kind = prefix.group(1)!.toLowerCase();
        final value = prefix.group(2)!.trim();
        if (value.isEmpty && kind != 'dotless') {
          issues.add(RuleIssue(line, 'Missing a value after "$kind:"'));
          continue;
        }
        if (kind == 'regexp') {
          try {
            RegExp(value);
          } on FormatException {
            issues.add(RuleIssue(line, 'Not a valid regular expression'));
            continue;
          }
          addUnique(domains, 'regexp:$value');
        } else {
          addUnique(domains, '$kind:${value.toLowerCase()}');
          if (kind == 'domain') addUnique(osDomains, value.toLowerCase());
        }
        continue;
      }

      final plain = _plainEntry(lower);
      if (plain == null) {
        issues.add(RuleIssue(line, 'Not a domain, IP range or geo rule'));
      } else if (plain.isIp) {
        addUnique(ips, plain.value);
        addUnique(osIps, plain.value);
      } else {
        addUnique(domains, 'domain:${plain.value}');
        addUnique(osDomains, plain.value);
      }
    }
    return CompiledRules(domains: domains, ips: ips, osDomains: osDomains, osIps: osIps, issues: issues);
  }

  /// "example.com", "*.example.com", "https://example.com/x", "1.2.3.4",
  /// "1.2.3.4:80", "10.0.0.0/8", IPv6 and IPv6/CIDR.
  static ({bool isIp, String value})? _plainEntry(String input) {
    var e = input.replaceFirst(RegExp(r'^[a-z]+://'), '');
    if (_isCidr(e)) return (isIp: true, value: e);
    final slash = e.indexOf('/');
    if (slash >= 0) e = e.substring(0, slash);
    e = e.replaceAll('[', '').replaceAll(']', '');
    // "host:port" (one colon) loses the port; IPv6 has several colons.
    if (':'.allMatches(e).length == 1) e = e.substring(0, e.indexOf(':'));
    if (ShareLinkParser.parseIpv4(e) != null || _looksLikeIpv6(e)) return (isIp: true, value: e);
    e = e.replaceFirst(RegExp(r'^\*?\.'), '');
    if (RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*$').hasMatch(e)) return (isIp: false, value: e);
    return null;
  }

  static bool _isCidr(String s) {
    final slash = s.indexOf('/');
    if (slash < 0) return false;
    final bits = int.tryParse(s.substring(slash + 1));
    final ip = s.substring(0, slash);
    if (bits == null) return false;
    if (ShareLinkParser.parseIpv4(ip) != null) return bits >= 0 && bits <= 32;
    return _looksLikeIpv6(ip) && bits >= 0 && bits <= 128;
  }

  static bool _looksLikeIpv6(String s) =>
      s.contains(':') && RegExp(r'^[0-9a-f:.]+$').hasMatch(s) && s.split(':').length >= 3;
}
