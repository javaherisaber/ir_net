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
}
