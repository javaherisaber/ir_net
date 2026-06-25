import 'package:package_info_plus/package_info_plus.dart';

/// App version, loaded once at startup so widgets can read it synchronously
/// (avoids a FutureBuilder flicker in the brand mark).
class AppInfo {
  AppInfo._();

  static String version = '';

  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
    } catch (_) {
      // Leave empty; the UI simply omits the version suffix.
    }
  }
}
