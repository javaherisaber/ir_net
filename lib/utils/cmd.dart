import 'dart:io';

class AppCmd {
  static Future<WinRegProxyResult> getProxySettings() async {
    if (Platform.isWindows) {
      return _getWindowsProxySettings();
    } else if (Platform.isLinux) {
      return _getLinuxProxySettings();
    }
    return WinRegProxyResult(false, null);
  }

  static Future<WinRegProxyResult> _getWindowsProxySettings() async {
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

  static Future<WinRegProxyResult> _getLinuxProxySettings() async {
    bool proxyEnabled = false;
    String? proxyServer;
    
    // Check gsettings for GNOME-based systems
    try {
      var gsettingsResult = await Process.run('gsettings', ['get', 'org.gnome.system.proxy', 'mode']);
      proxyEnabled = gsettingsResult.stdout.toString().trim() == "'manual'";
      
      if (proxyEnabled) {
        var httpProxy = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.http', 'host']);
        var httpPort = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.http', 'port']);
        var host = httpProxy.stdout.toString().trim().replaceAll("'", "");
        var port = httpPort.stdout.toString().trim();
        
        if (host.isNotEmpty && port.isNotEmpty) {
          proxyServer = "$host:$port";
        }
      }
    } catch (e) {
      // gsettings not available or failed
    }
    
    // Check environment variables as fallback
    if (!proxyEnabled) {
      var envVars = Platform.environment;
      if (envVars.containsKey('http_proxy') || envVars.containsKey('HTTP_PROXY')) {
        proxyEnabled = true;
        proxyServer = envVars['http_proxy'] ?? envVars['HTTP_PROXY'];
      }
    }
    
    return WinRegProxyResult(proxyEnabled, proxyServer);
  }

  static Future<LocalNetworksResult> getLocalNetworkInfo() async {
    if (Platform.isWindows) {
      return _getWindowsNetworkInfo();
    } else if (Platform.isLinux) {
      return _getLinuxNetworkInfo();
    }
    return LocalNetworksResult([], []);
  }

  static Future<LocalNetworksResult> _getWindowsNetworkInfo() async {
    final arpAddresses = await _getWindowsArpAddresses();
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

  static Future<LocalNetworksResult> _getLinuxNetworkInfo() async {
    final interfaces = <NetworkInterface>[];
    final dnsServers = <String>[];
    
    // Get network interfaces with IP addresses
    try {
      var ipResult = await Process.run('ip', ['addr']);
      var currentInterface = '';
      
      for (var line in ipResult.stdout.toString().split('\n')) {
        if (line.startsWith(' ') && line.contains('inet ') && !line.contains('127.0.0.1')) {
          // Extract IPv4 address
          var parts = line.trim().split(' ');
          var ipIndex = parts.indexOf('inet');
          if (ipIndex >= 0 && ipIndex + 1 < parts.length) {
            var ip = parts[ipIndex + 1].split('/')[0];
            if (currentInterface.isNotEmpty) {
              interfaces.add(NetworkInterface(currentInterface, ip));
            }
          }
        } else if (!line.startsWith(' ') && line.contains(':')) {
          // Extract interface name
          var interfaceName = line.split(':')[1].trim();
          if (interfaceName.isNotEmpty && !interfaceName.startsWith('lo')) {
            currentInterface = interfaceName;
          }
        }
      }
    } catch (e) {
      // Command failed
    }
    
    // Get DNS information from resolv.conf
    try {
      var dnsResult = await Process.run('cat', ['/etc/resolv.conf']);
      for (var line in dnsResult.stdout.toString().split('\n')) {
        if (line.startsWith('nameserver')) {
          var dns = line.split('nameserver')[1].trim();
          if (dns.isNotEmpty) {
            dnsServers.add(dns);
          }
        }
      }
    } catch (e) {
      // Command failed
    }
    
    return LocalNetworksResult(interfaces, dnsServers);
  }

  static Future<List<String>> _getWindowsArpAddresses() async {
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
