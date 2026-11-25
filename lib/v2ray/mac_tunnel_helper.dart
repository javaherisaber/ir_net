import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'elevated_core.dart';
import 'xray_runner.dart';

/// Password-free Tunnel mode on macOS.
///
/// Creating the TUN device and routes needs root. Instead of a password
/// prompt on every connect, IRNet installs (with one prompt) a small helper
/// owned by root in /Library/PrivilegedHelperTools plus a sudoers rule that
/// lets this user run exactly that helper without a password.
///
/// Because anything that can run as root without a password must not be a
/// way to do *other* things as root, the helper:
///  * takes the Xray config only on stdin (it never opens a path it is
///    given), and refuses configs with anything outside what IRNet generates
///    (other inbound/outbound kinds, certificate/key/log files, `ext:` paths)
///    — and replaces the log section, so the core writes no files;
///  * runs its own root-owned copy of the core, with state (log, pids) in a
///    root-owned folder that IRNet only reads;
///  * passes only the `networksetup` subcommands IRNet uses (proxy, DNS,
///    Wi-Fi power, service on/off) on to networksetup.
class MacTunnelHelper {
  MacTunnelHelper({
    Future<ProcessResult> Function(String, List<String>)? run,
    Future<Process> Function(String, List<String>)? start,
    @visibleForTesting this.statePath = stateDir,
  })  : _run = run ?? Process.run,
        _start = start ?? Process.start;

  /// Where the helper keeps the core's log and pids (tests point elsewhere).
  final String statePath;

  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<Process> Function(String, List<String>) _start;

  static const dir = '/Library/PrivilegedHelperTools/com.buildtoapp.irnet';
  static const helperPath = '$dir/irnet-helper';
  static const stateDir = '/private/var/run/com.buildtoapp.irnet';
  static const sudoersPath = '/etc/sudoers.d/irnet';
  static const _sudo = '/usr/bin/sudo';

  static bool get isInstalled => File(helperPath).existsSync();

  static String? _xrayHash;
  static String? _xrayHashPath;

  /// What the installed copy must say in VERSION to be current: the helper
  /// scripts' hash and the bundled core's.
  static Future<String> expectedVersion(String xrayPath) async {
    if (_xrayHash == null || _xrayHashPath != xrayPath) {
      _xrayHash = await _coreHash(xrayPath);
      _xrayHashPath = xrayPath;
    }
    final scripts = sha256.convert(utf8.encode(helperScript + validatorScript)).toString();
    return 'helper=$scripts xray=$_xrayHash';
  }

  /// The core's code signature hash (CDHash): it changes with the code, but
  /// not when a build merely re-signs the same core. A developer-certificate
  /// signature carries its signing time, so the file's own hash differs on
  /// every build and would ask for the password after each update.
  static Future<String> _coreHash(String path) async {
    try {
      final r = await Process.run('/usr/bin/codesign', ['-d', '--verbose=4', path]);
      final cd = cdHashIn('${r.stderr}\n${r.stdout}');
      if (cd != null) return 'cd:$cd';
    } catch (_) {}
    return compute(_hashFile, path);
  }

  @visibleForTesting
  static String? cdHashIn(String codesignOutput) =>
      RegExp(r'^CDHash=([0-9a-f]{40,64})\s*$', multiLine: true).firstMatch(codesignOutput)?.group(1);

  static Future<String> _hashFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

  /// Installed, matching this app's core and scripts, and allowed by sudo.
  Future<bool> isReady(String xrayPath) async {
    try {
      final version = File('$dir/VERSION');
      if (!version.existsSync()) return false;
      if (version.readAsStringSync().trim() != await expectedVersion(xrayPath)) return false;
      final ping = await _run(_sudo, ['-n', helperPath, 'ping']);
      return ping.exitCode == 0 && ping.stdout.toString().trim() == 'ok';
    } catch (_) {
      return false;
    }
  }

  /// Installs or updates the helper: one administrator password prompt.
  Future<void> install(String xrayPath) async {
    final user = (await _run('/usr/bin/id', ['-un'])).stdout.toString().trim();
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(user)) {
      throw XrayStartException('Can\'t set up tunnel mode for the user name "$user"');
    }
    final script = installScript(user: user, xrayPath: xrayPath, version: await expectedVersion(xrayPath));
    await _asAdmin(script,
        'IRNet needs your password once to set up Tunnel mode. After this, it connects without asking.');
    if (!await isReady(xrayPath)) {
      throw const XrayStartException(
          'Tunnel mode was set up, but macOS still asks for a password to run it (sudo ignored the new rule).');
    }
  }

  /// Removes the helper and its sudoers rule: one password prompt.
  Future<void> uninstall() async {
    await _asAdmin(
      '[ -x $helperPath ] && $helperPath stop >/dev/null 2>&1; rm -f $sudoersPath; rm -rf $dir $stateDir',
      'IRNet needs your password to remove its Tunnel mode helper.',
    );
  }

  Future<void> _asAdmin(String script, String prompt) async {
    final command = "/bin/sh -c ${_shellQuote(script)}";
    final apple = 'do shell script "${_appleEscape(command)}" with prompt "${_appleEscape(prompt)}" '
        'with administrator privileges';
    final r = await _run('/usr/bin/osascript', ['-e', apple]);
    if (r.exitCode != 0) {
      final err = r.stderr.toString();
      throw XrayStartException(err.contains('-128')
          ? 'The password prompt was cancelled.'
          : 'Could not set up tunnel mode: ${err.trim()}');
    }
  }

  /// Starts the core through the helper (no prompt). [config] is sent on stdin.
  Future<ControlDirInstance> startCore({
    required String config,
    required String assetDir,
    required List<String> dnsServices,
    int? parentPid,
  }) async {
    final process = await _start(_sudo, ['-n', helperPath, 'start', '${parentPid ?? pid}', assetDir, ...dnsServices]);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(config);
    await process.stdin.close();
    final code = await process.exitCode;
    if (code != 0 || (await out).trim() != 'started') {
      final message = (await err).trim();
      throw XrayStartException(message.isEmpty ? 'The tunnel helper failed (exit code $code)' : message);
    }
    return ControlDirInstance(Directory(statePath), pidFile: 'xray.pid', onStop: stopCore);
  }

  Future<void> stopCore() async {
    await _run(_sudo, ['-n', helperPath, 'stop']);
  }

  /// A networksetup command through the helper (callers check
  /// [isInstalled] first); false if it can't be used.
  Future<bool> networksetup(List<String> args) async {
    try {
      final r = await _run(_sudo, ['-n', helperPath, 'net', ...args]);
      return r.exitCode == 0 && !'${r.stdout}${r.stderr}'.contains('** Error');
    } catch (_) {
      return false;
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  static String _appleEscape(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  // ───────────────────────────── scripts ─────────────────────────────

  @visibleForTesting
  static String installScript({required String user, required String xrayPath, required String version}) => '''
set -e
D=$dir
mkdir -p "\$D"
chown root:wheel "\$D"
chmod 755 "\$D"
T="\$(mktemp -d /tmp/irnet-install.XXXXXX)"
cat > "\$T/irnet-helper" <<'IRNET_HELPER_EOF'
$helperScript
IRNET_HELPER_EOF
cat > "\$T/validate.js" <<'IRNET_VALIDATE_EOF'
$validatorScript
IRNET_VALIDATE_EOF
printf '%s\\n' ${_shellQuote(version)} > "\$T/VERSION"
printf '# IRNet: lets %s start and stop the VPN tunnel without a password.\\n# Remove it from IRNet (VPN, Settings) or with: sudo rm $sudoersPath\\n%s ALL=(root) NOPASSWD: %s\\n' ${_shellQuote(user)} ${_shellQuote(user)} "\$D/irnet-helper" > "\$T/sudoers"
/usr/sbin/visudo -cf "\$T/sudoers" >/dev/null
[ -x "\$D/irnet-helper" ] && "\$D/irnet-helper" stop >/dev/null 2>&1 || true
install -o root -g wheel -m 755 "\$T/irnet-helper" "\$D/irnet-helper"
install -o root -g wheel -m 644 "\$T/validate.js" "\$D/validate.js"
install -o root -g wheel -m 755 ${_shellQuote(xrayPath)} "\$D/xray"
install -o root -g wheel -m 644 "\$T/VERSION" "\$D/VERSION"
mkdir -p /etc/sudoers.d
install -o root -g wheel -m 440 "\$T/sudoers" $sudoersPath
rm -rf "\$T"
''';

  /// Runs as root through sudo (env is reset, PATH fixed below).
  @visibleForTesting
  static const helperScript = r'''#!/bin/sh
# IRNet's Tunnel mode helper. Installed by IRNet; runs as root through sudo.
#   irnet-helper ping
#   irnet-helper start <irnet-pid> <geo-asset-dir> [<network service>...]  (config on stdin)
#   irnet-helper stop
#   irnet-helper net <networksetup subcommand> <args...>
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
HELPER_DIR=/Library/PrivilegedHelperTools/com.buildtoapp.irnet
STATE=/private/var/run/com.buildtoapp.irnet
NETWORKSETUP=/usr/sbin/networksetup
TEST=0
if [ "$(id -u)" != 0 ] && [ -n "${IRNET_HELPER_TEST_ROOT:-}" ]; then
  # Tests only: never as root, so sudo can't be pointed elsewhere.
  HELPER_DIR="$IRNET_HELPER_TEST_ROOT/helper"
  STATE="$IRNET_HELPER_TEST_ROOT/state"
  NETWORKSETUP="$HELPER_DIR/networksetup"
  TEST=1
fi
DNS_SERVERS="1.1.1.1 8.8.8.8"
TAB="$(printf '\t')"

die() { echo "$*" >&2; exit 2; }

flush_dns() {
  [ "$TEST" = 1 ] && return 0
  dscacheutil -flushcache 2>/dev/null
  killall -HUP mDNSResponder 2>/dev/null
  return 0
}

restore_dns() {
  [ -f "$STATE/dns.saved" ] || return 0
  while IFS="$TAB" read -r svc servers; do
    [ -n "$svc" ] || continue
    "$NETWORKSETUP" -setdnsservers "$svc" $servers
  done < "$STATE/dns.saved"
  rm -f "$STATE/dns.saved"
  flush_dns
}

stop_core() {
  [ -f "$STATE/supervisor.pid" ] || return 0
  if [ ! -f "$STATE/exited" ]; then
    : > "$STATE/stop"
    i=0
    while [ ! -f "$STATE/exited" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  if [ ! -f "$STATE/exited" ]; then
    # The supervisor is stuck: stop the core directly.
    xp="$(cat "$STATE/xray.pid" 2>/dev/null)"
    sp="$(cat "$STATE/supervisor.pid" 2>/dev/null)"
    [ -n "$xp" ] && kill -KILL "$xp" 2>/dev/null
    [ -n "$sp" ] && kill -KILL "$sp" 2>/dev/null
    restore_dns
    echo done > "$STATE/exited"
  fi
  rm -f "$STATE/supervisor.pid" "$STATE/config.json"
}

supervise() {
  PARENT="$1"
  XRAY_LOCATION_ASSET="$STATE/assets" "$HELPER_DIR/xray" run -c "$STATE/config.json" >> "$STATE/xray.log" 2>&1 < /dev/null &
  XPID=$!
  echo "$XPID" > "$STATE/xray.pid"
  while :; do
    sleep 1
    [ -f "$STATE/stop" ] && break
    kill -0 "$PARENT" 2>/dev/null || break
    kill -0 "$XPID" 2>/dev/null || break
  done
  kill -TERM "$XPID" 2>/dev/null
  i=0
  while kill -0 "$XPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$XPID" 2>/dev/null
  restore_dns
  rm -f "$STATE/config.json"
  echo done > "$STATE/exited"
}

start() {
  [ $# -ge 2 ] || die "usage: start <pid> <asset-dir> [service...]"
  PARENT="$1"; ASSETS="$2"; shift 2
  case "$PARENT" in ''|*[!0-9]*) die "bad pid";; esac
  stop_core
  rm -rf "$STATE"
  mkdir -p "$STATE"
  chmod 755 "$STATE"
  umask 077
  head -c 1000000 > "$STATE/config.json"
  res="$(/usr/bin/osascript -l JavaScript "$HELPER_DIR/validate.js" "$STATE/config.json" 2>&1)"
  [ "$res" = ok ] || { rm -f "$STATE/config.json"; die "IRNet's helper refused the config: $res"; }
  mkdir -p "$STATE/assets"
  if [ -d "$ASSETS" ]; then
    find "$ASSETS" -maxdepth 1 -type f -name '*.dat' -exec cp {} "$STATE/assets/" \;
  fi
  umask 022
  chmod 755 "$STATE/assets"
  : > "$STATE/xray.log"
  chmod 644 "$STATE/xray.log"
  for svc in "$@"; do
    case "$svc" in ''|*"$TAB"*) continue;; esac
    cur="$("$NETWORKSETUP" -getdnsservers "$svc" | tr '\n' ' ')"
    case "$cur" in *" any "*|*"aren't"*) cur=Empty;; esac
    printf '%s\t%s\n' "$svc" "$cur" >> "$STATE/dns.saved"
    "$NETWORKSETUP" -setdnsservers "$svc" $DNS_SERVERS
  done
  [ -f "$STATE/dns.saved" ] && chmod 600 "$STATE/dns.saved"
  flush_dns
  nohup /bin/sh "$0" supervise "$PARENT" > /dev/null 2>&1 < /dev/null &
  echo $! > "$STATE/supervisor.pid"
  echo started
}

net() {
  case "${1:-}" in
    -setwebproxy|-setsecurewebproxy|-setsocksfirewallproxy|-setproxybypassdomains|\
    -setwebproxystate|-setsecurewebproxystate|-setsocksfirewallproxystate|\
    -setairportpower|-setnetworkserviceenabled|-setdnsservers) ;;
    *) die "not allowed: ${1:-}";;
  esac
  exec "$NETWORKSETUP" "$@"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  ping) echo ok ;;
  start) start "$@" ;;
  stop) stop_core; echo stopped ;;
  supervise) supervise "$@" ;;
  net) net "$@" ;;
  *) die "usage: irnet-helper ping|start|stop|net" ;;
esac
''';

  /// JavaScript for Automation, run by the helper as root: accepts only the
  /// kind of config IRNet generates and writes it back with a log section
  /// that writes no files.
  @visibleForTesting
  static const validatorScript = r'''
ObjC.import('Foundation');
// Xray's Go JSON decoder matches keys case-insensitively, so every key check
// here is too; top-level sections must be spelled exactly.
function check(c) {
  if (typeof c !== 'object' || c === null || Array.isArray(c)) return 'not a JSON object';
  var sections = ['log', 'inbounds', 'outbounds', 'routing', 'dns', 'policy', 'stats', 'observatory'];
  for (var k in c) if (sections.indexOf(k) < 0) return 'unexpected section "' + k + '"';
  var inbounds = c.inbounds || [];
  for (var i = 0; i < inbounds.length; i++) {
    var ib = inbounds[i];
    if (['tun', 'http', 'socks'].indexOf(ib.protocol) < 0) return 'inbound "' + ib.protocol + '"';
    if (ib.protocol !== 'tun' && ib.listen !== '127.0.0.1') return 'inbound not on 127.0.0.1';
  }
  var outbounds = c.outbounds || [];
  for (var j = 0; j < outbounds.length; j++) {
    var ob = outbounds[j];
    if (['vless', 'vmess', 'trojan', 'wireguard', 'freedom', 'blackhole', 'dns'].indexOf(ob.protocol) < 0) {
      return 'outbound "' + ob.protocol + '"';
    }
    var net = ob.streamSettings && ob.streamSettings.network;
    if (net && ['raw', 'tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'splithttp', 'kcp', 'mkcp'].indexOf(net) < 0) {
      return 'transport "' + net + '"';
    }
  }
  // Files a root process must not write or serve, and Unix sockets it must
  // not open (e.g. Docker's) on someone's behalf.
  var forbidden = ['masterkeylog', 'certificatefile', 'keyfile', 'dir', 'masquerade', 'access', 'error'];
  var socketish = ['address', 'listen', 'redirect'];
  function walk(o) {
    if (Array.isArray(o)) {
      for (var i = 0; i < o.length; i++) { var r = walk(o[i]); if (r) return r; }
    } else if (o !== null && typeof o === 'object') {
      for (var k in o) {
        var key = k.toLowerCase();
        if (forbidden.indexOf(key) >= 0) return 'field "' + k + '"';
        var v = o[k];
        if (socketish.indexOf(key) >= 0 && typeof v === 'string' && /^[\/@]/.test(v)) return 'Unix socket in "' + k + '"';
        var r2 = walk(v); if (r2) return r2;
      }
    } else if (typeof o === 'string' && /^ext:[^:]*(\/|\\|\.\.)/i.test(o)) {
      return 'geo file path';
    }
    return '';
  }
  return walk(c);
}
function run(argv) {
  var path = argv[0];
  var text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) return 'unreadable';
  var c;
  try { c = JSON.parse(text.js); } catch (e) { return 'not JSON'; }
  var log = c && c.log;
  if (log && typeof log === 'object') delete c.log;
  var problem = check(c);
  if (problem) return problem;
  c.log = { loglevel: 'warning' };
  var out = $(JSON.stringify(c));
  if (!out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) return 'write failed';
  return 'ok';
}
''';
}
