import 'package:shared_preferences/shared_preferences.dart';

class AppSharedPreferences {
  static SharedPreferences? __instance;

  static Future<SharedPreferences> get _preference async {
    __instance ??= await SharedPreferences.getInstance();
    return __instance!;
  }

  static Future<bool> get showLeakInSysTray async {
    return (await _preference).getBool(_keyShowLeakInSysTray) ?? false;
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

  static const _keyIsLeakPrePopulated = 'isLeakPrePopulated';
  static const _keyShowLeakInSysTray = 'showLeakInSysTray';
  static const _keyLeakCheckList = 'leakChecklist';
}