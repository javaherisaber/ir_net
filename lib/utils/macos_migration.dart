import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IRNet for macOS was sandboxed until the V2Ray VPN (which needs to run
/// the Xray core and set the system proxy). Unsandboxed, the app looks for
/// its data in ~/Library instead of ~/Library/Containers/<bundle id>, so on
/// the first unsandboxed launch this copies settings and the quality/usage
/// database over. Runs once; macOS may ask the user to allow access to the
/// old container. Anything it can't read is left behind.
Future<void> migrateFromMacSandbox() async {
  if (kIsWeb || !Platform.isMacOS) return;
  final home = Platform.environment['HOME'];
  // A sandboxed build sees a HOME inside its container: nothing to do.
  if (home == null || home.contains('/Library/Containers/')) return;
  try {
    final support = await getApplicationSupportDirectory();
    final bundleId = p.basename(support.path);
    final marker = File(p.join(support.path, '.migrated-from-sandbox'));
    if (marker.existsSync()) return;
    final library = p.join(home, 'Library', 'Containers', bundleId, 'Data', 'Library');
    if (Directory(library).existsSync()) {
      await _copySupportFiles(Directory(p.join(library, 'Application Support', bundleId)), support);
      await _copyPreferences(File(p.join(library, 'Preferences', '$bundleId.plist')));
    }
    await support.create(recursive: true);
    await marker.writeAsString(DateTime.now().toIso8601String());
  } catch (e) {
    debugPrint('Sandbox migration skipped: $e');
  }
}

/// The database (+ WAL) and caches, unless this location already has data.
Future<void> _copySupportFiles(Directory from, Directory to) async {
  if (!from.existsSync() || File(p.join(to.path, 'irnet.db')).existsSync()) return;
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final target = File(p.join(to.path, p.relative(entity.path, from: from.path)));
    if (target.existsSync()) continue;
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}

/// Copies the `flutter.*` keys of the old preferences file through
/// SharedPreferences, so this process's cached defaults see them at once.
Future<void> _copyPreferences(File plist) async {
  if (!plist.existsSync()) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getKeys().isNotEmpty) return;
  final xml = await Process.run('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', plist.path]);
  if (xml.exitCode != 0) return;
  for (final e in parseFlutterPrefs(xml.stdout.toString()).entries) {
    final value = e.value;
    if (value is String) {
      await prefs.setString(e.key, value);
    } else if (value is bool) {
      await prefs.setBool(e.key, value);
    } else if (value is int) {
      await prefs.setInt(e.key, value);
    } else if (value is double) {
      await prefs.setDouble(e.key, value);
    } else if (value is List<String>) {
      await prefs.setStringList(e.key, value);
    }
  }
  await prefs.reload();
}

/// The `flutter.`-prefixed values of an XML plist, without the prefix
/// (shared_preferences adds it back). Only the types it stores are read.
@visibleForTesting
Map<String, Object> parseFlutterPrefs(String xml) {
  String unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  final out = <String, Object>{};
  final entry = RegExp(
    r'<key>flutter\.([^<]*)</key>\s*(?:<string>([^<]*)</string>|<string/>|<integer>(-?\d+)</integer>|'
    r'<real>([^<]*)</real>|<(true|false)/>|<array>((?:\s*<string>[^<]*</string>|\s*<string/>)*)\s*</array>|<array/>)',
  );
  for (final m in entry.allMatches(xml)) {
    final key = unescape(m.group(1)!);
    final whole = m.group(0)!;
    if (m.group(2) != null) {
      out[key] = unescape(m.group(2)!);
    } else if (whole.endsWith('<string/>')) {
      out[key] = '';
    } else if (m.group(3) != null) {
      out[key] = int.parse(m.group(3)!);
    } else if (m.group(4) != null) {
      final d = double.tryParse(m.group(4)!);
      if (d != null) out[key] = d;
    } else if (m.group(5) != null) {
      out[key] = m.group(5) == 'true';
    } else {
      out[key] = [
        for (final s in RegExp(r'<string>([^<]*)</string>|<string/>').allMatches(m.group(6) ?? ''))
          unescape(s.group(1) ?? ''),
      ];
    }
  }
  return out;
}
