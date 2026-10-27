/// Human-friendly app names for processes seen by the usage collectors.
library;

final _appBundle = RegExp(r'/([^/]+)\.app(?:/|$)');

/// macOS daemons and common Linux binaries whose process name says little.
const _friendlyNames = {
  // macOS
  'com.apple.WebKit.Networking': 'Safari / WebKit',
  'nsurlsessiond': 'macOS background transfers',
  'apsd': 'Apple Push Notifications',
  'mDNSResponder': 'macOS DNS',
  'softwareupdated': 'Software Update',
  'cloudd': 'iCloud',
  'bird': 'iCloud Drive',
  'trustd': 'Certificate checks',
  'akd': 'Apple Account',
  'identityservicesd': 'iMessage & FaceTime',
  'imagent': 'iMessage',
  'parsecd': 'Siri Suggestions',
  'rapportd': 'Continuity',
  'sharingd': 'AirDrop & Sharing',
  'storedownloadd': 'App Store downloads',
  'appstoreagent': 'App Store',
  'syspolicyd': 'Gatekeeper',
  'nesessionmanager': 'Network Extensions',
  'mobileassetd': 'macOS assets',
  'timed': 'Time sync',
  'netbiosd': 'NetBIOS',
  // Linux
  'firefox': 'Firefox',
  'firefox-bin': 'Firefox',
  'chrome': 'Google Chrome',
  'chromium': 'Chromium',
  'chromium-browse': 'Chromium',
  'brave': 'Brave',
  'msedge': 'Microsoft Edge',
  'opera': 'Opera',
  'code': 'VS Code',
  'telegram-deskto': 'Telegram',
  'telegram-desktop': 'Telegram',
  'slack': 'Slack',
  'discord': 'Discord',
  'Discord': 'Discord',
  'spotify': 'Spotify',
  'thunderbird': 'Thunderbird',
  'systemd-resolve': 'DNS (systemd-resolved)',
  'packagekitd': 'PackageKit updates',
  'snapd': 'Snap updates',
};

/// Display name for an executable path: the outermost `.app` bundle on macOS
/// ("/Applications/Google Chrome.app/…/Google Chrome Helper" → "Google Chrome"),
/// otherwise a friendly name for the binary, otherwise its file name.
String appNameFromPath(String path) {
  final bundle = _appBundle.firstMatch(path);
  if (bundle != null) return bundle.group(1)!;
  final base = path.split('/').where((p) => p.isNotEmpty).lastOrNull ?? path;
  return friendlyProcessName(base);
}

String friendlyProcessName(String name) => _friendlyNames[name] ?? name;

/// Apps that carry other apps' traffic (VPN / proxy clients and their tunnel
/// extensions). When a tunnel interface is in use, their own traffic is the
/// encrypted copy of everything else, so counting it would double the total.
const _vpnExactNames = {
  'happ', 'happd', 'v2box', 'streisand', 'foxray', 'shadowrocket', 'nekoray',
  'nekobox', 'throne', 'karing', 'oneclick', 'mihomo', 'clashx', 'stash',
  'surge', 'loon', 'quantumult x', 'outline', 'psiphon', 'lantern', 'tor',
  'tailscale', 'tailscaled', 'warp-svc', 'cloudflare warp', 'mullvad vpn',
  'windscribe', 'surfshark', 'tunnelblick', 'anyconnect', 'vpnagentd',
  'openconnect', 'forticlient', 'globalprotect', 'pangps', 'ss-local',
  'sslocal', 'trojan', 'naive', 'tuic', 'hiddifycli',
};

final _vpnPattern = RegExp(
  r'vpn|tunnel|v2ray|xray|sing-?box|clash|wireguard|shadowsocks|hysteria|'
  r'tun2socks|hiddify|mihomo|nekoray|openvpn',
  caseSensitive: false,
);

bool looksLikeVpnApp(String name) {
  final n = name.trim().toLowerCase();
  return _vpnExactNames.contains(n) || _vpnPattern.hasMatch(n);
}
