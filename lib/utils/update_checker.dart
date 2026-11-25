import 'dart:convert';

import 'package:http/http.dart' as http;

/// A newer IRNet release on GitHub.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.url, this.name});

  /// "1.7.0" (a leading "v" removed).
  final String version;

  /// The release page, where the downloads are.
  final String url;
  final String? name;
}

/// Asks GitHub for the latest IRNet release (drafts and pre-releases are
/// never "latest") and says whether it's newer than the running version.
class UpdateChecker {
  UpdateChecker({required this.client, this.repo = defaultRepo});

  static const defaultRepo = 'javaherisaber/ir_net';
  static const releasesPage = 'https://github.com/$defaultRepo/releases';

  final http.Client client;
  final String repo;

  /// The latest release when it's newer than [current], else null. Throws
  /// when GitHub can't be reached or answers oddly.
  Future<UpdateInfo?> newerThan(String current) async {
    final response = await client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'IRNet'},
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw http.ClientException('GitHub answered ${response.statusCode}');
    final json = jsonDecode(response.body);
    if (json is! Map) throw const FormatException('Unexpected release data');
    final tag = '${json['tag_name'] ?? ''}'.trim();
    if (tag.isEmpty || json['draft'] == true || json['prerelease'] == true) return null;
    if (!isNewer(tag, current)) return null;
    final url = '${json['html_url'] ?? ''}';
    return UpdateInfo(
      version: _clean(tag),
      url: url.startsWith('https://github.com/') ? url : releasesPage,
      name: json['name'] is String ? json['name'] as String : null,
    );
  }

  /// Whether [candidate] ("v1.10.0") is a later version than [current]
  /// ("1.9.2+13"): numeric parts compared in order; a release beats a
  /// pre-release of the same numbers ("1.7.0" > "1.7.0-beta").
  static bool isNewer(String candidate, String current) => compare(candidate, current) > 0;

  static int compare(String a, String b) {
    final (na, pa) = _parse(a);
    final (nb, pb) = _parse(b);
    for (var i = 0; i < 4; i++) {
      final x = i < na.length ? na[i] : 0;
      final y = i < nb.length ? nb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    if (pa == pb) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pa.compareTo(pb);
  }

  static String _clean(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    return s.split('+').first;
  }

  static (List<int>, String?) _parse(String v) {
    final s = _clean(v);
    final dash = s.indexOf('-');
    final core = dash < 0 ? s : s.substring(0, dash);
    final pre = dash < 0 ? null : s.substring(dash + 1);
    final numbers = [for (final part in core.split('.')) int.tryParse(part.trim()) ?? 0];
    return (numbers, pre);
  }
}
