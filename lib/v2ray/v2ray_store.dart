import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'share_link.dart';

/// What [V2rayStore] keeps between launches.
class V2raySnapshot {
  const V2raySnapshot({
    this.profiles = const [],
    this.subscriptions = const [],
    this.selectedId,
    this.delays = const {},
    this.settings = const V2raySettings(),
    this.assets = const [],
  });

  final List<V2rayProfile> profiles;
  final List<V2raySubscription> subscriptions;
  final String? selectedId;
  final Map<String, DelayResult> delays;
  final V2raySettings settings;
  final List<GeoAsset> assets;
}

/// Saves configs as their share links (re-parsed on load, so parser fixes
/// apply to configs imported earlier) plus subscriptions, the selection,
/// the last delay results and settings, as one JSON value.
class V2rayStore {
  static const _key = 'v2ray.v1';

  /// Separate key: written by the desktop engine before it touches the OS
  /// proxy, so a crash can be undone on the next launch.
  static const _recoveryKey = 'v2ray.recovery';

  Future<V2raySnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const V2raySnapshot();
    try {
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final profiles = <V2rayProfile>[];
      for (final item in (json['profiles'] as List? ?? const [])) {
        if (item is! Map) continue;
        final link = item['l'] as String?;
        if (link == null) continue;
        try {
          var p = ShareLinkParser.parse(link, subscriptionId: item['s'] as String?);
          final name = item['n'] as String?;
          if (name != null && name.isNotEmpty) p = p.copyWith(name: name);
          profiles.add(p);
        } on ShareLinkException catch (e) {
          debugPrint('V2rayStore: dropping unreadable config: $e');
        }
      }
      final subscriptions = [
        for (final s in (json['subscriptions'] as List? ?? const []))
          if (s is Map) V2raySubscription.fromJson(s.cast<String, dynamic>()),
      ];
      final ids = profiles.map((p) => p.id).toSet();
      final delays = <String, DelayResult>{};
      (json['delays'] as Map?)?.forEach((k, v) {
        if (k is String && v is Map && ids.contains(k)) {
          delays[k] = DelayResult.fromJson(v.cast<String, dynamic>());
        }
      });
      return V2raySnapshot(
        profiles: profiles,
        subscriptions: subscriptions,
        selectedId: json['selected'] as String?,
        delays: delays,
        settings: json['settings'] is Map
            ? V2raySettings.fromJson((json['settings'] as Map).cast<String, dynamic>())
            : const V2raySettings(),
        assets: [
          for (final a in (json['assets'] as List? ?? const []))
            if (a is Map) GeoAsset.fromJson(a.cast<String, dynamic>()),
        ],
      );
    } catch (e) {
      debugPrint('V2rayStore: could not read saved state: $e');
      return const V2raySnapshot();
    }
  }

  Future<void> save(V2rayState state) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = state.profiles.map((p) => p.id).toSet();
    await prefs.setString(
      _key,
      jsonEncode({
        'profiles': [
          for (final p in state.profiles)
            {
              'l': p.link,
              if (p.subscriptionId != null) 's': p.subscriptionId,
            },
        ],
        'subscriptions': [for (final s in state.subscriptions) s.toJson()],
        if (state.selectedId != null) 'selected': state.selectedId,
        'delays': {
          for (final e in state.delays.entries)
            if (ids.contains(e.key)) e.key: e.value.toJson(),
        },
        'settings': state.settings.toJson(),
        'assets': [for (final a in state.assets) a.toJson()],
      }),
    );
  }

  static const _notifiedKey = 'v2ray.notified';
  static const _iranRulesKey = 'v2ray.iranRulesUpdated';

  /// Which alerts went out on which day ("expiring:<sub>" → "2026-11-24").
  Future<Map<String, String>> loadNotified() async {
    final raw = (await SharedPreferences.getInstance()).getString(_notifiedKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveNotified(Map<String, String> sent) async =>
      (await SharedPreferences.getInstance()).setString(_notifiedKey, jsonEncode(sent));

  Future<int?> loadIranRulesUpdated() async => (await SharedPreferences.getInstance()).getInt(_iranRulesKey);

  Future<void> saveIranRulesUpdated(int at) async => (await SharedPreferences.getInstance()).setInt(_iranRulesKey, at);

  static const _killSwitchKey = 'v2ray.killSwitch';

  /// What the kill switch turned off, while it is off.
  Future<Map<String, dynamic>?> loadNetworkCut() async {
    final raw = (await SharedPreferences.getInstance()).getString(_killSwitchKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveNetworkCut(Map<String, dynamic>? state) async {
    final prefs = await SharedPreferences.getInstance();
    if (state == null) {
      await prefs.remove(_killSwitchKey);
    } else {
      await prefs.setString(_killSwitchKey, jsonEncode(state));
    }
  }

  Future<Map<String, dynamic>?> loadRecovery() async {
    final raw = (await SharedPreferences.getInstance()).getString(_recoveryKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRecovery(Map<String, dynamic>? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_recoveryKey);
    } else {
      await prefs.setString(_recoveryKey, jsonEncode(value));
    }
  }
}
