import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// third_party/flutter_v2ray is a patched copy of the plugin (IRNET.md);
/// these guard the patches against an update that copies upstream over them.
void main() {
  test('tun2socks carries UDP (DNS) with a real SOCKS5 UDP ASSOCIATE', () {
    final service = File(
      'third_party/flutter_v2ray/android/src/main/java/com/github/blueboytm/'
      'flutter_v2ray/v2ray/services/V2rayVPNService.java',
    ).readAsStringSync();
    // Xray v26.9+ doesn't listen for UDP on the SOCKS port, so the old relay
    // mode loses every DNS lookup in the tunnel.
    expect(service, contains('"--socks5-udp"'));
    expect(service, isNot(contains('"--enable-udprelay"')));
  });

  test('Xray TUN mode keeps no app out, so cloned apps are in the VPN', () {
    const dir = 'third_party/flutter_v2ray/android/src/main/java/com/github/blueboytm/flutter_v2ray/v2ray';
    final service = File('$dir/services/V2rayVPNService.java').readAsStringSync();
    expect(service, contains('startXrayTun'));
    expect(service, contains('buildTun(false)'));
    expect(service, contains('sockopt.put("interface"'));
    expect(File('$dir/utils/Utilities.java').readAsStringSync(), contains('XRAY_TUN = true'));
    expect(File('$dir/core/AppProcessFinder.java').existsSync(), isTrue);
    expect(File('$dir/core/V2rayCoreManager.java').readAsStringSync(), contains('restartLoop'));
  });
}
