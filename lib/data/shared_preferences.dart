import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSharedPreferences {
  static Future<String?> get kerioIP async {
    return (await _preference).getString(_keyKerioIP);
  }

  static Future<void> setKerioIP(String value) async {
    (await _preference).setString(_keyKerioIP, value);
  }

  static Future<String?> get kerioUsername async {
    return (await _preference).getString(_keyKerioUsername);
  }

  static Future<void> setKerioUsername(String value) async {
    (await _preference).setString(_keyKerioUsername, value);
  }

  static Future<String?> get kerioPassword async {
    return (await _preference).getString(_keyKerioPassword);
  }

  static Future<void> setKerioPassword(String value) async {
    (await _preference).setString(_keyKerioPassword, value);
  }

  static Future<bool> get kerioAutoLogin async {
    return (await _preference).getBool(_keyKerioAutoLogin) ?? true;
  }

  static Future<void> setKerioAutoLogin(bool value) async {
    (await _preference).setBool(_keyKerioAutoLogin, value);
  }

  static Future<int> get kerioLowBalanceToastCount async {
    return (await _preference).getInt(_keyKerioLowBalanceToastCount) ?? 0;
  }

  static Future<void> setKerioLowBalanceToastCount(int value) async {
    (await _preference).setInt(_keyKerioLowBalanceToastCount, value);
  }

  static Future<String?> get kerioLowBalanceToastDate async {
    return (await _preference).getString(_keyKerioLowBalanceToastDate);
  }

  static Future<void> setKerioLowBalanceToastDate(String value) async {
    (await _preference).setString(_keyKerioLowBalanceToastDate, value);
  }

  static Future<bool> get showLeakInSysTray async {
    return (await _preference).getBool(_keyShowLeakInSysTray) ?? true;
  }

  static Future<void> setShowLeakInSysTray(bool value) async {
    (await _preference).setBool(_keyShowLeakInSysTray, value);
  }

  static Future<bool> get isLeakPrePopulated async {
    return (await _preference).getBool(_keyIsLeakPrePopulated) ?? false;
  }

  static Future<void> setIsLeakPrePopulated(bool value) async {
    (await _preference).setBool(_keyIsLeakPrePopulated, value);
  }

  static Future<List<String>> get leakChecklist async {
    return ((await _preference).getString(_keyLeakCheckList) ?? '').split(';');
  }

  static Future<void> addToLeakChecklist(String value) async {
    var checklist = ((await _preference).getString(_keyLeakCheckList) ?? '');
    if (checklist == '') {
      checklist += value;
    } else {
      checklist += ';$value';
    }
    (await _preference).setString(_keyLeakCheckList, checklist);
  }

  static Future<void> removeFromLeakChecklist(String value) async {
    final previousChecklist = await leakChecklist;
    previousChecklist.removeWhere((element) => element == value);
    (await _preference).setString(_keyLeakCheckList, previousChecklist.join(';'));
  }

  static Future<bool> get qualityMonitoring async {
    return (await _preference).getBool(_keyQualityMonitoring) ?? true;
  }

  static Future<void> setQualityMonitoring(bool value) async {
    (await _preference).setBool(_keyQualityMonitoring, value);
  }

  /// Seconds between quality probes.
  static Future<int> get qualityInterval async {
    return (await _preference).getInt(_keyQualityInterval) ?? 2;
  }

  static Future<void> setQualityInterval(int value) async {
    (await _preference).setInt(_keyQualityInterval, value);
  }

  static Future<bool> get usageTracking async {
    return (await _preference).getBool(_keyUsageTracking) ?? true;
  }

  static Future<void> setUsageTracking(bool value) async {
    (await _preference).setBool(_keyUsageTracking, value);
  }

  /// Whether destination addresses may be looked up (country and owner via
  /// geojs.io, host names via reverse DNS).
  static Future<bool> get usageLookups async {
    return (await _preference).getBool(_keyUsageLookups) ?? true;
  }

  static Future<void> setUsageLookups(bool value) async {
    (await _preference).setBool(_keyUsageLookups, value);
  }

  /// Whether past per-app usage the OS kept has been imported (once).
  static Future<bool> get usageImported async {
    return (await _preference).getBool(_keyUsageImported) ?? false;
  }

  static Future<void> setUsageImported(bool value) async {
    (await _preference).setBool(_keyUsageImported, value);
  }

  /// Forgets the cached instance so tests can start from fresh mock values.
  @visibleForTesting
  static void resetCache() => __instance = null;

  static SharedPreferences? __instance;
  static Future<SharedPreferences> get _preference async {
    __instance ??= await SharedPreferences.getInstance();
    return __instance!;
  }

  static const _keyIsLeakPrePopulated = 'isLeakPrePopulated';
  static const _keyShowLeakInSysTray = 'showLeakInSysTray';
  static const _keyLeakCheckList = 'leakChecklist';
  static const _keyKerioIP = 'kerioIP';
  static const _keyKerioUsername = 'kerioUsername';
  static const _keyKerioPassword = 'kerioPassword';
  static const _keyKerioAutoLogin = 'kerioAutoLogin';
  static const _keyKerioLowBalanceToastCount = 'kerioLowBalanceToastCount';
  static const _keyKerioLowBalanceToastDate = 'kerioLowBalanceToastDate';
  static const _keyQualityMonitoring = 'qualityMonitoring';
  static const _keyQualityInterval = 'qualityInterval';
  static const _keyUsageTracking = 'usageTracking';
  static const _keyUsageLookups = 'usageLookups';
  static const _keyUsageImported = 'usageImported';
}