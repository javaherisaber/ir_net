import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// An app the user can send around the VPN: [value] is what goes into the
/// setting (an Android package; on desktop a process name, or on macOS the
/// app bundle as a folder rule, which covers its helper processes too).
class AppChoice {
  const AppChoice(this.label, this.value);
  final String label;
  final String value;
}

/// Apps to choose from for split tunnelling.
class AppLister {
  AppLister._();

  static const _channel = MethodChannel('ir_net/xray');

  static Future<List<AppChoice>> list() async {
    if (kIsWeb) return const [];
    try {
      if (Platform.isAndroid) return _android();
      if (Platform.isMacOS) return _macApps();
      if (Platform.isWindows) return _processes('tasklist', ['/fo', 'csv', '/nh'], _windowsName);
      if (Platform.isLinux) return _processes('ps', ['-eo', 'comm='], (l) => l.trim());
    } catch (e) {
      debugPrint('App list failed: $e');
    }
    return const [];
  }

  /// How a stored [value] reads in the list of chosen apps.
  static String labelFor(String value, [List<AppChoice> known = const []]) {
    for (final a in known) {
      if (a.value == value) return a.label;
    }
    if (value.endsWith('.app/')) return p.basenameWithoutExtension(value.substring(0, value.length - 1));
    if (value.endsWith('/')) return value;
    return value;
  }

  static Future<List<AppChoice>> _android() async {
    final raw = await _channel.invokeListMethod<Map>('listApps') ?? const [];
    return [
      for (final m in raw) AppChoice('${m['label']}', '${m['package']}'),
    ];
  }

  /// .app bundles in the usual folders, as folder rules ("/Applications/X.app/").
  static Future<List<AppChoice>> _macApps() async {
    final home = Platform.environment['HOME'];
    final roots = [
      '/Applications',
      '/Applications/Utilities',
      '/System/Applications',
      if (home != null) '$home/Applications',
    ];
    final apps = <String, AppChoice>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is Directory && e.path.endsWith('.app')) {
          final name = p.basenameWithoutExtension(e.path);
          apps.putIfAbsent(name, () => AppChoice(name, '${e.path}/'));
        }
      }
    }
    return apps.values.toList()..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  static String _windowsName(String csvLine) {
    final first = csvLine.split('","').first.replaceAll('"', '').trim();
    return first.toLowerCase().endsWith('.exe') ? first.substring(0, first.length - 4) : first;
  }

  static Future<List<AppChoice>> _processes(String exe, List<String> args, String Function(String) name) async {
    final r = await Process.run(exe, args);
    final names = <String>{};
    for (final line in r.stdout.toString().split(RegExp(r'\r?\n'))) {
      final n = name(line);
      if (n.isNotEmpty && !n.startsWith('[')) names.add(n);
    }
    return (names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())))
        .map((n) => AppChoice(n, n))
        .toList();
  }
}
