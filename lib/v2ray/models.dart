/// Data types for the V2Ray (Xray) VPN: configs, subscriptions, delay
/// results and the connection state the UI renders.
library;

import 'geo_assets.dart';

export 'geo_assets.dart' show GeoAsset, GeoKind;

enum V2rayProtocol {
  vless('VLESS'),
  vmess('VMESS'),
  trojan('TROJAN'),
  wireguard('WIREGUARD');

  const V2rayProtocol(this.label);
  final String label;
}

/// Transport and security of a config ("streamSettings" in Xray terms).
class StreamOptions {
  const StreamOptions({
    this.network = 'raw',
    this.security = 'none',
    this.headerType = '',
    this.host = '',
    this.path = '',
    this.serviceName = '',
    this.authority = '',
    this.mode = '',
    this.extra = '',
    this.sni = '',
    this.alpn = const [],
    this.fingerprint = '',
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.mldsa65Verify = '',
    this.pinnedPeerCertSha256 = '',
    this.verifyPeerCertByName = '',
    this.echConfigList = '',
    this.insecure = false,
  });

  /// raw, ws, grpc, httpupgrade, xhttp, kcp (normalised; see [ShareLinkParser]).
  final String network;

  /// none, tls or reality.
  final String security;

  /// RAW "http" header obfuscation, or empty.
  final String headerType;
  final String host;
  final String path;
  final String serviceName;
  final String authority;

  /// gRPC "multi"/"gun", or the XHTTP mode (auto, packet-up, stream-up, stream-one).
  final String mode;

  /// XHTTP "extra" JSON, as given in the link.
  final String extra;

  final String sni;
  final List<String> alpn;
  final String fingerprint;
  final String publicKey;
  final String shortId;
  final String spiderX;
  final String mldsa65Verify;
  final String pinnedPeerCertSha256;
  final String verifyPeerCertByName;
  final String echConfigList;

  /// The link asked to skip certificate checks (allowInsecure / insecure).
  /// Xray no longer supports that, so this only drives a warning.
  final bool insecure;

  /// Short human label, e.g. "ws · tls" or "xhttp · reality".
  String get label {
    if (network == 'wireguard') return 'udp';
    final parts = <String>[network == 'raw' ? 'tcp' : network];
    if (security != 'none') parts.add(security);
    return parts.join(' · ');
  }
}

/// The [Interface] and [Peer] settings of a WireGuard config (the private
/// key is the profile's credential, the endpoint its address and port).
class WireGuardOptions {
  const WireGuardOptions({
    required this.publicKey,
    this.preSharedKey = '',
    this.addresses = const [],
    this.mtu,
    this.reserved = const [],
    this.keepAlive = 0,
    this.allowedIPs = const [],
  });

  /// The peer's (server's) public key.
  final String publicKey;
  final String preSharedKey;

  /// This device's tunnel addresses (CIDR), from [Interface] Address.
  final List<String> addresses;
  final int? mtu;

  /// Three bytes some servers (Cloudflare WARP) expect in every packet.
  final List<int> reserved;

  /// PersistentKeepalive in seconds; 0 = off.
  final int keepAlive;

  /// Empty = everything.
  final List<String> allowedIPs;
}

/// One server config (a share link) the user can connect to.
class V2rayProfile {
  const V2rayProfile({
    required this.id,
    required this.link,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    required this.credential,
    this.encryption = '',
    this.flow = '',
    this.stream = const StreamOptions(),
    this.subscriptionId,
    this.problem,
    this.wireguard,
  });

  /// WireGuard settings, for [V2rayProtocol.wireguard] profiles.
  final WireGuardOptions? wireguard;

  /// Stable id: derived from the link and its subscription, so a refreshed
  /// subscription keeps selection and delay results of unchanged configs.
  final String id;

  /// The share link as imported.
  final String link;

  /// Remark from the link, or "host:port" when it has none.
  final String name;
  final V2rayProtocol protocol;
  final String address;
  final int port;

  /// VLESS/VMess user id (UUID) or Trojan password.
  final String credential;

  /// VLESS "encryption" or VMess cipher ("security").
  final String encryption;

  /// VLESS flow (xtls-rprx-vision).
  final String flow;
  final StreamOptions stream;

  /// Owning subscription, or null for a config added on its own.
  final String? subscriptionId;

  /// Why the bundled Xray core can't use this config, if it can't.
  final String? problem;

  bool get isUsable => problem == null;

  String get endpoint => address.contains(':') ? '[$address]:$port' : '$address:$port';

  V2rayProfile copyWith({String? name}) => V2rayProfile(
        id: id,
        link: link,
        name: name ?? this.name,
        protocol: protocol,
        address: address,
        port: port,
        credential: credential,
        encryption: encryption,
        flow: flow,
        stream: stream,
        subscriptionId: subscriptionId,
        problem: problem,
        wireguard: wireguard,
      );
}

/// Traffic and expiry a subscription server reports
/// (the `subscription-userinfo` header).
class SubscriptionUsage {
  const SubscriptionUsage({this.upload = 0, this.download = 0, this.total = 0, this.expire});

  final int upload;
  final int download;

  /// Data cap in bytes; 0 means unlimited.
  final int total;

  /// Expiry as Unix seconds; null (or 0 in the header) means it never expires.
  final int? expire;

  int get used => upload + download;
  bool get isUnlimited => total <= 0;
  int get remaining => isUnlimited ? 0 : (total - used).clamp(0, total);

  /// Share of the cap still left, 0..1 (1 when unlimited).
  double get remainingFraction => isUnlimited ? 1 : remaining / total;

  DateTime? get expiresAt =>
      expire == null ? null : DateTime.fromMillisecondsSinceEpoch(expire! * 1000);

  bool isExpired(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  Duration? timeLeft(DateTime now) {
    final at = expiresAt;
    if (at == null) return null;
    final left = at.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  Map<String, dynamic> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        if (expire != null) 'expire': expire,
      };

  factory SubscriptionUsage.fromJson(Map<String, dynamic> json) => SubscriptionUsage(
        upload: (json['upload'] as num?)?.toInt() ?? 0,
        download: (json['download'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        expire: (json['expire'] as num?)?.toInt(),
      );
}

class V2raySubscription {
  const V2raySubscription({
    required this.id,
    required this.url,
    required this.name,
    this.customName,
    this.usage,
    this.updateIntervalHours,
    this.lastUpdated,
    this.lastError,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
  });

  final String id;
  final String url;

  /// Title the server gave (profile-title), or the URL host.
  final String name;

  /// Name the user typed, which wins over [name].
  final String? customName;

  /// Null when the server sends no subscription-userinfo.
  final SubscriptionUsage? usage;

  /// From profile-update-interval (hours).
  final int? updateIntervalHours;

  /// Unix milliseconds of the last successful update.
  final int? lastUpdated;
  final String? lastError;
  final String? supportUrl;
  final String? webPageUrl;
  final String? announce;

  String get title => (customName?.trim().isNotEmpty ?? false) ? customName!.trim() : name;

  /// Auto-refresh period: the server's interval, else a day.
  Duration get refreshEvery => Duration(hours: (updateIntervalHours ?? 24).clamp(1, 24 * 7));

  bool isStale(DateTime now) =>
      lastUpdated == null ||
      now.difference(DateTime.fromMillisecondsSinceEpoch(lastUpdated!)) >= refreshEvery;

  V2raySubscription copyWith({
    String? name,
    String? customName,
    bool clearCustomName = false,
    SubscriptionUsage? usage,
    bool clearUsage = false,
    int? updateIntervalHours,
    int? lastUpdated,
    String? lastError,
    bool clearError = false,
    String? supportUrl,
    String? webPageUrl,
    String? announce,
  }) =>
      V2raySubscription(
        id: id,
        url: url,
        name: name ?? this.name,
        customName: clearCustomName ? null : (customName ?? this.customName),
        usage: clearUsage ? null : (usage ?? this.usage),
        updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
        lastUpdated: lastUpdated ?? this.lastUpdated,
        lastError: clearError ? null : (lastError ?? this.lastError),
        supportUrl: supportUrl ?? this.supportUrl,
        webPageUrl: webPageUrl ?? this.webPageUrl,
        announce: announce ?? this.announce,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        if (customName != null) 'customName': customName,
        if (usage != null) 'usage': usage!.toJson(),
        if (updateIntervalHours != null) 'updateIntervalHours': updateIntervalHours,
        if (lastUpdated != null) 'lastUpdated': lastUpdated,
        if (lastError != null) 'lastError': lastError,
        if (supportUrl != null) 'supportUrl': supportUrl,
        if (webPageUrl != null) 'webPageUrl': webPageUrl,
        if (announce != null) 'announce': announce,
      };

  factory V2raySubscription.fromJson(Map<String, dynamic> json) => V2raySubscription(
        id: json['id'] as String,
        url: json['url'] as String,
        name: json['name'] as String? ?? '',
        customName: json['customName'] as String?,
        usage: json['usage'] is Map
            ? SubscriptionUsage.fromJson((json['usage'] as Map).cast<String, dynamic>())
            : null,
        updateIntervalHours: (json['updateIntervalHours'] as num?)?.toInt(),
        lastUpdated: (json['lastUpdated'] as num?)?.toInt(),
        lastError: json['lastError'] as String?,
        supportUrl: json['supportUrl'] as String?,
        webPageUrl: json['webPageUrl'] as String?,
        announce: json['announce'] as String?,
      );
}

/// Result of one delay test.
class DelayResult {
  const DelayResult({this.ms, this.error, required this.at});

  /// Round trip of a request through the config, in milliseconds.
  final int? ms;

  /// Why the test failed ("Timeout", the core's error…), when it did.
  final String? error;

  /// Unix milliseconds.
  final int at;

  bool get ok => ms != null;

  Map<String, dynamic> toJson() => {
        if (ms != null) 'ms': ms,
        if (error != null) 'error': error,
        'at': at,
      };

  factory DelayResult.fromJson(Map<String, dynamic> json) => DelayResult(
        ms: (json['ms'] as num?)?.toInt(),
        error: json['error'] as String?,
        at: (json['at'] as num?)?.toInt() ?? 0,
      );
}

/// How the VPN carries traffic.
enum VpnMode {
  /// Everything on the device goes through the VPN: a TUN device on desktop
  /// (needs admin rights), Android's VpnService.
  tunnel('Tunnel'),

  /// A local HTTP/SOCKS proxy; the desktop OS proxy points at it, so apps
  /// that honour the system proxy use the VPN and others go direct.
  proxy('Proxy');

  const VpnMode(this.label);
  final String label;
}

/// TLS ClientHello fragmentation (Xray's "fragment" mask): splits the
/// handshake so filters can't read the server name in one packet.
class FragmentOptions {
  const FragmentOptions({this.packets = 'tlshello', this.length = '100-200', this.delay = '10-20'});

  final String packets;

  /// Bytes per piece, "min-max".
  final String length;

  /// Milliseconds between pieces, "min-max".
  final String delay;

  static const defaults = FragmentOptions();

  Map<String, dynamic> toJson() => {'packets': packets, 'length': length, 'delay': delay};

  factory FragmentOptions.fromJson(Map<String, dynamic> json) => FragmentOptions(
        packets: json['packets'] as String? ?? 'tlshello',
        length: json['length'] as String? ?? '100-200',
        delay: json['delay'] as String? ?? '10-20',
      );
}

/// User options that shape the generated Xray config.
class V2raySettings {
  const V2raySettings({
    this.bypassLan = true,
    this.rules = const [],
    this.mode,
    this.killSwitch = false,
    this.fragment = false,
    this.fragmentOptions = FragmentOptions.defaults,
    this.iranDirect = false,
    this.bypassApps = const [],
    this.connectOnLaunch = false,
    this.autoReconnect = true,
    this.notify = true,
  });

  /// Send LAN / local addresses directly instead of through the VPN.
  final bool bypassLan;

  /// Pass-through (direct) rules, one per line; see PassThroughRules.
  final List<String> rules;

  /// Null until the user picks one: then the platform's default applies.
  final VpnMode? mode;

  /// Turn the network off (Wi-Fi and Ethernet) whenever the VPN isn't connected.
  final bool killSwitch;

  /// Fragment the TLS handshake of TLS/REALITY configs.
  final bool fragment;
  final FragmentOptions fragmentOptions;

  /// Iranian sites and IPs go direct (curated Iran rule files).
  final bool iranDirect;

  /// Apps that skip the VPN: package names on Android, process names, paths
  /// or folders ("/Applications/Telegram.app/") on desktop.
  final List<String> bypassApps;

  /// Connect when IRNet starts (with launch at startup: at login).
  final bool connectOnLaunch;

  /// Reconnect after the VPN drops, and when a health check fails.
  final bool autoReconnect;

  /// System notifications for drops and subscription warnings.
  final bool notify;

  V2raySettings copyWith({
    bool? bypassLan,
    List<String>? rules,
    VpnMode? mode,
    bool? killSwitch,
    bool? fragment,
    FragmentOptions? fragmentOptions,
    bool? iranDirect,
    List<String>? bypassApps,
    bool? connectOnLaunch,
    bool? autoReconnect,
    bool? notify,
  }) =>
      V2raySettings(
        bypassLan: bypassLan ?? this.bypassLan,
        rules: rules ?? this.rules,
        mode: mode ?? this.mode,
        killSwitch: killSwitch ?? this.killSwitch,
        fragment: fragment ?? this.fragment,
        fragmentOptions: fragmentOptions ?? this.fragmentOptions,
        iranDirect: iranDirect ?? this.iranDirect,
        bypassApps: bypassApps ?? this.bypassApps,
        connectOnLaunch: connectOnLaunch ?? this.connectOnLaunch,
        autoReconnect: autoReconnect ?? this.autoReconnect,
        notify: notify ?? this.notify,
      );

  Map<String, dynamic> toJson() => {
        'bypassLan': bypassLan,
        'rules': rules,
        if (mode != null) 'mode': mode!.name,
        'killSwitch': killSwitch,
        'fragment': fragment,
        'fragmentOptions': fragmentOptions.toJson(),
        'iranDirect': iranDirect,
        'bypassApps': bypassApps,
        'connectOnLaunch': connectOnLaunch,
        'autoReconnect': autoReconnect,
        'notify': notify,
      };

  factory V2raySettings.fromJson(Map<String, dynamic> json) => V2raySettings(
        bypassLan: json['bypassLan'] as bool? ?? true,
        rules: (json['rules'] as List?)?.whereType<String>().toList() ?? const [],
        mode: VpnMode.values.where((m) => m.name == json['mode']).firstOrNull,
        killSwitch: json['killSwitch'] as bool? ?? false,
        fragment: json['fragment'] as bool? ?? false,
        fragmentOptions: json['fragmentOptions'] is Map
            ? FragmentOptions.fromJson((json['fragmentOptions'] as Map).cast<String, dynamic>())
            : FragmentOptions.defaults,
        iranDirect: json['iranDirect'] as bool? ?? false,
        bypassApps: (json['bypassApps'] as List?)?.whereType<String>().toList() ?? const [],
        connectOnLaunch: json['connectOnLaunch'] as bool? ?? false,
        autoReconnect: json['autoReconnect'] as bool? ?? true,
        notify: json['notify'] as bool? ?? true,
      );
}

/// "Auto" selection: the fastest working config of a group (a subscription
/// id, or V2rayBloc.manualGroup), chosen by Xray as it goes.
class AutoSelect {
  AutoSelect._();

  static const prefix = 'auto:';

  static String idFor(String groupId) => '$prefix$groupId';

  static bool isAuto(String? id) => id != null && id.startsWith(prefix);

  static String? groupOf(String? id) => isAuto(id) ? id!.substring(prefix.length) : null;

  /// At most this many configs go into one Auto connection.
  static const maxServers = 12;
}

enum ConnectionPhase { disconnected, connecting, connected, disconnecting, failed }

/// Live state of the VPN connection.
class V2rayConnection {
  const V2rayConnection({
    this.phase = ConnectionPhase.disconnected,
    this.profileId,
    this.profileName,
    this.since,
    this.error,
    this.httpProxy,
    this.udpProxy,
    this.systemProxy = false,
    this.note,
    this.uploadSpeed,
    this.downloadSpeed,
    this.uploaded,
    this.downloaded,
    this.mode,
    this.activeProfileId,
  });

  final ConnectionPhase phase;

  /// In Auto: the config Xray is using right now, when the platform reports it.
  final String? activeProfileId;

  /// Mode of this connection (connecting / connected).
  final VpnMode? mode;
  final String? profileId;

  /// Kept so the UI can still name the server if its config is removed.
  final String? profileName;
  final DateTime? since;
  final String? error;

  /// "host:port" (with credentials on Android) of the local HTTP proxy that
  /// IRNet's own requests use while connected.
  final String? httpProxy;

  /// SOCKS5 proxy for IRNet's UDP probes (see EngineSession.udpProxy).
  final String? udpProxy;

  /// Whether the OS-wide proxy points at the core (desktop).
  final bool systemProxy;

  /// Extra information for the user (e.g. the proxy could not be set).
  final String? note;

  /// Bytes per second / totals, where the platform reports them.
  final int? uploadSpeed;
  final int? downloadSpeed;
  final int? uploaded;
  final int? downloaded;

  bool get isConnected => phase == ConnectionPhase.connected;
  bool get isBusy => phase == ConnectionPhase.connecting || phase == ConnectionPhase.disconnecting;

  static const idle = V2rayConnection();

  V2rayConnection withActive(String? id) => V2rayConnection(
        phase: phase,
        profileId: profileId,
        profileName: profileName,
        since: since,
        error: error,
        httpProxy: httpProxy,
        udpProxy: udpProxy,
        systemProxy: systemProxy,
        note: note,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed,
        uploaded: uploaded,
        downloaded: downloaded,
        mode: mode,
        activeProfileId: id,
      );

  V2rayConnection withTraffic({int? uploadSpeed, int? downloadSpeed, int? uploaded, int? downloaded}) =>
      V2rayConnection(
        phase: phase,
        profileId: profileId,
        profileName: profileName,
        since: since,
        error: error,
        httpProxy: httpProxy,
        udpProxy: udpProxy,
        systemProxy: systemProxy,
        note: note,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed,
        uploaded: uploaded,
        downloaded: downloaded,
        mode: mode,
        activeProfileId: activeProfileId,
      );
}

/// Everything the VPN screens render, as one immutable snapshot.
class V2rayState {
  const V2rayState({
    this.loaded = false,
    this.profiles = const [],
    this.subscriptions = const [],
    this.selectedId,
    this.delays = const {},
    this.testing = const {},
    this.testingAll = false,
    this.updating = const {},
    this.settings = const V2raySettings(),
    this.assets = const [],
    this.connection = V2rayConnection.idle,
    this.unsupportedReason,
    this.defaultMode = VpnMode.proxy,
    this.networkCut = false,
    this.killSwitchError,
    this.iranRules = const IranRulesStatus(),
  });

  /// The curated Iran rule files behind "Iranian sites go direct".
  final IranRulesStatus iranRules;

  /// The mode used while [V2raySettings.mode] is unset.
  final VpnMode defaultMode;

  /// The kill switch has turned the network off.
  final bool networkCut;

  /// The last kill-switch action that failed, if any.
  final String? killSwitchError;

  VpnMode get mode => settings.mode ?? defaultMode;

  final bool loaded;

  /// Imported geoip/geosite .dat files.
  final List<GeoAsset> assets;
  final List<V2rayProfile> profiles;
  final List<V2raySubscription> subscriptions;
  final String? selectedId;
  final Map<String, DelayResult> delays;

  /// Profile ids with a delay test in flight.
  final Set<String> testing;
  final bool testingAll;

  /// Subscription ids being refreshed.
  final Set<String> updating;
  final V2raySettings settings;
  final V2rayConnection connection;

  /// Set when this platform can't connect (iOS, web); configs still import.
  final String? unsupportedReason;

  V2rayProfile? profileById(String? id) {
    if (id == null) return null;
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  V2rayProfile? get selected => profileById(selectedId);

  V2raySubscription? subscriptionById(String? id) {
    if (id == null) return null;
    for (final s in subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<V2rayProfile> profilesOf(String? subscriptionId) =>
      profiles.where((p) => p.subscriptionId == subscriptionId).toList();

  V2rayState copyWith({
    bool? loaded,
    List<V2rayProfile>? profiles,
    List<V2raySubscription>? subscriptions,
    String? selectedId,
    bool clearSelected = false,
    Map<String, DelayResult>? delays,
    Set<String>? testing,
    bool? testingAll,
    Set<String>? updating,
    V2raySettings? settings,
    List<GeoAsset>? assets,
    V2rayConnection? connection,
    String? unsupportedReason,
    VpnMode? defaultMode,
    bool? networkCut,
    String? killSwitchError,
    bool clearKillSwitchError = false,
    IranRulesStatus? iranRules,
  }) =>
      V2rayState(
        loaded: loaded ?? this.loaded,
        profiles: profiles ?? this.profiles,
        subscriptions: subscriptions ?? this.subscriptions,
        selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
        delays: delays ?? this.delays,
        testing: testing ?? this.testing,
        testingAll: testingAll ?? this.testingAll,
        updating: updating ?? this.updating,
        settings: settings ?? this.settings,
        assets: assets ?? this.assets,
        connection: connection ?? this.connection,
        unsupportedReason: unsupportedReason ?? this.unsupportedReason,
        defaultMode: defaultMode ?? this.defaultMode,
        networkCut: networkCut ?? this.networkCut,
        killSwitchError: clearKillSwitchError ? null : (killSwitchError ?? this.killSwitchError),
        iranRules: iranRules ?? this.iranRules,
      );
}

class IranRulesStatus {
  const IranRulesStatus({this.updatedAt, this.updating = false, this.error});

  /// Unix milliseconds of the last successful download.
  final int? updatedAt;
  final bool updating;
  final String? error;
}
