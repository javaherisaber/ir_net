import 'dart:convert';
import 'dart:typed_data';

/// What an imported .dat file holds.
enum GeoKind {
  ip('GeoIP'),
  site('GeoSite');

  const GeoKind(this.label);
  final String label;
}

/// A geoip/geosite .dat file the user imported. Xray reads it from its asset
/// directory: `geoip:tag` / `geosite:tag` use geoip.dat / geosite.dat, any
/// other file name is used as `ext:<file>:tag`.
class GeoAsset {
  const GeoAsset({
    required this.fileName,
    required this.kind,
    required this.size,
    required this.tags,
    required this.importedAt,
  });

  final String fileName;
  final GeoKind kind;
  final int size;

  /// Category / country codes in the file, lower-case ("ir", "category-ir").
  final List<String> tags;

  /// Unix milliseconds.
  final int importedAt;

  bool hasTag(String tag) => tags.contains(tag.toLowerCase());

  /// The rule that sends [tag] of this file direct.
  String ruleFor(String tag) {
    final t = tag.toLowerCase();
    if (fileName == 'geoip.dat' && kind == GeoKind.ip) return 'geoip:$t';
    if (fileName == 'geosite.dat' && kind == GeoKind.site) return 'geosite:$t';
    return 'ext:$fileName:$t';
  }

  Map<String, dynamic> toJson() => {
        'file': fileName,
        'kind': kind.name,
        'size': size,
        'tags': tags,
        'at': importedAt,
      };

  factory GeoAsset.fromJson(Map<String, dynamic> json) => GeoAsset(
        fileName: json['file'] as String,
        kind: json['kind'] == 'ip' ? GeoKind.ip : GeoKind.site,
        size: (json['size'] as num?)?.toInt() ?? 0,
        tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
        importedAt: (json['at'] as num?)?.toInt() ?? 0,
      );
}

class GeoInfo {
  const GeoInfo(this.kind, this.tags);
  final GeoKind kind;
  final List<String> tags;
}

/// Reads the kind and tags of a v2ray/Xray geo .dat file without a
/// protobuf library. Both formats are `repeated Entry entry = 1`, where an
/// entry is `string code = 1` plus repeated messages in field 2: a GeoIP CIDR
/// starts with its `bytes ip = 1` (tag 0x0a), a GeoSite Domain with its
/// `type = 1` varint (0x08) or, for the default type, its `value = 2` (0x12).
/// Returns null for anything else.
GeoInfo? inspectGeoFile(Uint8List bytes) {
  var pos = 0;
  int? readVarint() {
    var result = 0;
    var multiplier = 1;
    for (var i = 0; i < 10; i++) {
      if (pos >= bytes.length) return null;
      final b = bytes[pos++];
      result += (b & 0x7f) * multiplier;
      if (b < 0x80) return result;
      multiplier *= 128;
    }
    return null;
  }

  final tags = <String>[];
  GeoKind? kind;
  while (pos < bytes.length) {
    final key = readVarint();
    if (key == null || key != 0x0a) return null; // field 1, length-delimited
    final length = readVarint();
    if (length == null || pos + length > bytes.length) return null;
    final end = pos + length;
    String? code;
    while (pos < end) {
      final k = readVarint();
      if (k == null) return null;
      final field = k ~/ 8;
      final wire = k % 8;
      if (wire == 2) {
        final l = readVarint();
        if (l == null || pos + l > end) return null;
        if (field == 1) {
          code = utf8.decode(bytes.sublist(pos, pos + l), allowMalformed: true);
        } else if (field == 2 && kind == null && l > 0) {
          final first = bytes[pos];
          if (first == 0x0a) {
            kind = GeoKind.ip;
          } else if (first == 0x08 || first == 0x12) {
            kind = GeoKind.site;
          }
        }
        pos += l;
      } else if (wire == 0) {
        if (readVarint() == null) return null;
      } else if (wire == 5) {
        pos += 4;
      } else if (wire == 1) {
        pos += 8;
      } else {
        return null;
      }
    }
    pos = end;
    if (code == null || code.isEmpty) return null;
    tags.add(code.toLowerCase());
  }
  if (tags.isEmpty || kind == null) return null;
  tags.sort();
  return GeoInfo(kind, tags);
}

/// Keeps file names to what Xray's `ext:` syntax can reference.
String sanitizeGeoFileName(String name) {
  var base = name.split(RegExp(r'[/\\]')).last.trim().toLowerCase();
  base = base.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
  if (!base.endsWith('.dat')) base = '$base.dat';
  return base;
}
