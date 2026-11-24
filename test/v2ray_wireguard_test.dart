import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ir_net/v2ray/models.dart';
import 'package:ir_net/v2ray/qr_image.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray/xray_config.dart';
import 'package:zxing2/qrcode.dart';

// Keys from the WireGuard documentation examples.
const _priv = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const _pub = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';
const _psk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

const _conf = '''
[Interface]
PrivateKey = $_priv
Address = 172.16.0.2/32
Address = 2606:4700:110:8a36::1
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $_pub
PresharedKey = $_psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
''';

void main() {
  test('reads a v2rayN wireguard:// link', () {
    final p = ShareLinkParser.parse('wireguard://${Uri.encodeComponent(_priv)}@162.159.192.1:2408/'
        '?publickey=${Uri.encodeComponent(_pub)}&reserved=1%2C2%2C3'
        '&address=172.16.0.2%2F32%2C2606%3A4700%3A110%3A8a36%3A%3A1%2F128&mtu=1280#WARP');
    expect(p.protocol, V2rayProtocol.wireguard);
    expect(p.name, 'WARP');
    expect(p.address, '162.159.192.1');
    expect(p.port, 2408);
    expect(p.credential, _priv);
    expect(p.problem, isNull);
    final wg = p.wireguard!;
    expect(wg.publicKey, _pub);
    expect(wg.addresses, ['172.16.0.2/32', '2606:4700:110:8a36::1/128']);
    expect(wg.reserved, [1, 2, 3]);
    expect(wg.mtu, 1280);
    expect(p.stream.label, 'udp');
  });

  test('reads wg:// with sing-box style parameter names and base64 reserved', () {
    final p = ShareLinkParser.parse('wg://[2001:db8::7]:51820?private_key=${Uri.encodeComponent(_priv)}'
        '&peer_public_key=${Uri.encodeComponent(_pub)}&local_address=10.8.0.2&reserved=AQID&keepalive=15#home');
    expect(p.address, '2001:db8::7');
    expect(p.credential, _priv);
    expect(p.wireguard!.addresses, ['10.8.0.2/32']);
    expect(p.wireguard!.reserved, [1, 2, 3]);
    expect(p.wireguard!.keepAlive, 15);
    expect(p.problem, isNull);
  });

  test('flags WireGuard configs Xray would reject', () {
    String link(String extra) => 'wireguard://${Uri.encodeComponent(_priv)}@1.2.3.4:51820?publickey=${Uri.encodeComponent(_pub)}$extra';
    expect(ShareLinkParser.parse(link('')).problem, contains('no Address'));
    expect(ShareLinkParser.parse(link('&address=10.0.0.2&reserved=1,2')).problem, contains('three bytes'));
    expect(ShareLinkParser.parse('wireguard://short@1.2.3.4:51820?publickey=${Uri.encodeComponent(_pub)}&address=10.0.0.2')
        .problem, contains('private key'));
    expect(ShareLinkParser.parse(link('&address=10.0.0.2&mtu=40')).problem, contains('MTU'));
    expect(() => ShareLinkParser.parse('wireguard://key@nohost'), throwsA(isA<ShareLinkException>()));
  });

  test('turns a WireGuard .conf into a config, named after the file', () {
    final r = ShareLinkParser.parseText(_conf, nameHint: 'warp-de');
    expect(r.errors, isEmpty);
    final p = r.profiles.single;
    expect(p.name, 'warp-de');
    expect(p.link, startsWith('wireguard://'));
    expect(p.address, 'engage.cloudflareclient.com');
    expect(p.port, 2408);
    final wg = p.wireguard!;
    expect(wg.addresses, ['172.16.0.2/32', '2606:4700:110:8a36::1/128']);
    expect(wg.preSharedKey, _psk);
    expect(wg.keepAlive, 25);
    expect(wg.mtu, 1280);
    expect(wg.allowedIPs, ['0.0.0.0/0', '::/0']);
    expect(p.problem, isNull);
    // The same config again is the same config (dedupe by id).
    expect(ShareLinkParser.parseText(_conf, nameHint: 'warp-de').profiles.single.id, p.id);
  });

  test('a "# Name" comment names it; configs and links mix in one paste', () {
    final text = '# exported\nvless://2f6a8a0e-5b7c-4d1e-9f3a-1b2c3d4e5f60@a.example.com:443?security=tls#A\n'
        '${_conf.replaceFirst('[Interface]', '[Interface]\n# Name = Office')}\n'
        'trojan://pw@b.example.com:443#B\n';
    final r = ShareLinkParser.parseText(text);
    expect(r.profiles.map((p) => p.name), containsAll(['A', 'Office', 'B']));
    expect(r.profiles, hasLength(3));
  });

  test('reports configs without a peer or endpoint', () {
    final r = ShareLinkParser.parseText('[Interface]\nPrivateKey = $_priv\nAddress = 10.0.0.2/32\n');
    expect(r.profiles, isEmpty);
    expect(r.errors.single, contains('[Peer] PublicKey'));
    final noEndpoint = ShareLinkParser.parseText('[Interface]\nPrivateKey = $_priv\n[Peer]\nPublicKey = $_pub\n');
    expect(noEndpoint.errors.single, contains('Endpoint'));
  });

  test('builds Xray\'s WireGuard outbound, userspace only', () {
    final p = ShareLinkParser.parseText(_conf, nameHint: 'w').profiles.single;
    final out = XrayConfigBuilder.outbound(p);
    expect(out, {
      'tag': 'proxy',
      'protocol': 'wireguard',
      'settings': {
        'secretKey': _priv,
        'address': ['172.16.0.2/32', '2606:4700:110:8a36::1/128'],
        'peers': [
          {
            'publicKey': _pub,
            'preSharedKey': _psk,
            'endpoint': 'engage.cloudflareclient.com:2408',
            'keepAlive': 25,
            'allowedIPs': ['0.0.0.0/0', '::/0'],
          }
        ],
        'mtu': 1280,
        'noKernelTun': true,
      },
    });
    // Tunnel mode points it at the address looked up before the tunnel (IPv4 first).
    final tunnel = XrayConfigBuilder.tunnel(p, httpPort: 1, os: 'macos', hosts: {
      'engage.cloudflareclient.com': ['2606:4700:d0::a29f:c001', '162.159.192.1']
    });
    final proxy = (tunnel['outbounds'] as List).first;
    expect(proxy['settings']['peers'][0]['endpoint'], '162.159.192.1:2408');
    expect(proxy.containsKey('streamSettings'), isFalse);
    jsonEncode(tunnel);
  });

  test('a WireGuard app QR code imports', () async {
    final matrix = Encoder.encode(_conf, ErrorCorrectionLevel.l).matrix!;
    const scale = 6, quiet = 4;
    final size = (matrix.width + quiet * 2) * scale;
    final image = img.Image(width: size, height: size);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 1) {
          img.fillRect(image,
              x1: (x + quiet) * scale,
              y1: (y + quiet) * scale,
              x2: (x + quiet + 1) * scale - 1,
              y2: (y + quiet + 1) * scale - 1,
              color: img.ColorRgb8(0, 0, 0));
        }
      }
    }
    final text = await decodeQrImage(Uint8List.fromList(img.encodePng(image)));
    expect(text, isNotNull);
    final p = ShareLinkParser.parseText(text!).profiles.single;
    expect(p.protocol, V2rayProtocol.wireguard);
    expect(p.name, 'WireGuard engage.cloudflareclient.com:2408');
  });
}
