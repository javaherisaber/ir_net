import 'dart:io';

class AppCmd {
  static Future<WinRegProxyResult> getProxySettings() async {
    var executable = r'reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings"';
    var result = await Process.run(executable, []);
    final stdout = result.stdout.toString();
    String? proxyServer;
    var proxyIsEnabled = false;
    if (stdout.isNotEmpty) {
      final lines = stdout.split('\r\n');
      for (var element in lines) {
        if (element.contains('ProxyEnable') && element.endsWith('0x1')) {
          proxyIsEnabled = true;
        } else if (element.contains('ProxyEnable') && element.endsWith('0x0')) {
          proxyIsEnabled = false;
        }
        if (element.contains('ProxyServer')) {
          proxyServer = element.split(' ').last;
          break;
        }
      }
    }
    return WinRegProxyResult(proxyIsEnabled, proxyServer);
  }
}

class WinRegProxyResult {
  WinRegProxyResult(this.proxyEnabled, this.proxyServer);

  final bool proxyEnabled;
  final String? proxyServer;
}