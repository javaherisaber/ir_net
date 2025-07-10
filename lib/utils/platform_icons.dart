import 'dart:io';

class PlatformIcons {
  static String getIconPath(String baseName) {
    return Platform.isLinux 
        ? 'assets/linux/$baseName.png' 
        : 'assets/$baseName.ico';
  }
  
  static String get loadingIcon => getIconPath('loading');
  static String get offlineIcon => getIconPath('offline');
  static String get networkErrorIcon => getIconPath('network_error');
  static String get globeIcon => getIconPath('globe');
  static String get iranIcon => getIconPath('iran');
  static String get notificationIcon => getIconPath('notification');
}
