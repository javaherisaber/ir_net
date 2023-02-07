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

  static Future<LocalNetworksResult> getLocalNetworkInfo() async {
    final arpAddresses = await _getArpAddresses();
    var command = await Process.run(r'ipconfig', [r'/all']);
    final stdout = command.stdout.toString();
    if (stdout.isEmpty) {
      throw r'Cannot resolve command ipconfig /all';
    }
    final lines = stdout.split('\r\n');
    final interfaces = <NetworkInterface>[];
    var dns1 = '';
    var dns2 = '';
    var emptyLinesCount = 0;
    var interfaceName = '';
    for (var line in lines) {
      if (emptyLinesCount == 2) {
        emptyLinesCount = 0;
      }
      if (line.isEmpty) {
        emptyLinesCount++;
      }
      if (emptyLinesCount == 1 && line.contains(' adapter ')) {
        interfaceName = line.split(' adapter ')[1].replaceAll(':', '');
      }
      if (emptyLinesCount > 0) {
        continue;
      }
      if (line.contains(':') && line.contains('IPv4 Address')) {
        for (var ip in arpAddresses) {
          final ipPartOfLine = line.split(':')[1].trimLeft();
          if (interfaceName.isNotEmpty && ipPartOfLine.startsWith(ip)) {
            interfaces.add(NetworkInterface(interfaceName, ip));
            break;
          }
        }
      }
      if (dns1.isNotEmpty && dns2.isEmpty && !line.contains(':')) {
        dns2 = line.trimLeft();
      }
      if (dns2.isEmpty && line.contains('DNS Servers')) {
        dns1 = line.split(':')[1].trimLeft();
      }
    }
    return LocalNetworksResult(interfaces, [dns1, dns2]);
  }

  static Future<List<String>> _getArpAddresses() async {
    final result = <String>[];
    var command = await Process.run(r'arp', [r'-a']);
    final stdout = command.stdout.toString();
    if (stdout.isNotEmpty) {
      final lines = stdout.split('\r\n');
      for (var element in lines) {
        if (element.startsWith('Interface: ')) {
          result.add(element.split(' ')[1]);
        }
      }
    }
    return result;
  }
}

class LocalNetworksResult {
  LocalNetworksResult(this.interfaces, this.dns);

  final List<NetworkInterface> interfaces;
  final List<String> dns;
}

class NetworkInterface {
  NetworkInterface(this.interfaceName, this.ipv4);

  final String interfaceName;
  final String ipv4;
}

class WinRegProxyResult {
  WinRegProxyResult(this.proxyEnabled, this.proxyServer);

  final bool proxyEnabled;
  final String? proxyServer;
}
