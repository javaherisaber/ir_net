import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

class FlutterUtils {
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}