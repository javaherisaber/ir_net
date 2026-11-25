import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/utils/local_network.dart';

void main() {
  test('macOS: the default resolver\'s servers from scutil --dns', () {
    const out = '''
DNS configuration

resolver #1
  search domain[0] : lan
  nameserver[0] : 1.1.1.1
  nameserver[1] : 1.0.0.1
  if_index : 25 (utun4)
  flags    : Request A records
  reach    : 0x00000003 (Reachable,Transient Connection)

resolver #2
  domain   : local
  options  : mdns
  nameserver[0] : 224.0.0.251

DNS configuration (for scoped queries)

resolver #1
  nameserver[0] : 192.168.70.1
  if_index : 15 (en0)
''';
    expect(LocalNetworkReader.parseScutilDns(out), ['1.1.1.1', '1.0.0.1']);
    expect(LocalNetworkReader.parseScutilDns('No DNS configuration available\n'), isEmpty);
  });

  test('macOS: hardware port names for devices', () {
    const out = '''

Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 00:00:00:00:00:01

Hardware Port: USB 10/100/1000 LAN
Device: en7
Ethernet Address: 98:fc:84:e6:51:0b
''';
    final ports = LocalNetworkReader.parseHardwarePorts(out);
    expect(ports, {'en0': 'Wi-Fi', 'en7': 'USB 10/100/1000 LAN'});
    expect(LocalNetworkReader.label('en0', ports), 'Wi-Fi (en0)');
    expect(LocalNetworkReader.label('utun4', ports), 'VPN tunnel (utun4)');
  });

  test('Linux and Android interface names read as what they are', () {
    expect(LocalNetworkReader.label('wlan0'), 'Wi-Fi (wlan0)');
    expect(LocalNetworkReader.label('wlp2s0'), 'Wi-Fi (wlp2s0)');
    expect(LocalNetworkReader.label('enp0s31f6'), 'Ethernet (enp0s31f6)');
    expect(LocalNetworkReader.label('rmnet_data1'), 'Mobile data (rmnet_data1)');
    expect(LocalNetworkReader.label('tun0'), 'VPN tunnel (tun0)');
    expect(LocalNetworkReader.label('docker0'), 'docker0');
  });

  test('Linux: servers from resolvectl, else resolv.conf', () {
    const resolvectl = '''
Global: 9.9.9.9#dns.quad9.net
Link 2 (wlp2s0): 192.168.1.1 fe80::1
Link 3 (irnet0):
''';
    expect(LocalNetworkReader.parseResolvectl(resolvectl), ['9.9.9.9', '192.168.1.1', 'fe80::1']);
    expect(
      LocalNetworkReader.parseResolvConf('# generated\nnameserver 127.0.0.53\noptions edns0\nnameserver 8.8.8.8\n'),
      ['127.0.0.53', '8.8.8.8'],
    );
  });
}
