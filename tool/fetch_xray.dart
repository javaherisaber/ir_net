// Downloads the Xray core that the desktop builds bundle for the V2Ray VPN.
//
//   dart run tool/fetch_xray.dart            # this machine's platform
//   dart run tool/fetch_xray.dart windows    # or macos, linux, all
//
// Writes third_party/xray/<platform>/xray[.exe] (+ LICENSE, and wintun.dll
// for Tunnel mode on Windows), which the
// macOS Xcode build phase, windows/CMakeLists.txt and linux/CMakeLists.txt
// copy next to the app's executable. The version and SHA-256 of each zip are
// pinned below; a download that doesn't match is rejected. To update, change
// [version] and the hashes (each release has a <zip>.dgst next to it).
//
// Android doesn't use this: flutter_v2ray pulls AndroidLibXrayLite (libv2ray)
// at Gradle build time.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const version = 'v26.11.9';

const zips = {
  'macos-arm64': ('Xray-macos-arm64-v8a.zip', '233f0c66681cd0726f81a6b2b6ed6a5710869e312047b522e46ed53035bebd26'),
  'macos-x64': ('Xray-macos-64.zip', '488963e676e06f5e48547f9dd38116aaca8de4234959b4272ae8f284e658dfd0'),
  'windows': ('Xray-windows-64.zip', '1262522266337b824f07beb8e1375786b437683b3890105469088f8e17e0a69d'),
  'linux': ('Xray-linux-64.zip', 'b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82'),
};

Future<void> main(List<String> args) async {
  final host = Platform.isMacOS ? 'macos' : (Platform.isWindows ? 'windows' : 'linux');
  final target = args.isEmpty ? host : args.first;
  final platforms = target == 'all' ? ['macos', 'windows', 'linux'] : [target];
  for (final platform in platforms) {
    switch (platform) {
      case 'macos':
        await _macos();
      case 'windows':
      case 'linux':
        await _single(platform);
      default:
        stderr.writeln('Unknown platform "$platform". Use macos, windows, linux or all.');
        exit(64);
    }
  }
}

Directory _out(String platform) => Directory('third_party/xray/$platform')..createSync(recursive: true);

Future<void> _single(String platform) async {
  final (zip, hash) = zips[platform]!;
  final archive = ZipDecoder().decodeBytes(await _download(zip, hash));
  final name = platform == 'windows' ? 'xray.exe' : 'xray';
  final dir = _out(platform);
  final binary = File('${dir.path}/$name')..writeAsBytesSync(_entry(archive, name));
  File('${dir.path}/LICENSE').writeAsBytesSync(_entry(archive, 'LICENSE'));
  if (platform == 'windows') {
    // Tunnel mode's TUN adapter (Xray loads it from next to xray.exe).
    File('${dir.path}/wintun.dll').writeAsBytesSync(_entry(archive, 'wintun.dll'));
    File('${dir.path}/LICENSE-Wintun').writeAsBytesSync(_entry(archive, 'LICENSE-Wintun'));
  }
  if (!Platform.isWindows) await Process.run('chmod', ['755', binary.path]);
  stdout.writeln('Xray $version for $platform → ${binary.path}');
}

/// One universal (arm64 + x86_64) binary via lipo.
Future<void> _macos() async {
  final dir = _out('macos');
  final temp = await Directory.systemTemp.createTemp('xray');
  try {
    final parts = <String>[];
    List<int>? license;
    for (final arch in ['macos-arm64', 'macos-x64']) {
      final (zip, hash) = zips[arch]!;
      final archive = ZipDecoder().decodeBytes(await _download(zip, hash));
      final part = File('${temp.path}/xray-$arch')..writeAsBytesSync(_entry(archive, 'xray'));
      parts.add(part.path);
      license ??= _entry(archive, 'LICENSE');
    }
    final out = '${dir.path}/xray';
    final lipo = await Process.run('lipo', ['-create', ...parts, '-output', out]);
    if (lipo.exitCode != 0) {
      stderr.writeln('lipo failed (needs the Xcode command line tools): ${lipo.stderr}');
      exit(1);
    }
    await Process.run('chmod', ['755', out]);
    File('${dir.path}/LICENSE').writeAsBytesSync(license!);
    stdout.writeln('Xray $version for macOS (universal) → $out');
  } finally {
    await temp.delete(recursive: true);
  }
}

List<int> _entry(Archive archive, String name) {
  for (final file in archive) {
    if (file.isFile && file.name == name) return file.content;
  }
  stderr.writeln('$name is missing from the Xray archive');
  exit(1);
}

Future<List<int>> _download(String zip, String expectedSha256) async {
  final url = Uri.parse('https://github.com/XTLS/Xray-core/releases/download/$version/$zip');
  stdout.writeln('Downloading $url');
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) {
      stderr.writeln('HTTP ${response.statusCode} for $url');
      exit(1);
    }
    final bytes = <int>[];
    await response.forEach(bytes.addAll);
    final actual = sha256.convert(bytes).toString();
    if (actual != expectedSha256) {
      stderr.writeln('SHA-256 mismatch for $zip\n  expected $expectedSha256\n  got      $actual');
      exit(1);
    }
    return bytes;
  } finally {
    client.close();
  }
}
