# flutter_v2ray 2.0.0, patched for IRNet

The Dart (`lib/`) and Android (`android/`) parts of
[flutter_v2ray 2.0.0](https://pub.dev/packages/flutter_v2ray/versions/2.0.0)
(MIT, see `LICENSE`), copied unchanged except for the patches below. The
example app, docs and Gradle wrapper are left out.

## Patches

1. **UDP inside the VPN** (`V2rayVPNService.runTun2socks`): tun2socks runs with
   `--socks5-udp` instead of `--enable-udprelay`.
   `--enable-udprelay` sends UDP datagrams straight to the SOCKS port. Xray
   stopped listening for UDP there in v26.9 (its SOCKS inbound is TCP-only and
   opens a port per UDP ASSOCIATE instead), so with the cores this plugin uses
   (v26.10.17, IRNet pins v26.11.9) every UDP packet was dropped. The VPN
   looked connected and TCP worked, but DNS lookups timed out, so most apps
   had no internet. `--socks5-udp` does a real UDP ASSOCIATE.

## Updating

When moving to a newer flutter_v2ray, copy its `lib/`, `android/` (minus
`gradlew*` and `gradle/`), `pubspec.yaml`, `CHANGELOG.md` and `LICENSE` here,
then re-apply the patches above (search for "IRNet patch").
