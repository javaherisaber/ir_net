import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'xray_runner.dart';

/// setcap isn't available, so the one-time setup can't be done.
class LinuxTunnelSetupUnavailable implements Exception {
  const LinuxTunnelSetupUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Password-free Tunnel mode on Linux, without any root process.
///
/// Creating the TUN device, its routes and binding Xray's own sockets to
/// the physical interface take CAP_NET_ADMIN and CAP_NET_RAW, not root. So
/// the one-time setup (one polkit prompt) installs a copy of the core in
/// /usr/local/lib/irnet with just those file capabilities, runnable only by
/// this user's group, and IRNet runs it as the user like in Proxy mode.
///
/// The only other thing Tunnel mode changes is the link DNS through
/// systemd-resolved, which Xray does with `resolvectl` (a separate process,
/// so without the core's capabilities). A polkit rule lets this user make
/// those changes, and nothing else, without a password.
class LinuxTunnelSetup {
  LinuxTunnelSetup({Future<ProcessResult> Function(String, List<String>)? run}) : _run = run ?? Process.run;
  final Future<ProcessResult> Function(String, List<String>) _run;

  static const dir = '/usr/local/lib/irnet';
  static const xrayPath = '$dir/xray';
  static const polkitRules = '/etc/polkit-1/rules.d/49-irnet.rules';
  static const pkla = '/etc/polkit-1/localauthority/50-local.d/irnet.pkla';

  static const resolvedActions = [
    'org.freedesktop.resolve1.set-dns-servers',
    'org.freedesktop.resolve1.set-domains',
    'org.freedesktop.resolve1.set-default-route',
    'org.freedesktop.resolve1.revert',
  ];

  static String? _hash;
  static String? _hashPath;

  static Future<String> expectedVersion(String bundledXray) async {
    if (_hash == null || _hashPath != bundledXray) {
      _hash = await compute(_hashFile, bundledXray);
      _hashPath = bundledXray;
    }
    return 'xray=$_hash';
  }

  static Future<String> _hashFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

  Future<bool> isReady(String bundledXray) async {
    try {
      final version = File('$dir/VERSION');
      return File(xrayPath).existsSync() &&
          version.existsSync() &&
          version.readAsStringSync().trim() == await expectedVersion(bundledXray);
    } catch (_) {
      return false;
    }
  }

  /// One polkit (pkexec) prompt. Throws [LinuxTunnelSetupUnavailable] when
  /// setcap is missing, [XrayStartException] when the prompt is cancelled
  /// or the setup fails.
  Future<void> install(String bundledXray) async {
    if ((await _run('sh', ['-c', 'command -v setcap || test -x /usr/sbin/setcap || test -x /sbin/setcap'])).exitCode != 0) {
      throw const LinuxTunnelSetupUnavailable('setcap (libcap) is not installed');
    }
    if ((await _run('which', ['pkexec'])).exitCode != 0) {
      throw const LinuxTunnelSetupUnavailable('pkexec (polkit) is not installed');
    }
    final user = (await _run('id', ['-un'])).stdout.toString().trim();
    final group = (await _run('id', ['-gn'])).stdout.toString().trim();
    final valid = RegExp(r'^[A-Za-z0-9._][A-Za-z0-9._-]*$');
    if (!valid.hasMatch(user) || !valid.hasMatch(group)) {
      throw XrayStartException('Can\'t set up tunnel mode for the user "$user"');
    }
    final script = installScript(
        user: user, group: group, source: bundledXray, version: await expectedVersion(bundledXray));
    final r = await _run('pkexec', ['/bin/sh', '-c', script]);
    if (r.exitCode == 126 || r.exitCode == 127) {
      throw const XrayStartException('The administrator prompt was cancelled.');
    }
    if (r.exitCode != 0) {
      throw XrayStartException('Could not set up tunnel mode: ${'${r.stderr}'.trim()}');
    }
    if (!await isReady(bundledXray)) throw const XrayStartException('Tunnel mode setup did not complete');
  }

  Future<void> uninstall() async {
    final r = await _run('pkexec', ['/bin/sh', '-c', 'rm -rf $dir $polkitRules $pkla']);
    if (r.exitCode != 0) throw const XrayStartException('The tunnel setup was not removed');
  }

  static String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

  @visibleForTesting
  static String installScript({
    required String user,
    required String group,
    required String source,
    required String version,
  }) {
    final actions = resolvedActions.map((a) => '"$a"').join(', ');
    return '''
set -e
PATH=/usr/sbin:/usr/bin:/sbin:/bin
D=$dir
mkdir -p "\$D"
chown root:root "\$D"
chmod 755 "\$D"
install -o root -g ${_q(group)} -m 750 ${_q(source)} "\$D/xray.new"
setcap cap_net_admin,cap_net_raw,cap_net_bind_service+ep "\$D/xray.new"
mv -f "\$D/xray.new" "\$D/xray"
printf '%s\\n' ${_q(version)} > "\$D/VERSION"
chmod 644 "\$D/VERSION"
if [ -d /etc/polkit-1/rules.d ]; then
cat > $polkitRules <<'IRNET_POLKIT_EOF'
// IRNet: lets $user point system DNS into the VPN tunnel (systemd-resolved)
// without a password. Remove it from IRNet (VPN, Settings) or by deleting this file.
polkit.addRule(function (action, subject) {
  if (subject.user == "$user" && subject.local && subject.active &&
      [$actions].indexOf(action.id) >= 0) {
    return polkit.Result.YES;
  }
});
IRNET_POLKIT_EOF
chmod 644 $polkitRules
fi
if [ -d /etc/polkit-1/localauthority ]; then
mkdir -p /etc/polkit-1/localauthority/50-local.d
cat > $pkla <<'IRNET_PKLA_EOF'
[IRNet tunnel DNS]
Identity=unix-user:$user
Action=${resolvedActions.join(';')}
ResultAny=no
ResultInactive=no
ResultActive=yes
IRNET_PKLA_EOF
chmod 644 $pkla
fi
''';
  }
}
