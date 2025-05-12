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
}