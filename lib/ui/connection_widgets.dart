import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/cmd.dart';

import 'components.dart';
import 'theme.dart';

/// Parsed view of `bloc.ipLookupResult` (ip-api.com json, fields=8923).
class ConnectionInfo {
  const ConnectionInfo({
    this.country,
    this.countryCode,
    this.region,
    this.city,
    this.isp,
    this.ip,
  });

  final String? country;
  final String? countryCode;
  final String? region;
  final String? city;
  final String? isp;
  final String? ip;

  factory ConnectionInfo.fromJson(dynamic json) {
    if (json is! Map) return const ConnectionInfo();
    String? s(dynamic v) => (v == null || '$v'.isEmpty) ? null : '$v';
    return ConnectionInfo(
      country: s(json['country']),
      countryCode: s(json['countryCode']),
      region: s(json['regionName']),
      city: s(json['city']),
      isp: s(json['isp']),
      ip: s(json['query']),
    );
  }

  bool get hasData => country != null;
  bool get isIran => country == 'Iran';

  /// "Enschede · Overijssel" – the parts that are present.
  String get place => [city, region].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
}

enum VpnState { checking, protected, exposed }

VpnState vpnStateOf(ConnectionInfo info) {
  if (!info.hasData) return VpnState.checking;
  return info.isIran ? VpnState.exposed : VpnState.protected;
}

/// Header chip ("The Netherlands · Enschede" + status dot) used on desktop.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final info = ConnectionInfo.fromJson(snapshot.data);
        final state = vpnStateOf(info);
        final label = info.hasData
            ? [info.country, info.city].whereType<String>().join(' · ')
            : 'Checking connection…';
        final dot = switch (state) {
          VpnState.protected => AppColors.good,
          VpnState.exposed => AppColors.bad,
          VpnState.checking => AppColors.warn,
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CountryFlagTile(
                countryCode: info.countryCode,
                size: 15,
                width: 20,
                iconSize: 15,
                radius: 3,
              ),
              const SizedBox(width: 9),
              Text(label, style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
              const SizedBox(width: 9),
              StatusDot(dot, size: 6),
            ],
          ),
        );
      },
    );
  }
}

/// Big "Connected from" banner. [compact] = mobile vertical layout.
class ConnectionHeroCard extends StatelessWidget {
  const ConnectionHeroCard({super.key, this.compact = false, this.onDetails});

  final bool compact;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final info = ConnectionInfo.fromJson(snapshot.data);
        return compact ? _compact(info) : _wide(info);
      },
    );
  }

  Widget _countryLine(ConnectionInfo info, double size) {
    return Row(
      children: [
        Flexible(
          child: Text(
            info.country ?? 'Detecting…',
            style: AppText.ui(size, FontWeight.w700, AppColors.text, height: 1),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (info.countryCode != null) ...[
          const SizedBox(width: 8),
          CodeBadge(info.countryCode!),
        ],
      ],
    );
  }

  Widget _wide(ConnectionInfo info) {
    final detail =
        [info.city, info.region, info.isp].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    return AppCard(
      gradient: AppGradients.card,
      padding: const EdgeInsets.all(22),
      onTap: onDetails,
      child: Row(
        children: [
          CountryFlagTile(
            countryCode: info.countryCode,
            size: 56,
            iconSize: 28,
            radius: 16,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Overline('Connected from'),
                const SizedBox(height: 6),
                _countryLine(info, 24),
                const SizedBox(height: 5),
                Text(
                  detail.isEmpty ? 'Resolving location…' : detail,
                  style: AppText.ui(13, FontWeight.w400, AppColors.text2),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _IpDnsSummary(ip: info.ip),
          if (onDetails != null) ...[
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right, size: 20, color: AppColors.text3),
          ],
        ],
      ),
    );
  }

  Widget _compact(ConnectionInfo info) {
    return AppCard(
      gradient: AppGradients.card,
      radius: 18,
      padding: const EdgeInsets.all(16),
      onTap: onDetails,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CountryFlagTile(countryCode: info.countryCode, size: 42, iconSize: 22),
              const SizedBox(width: 12),
              Flexible(child: _IpDnsSummary(ip: info.ip)),
            ],
          ),
          const SizedBox(height: 14),
          const Overline('Connected from'),
          const SizedBox(height: 6),
          _countryLine(info, 21),
          const SizedBox(height: 4),
          Text(
            info.place.isEmpty ? 'Resolving location…' : info.place,
            style: AppText.ui(13, FontWeight.w400, AppColors.text2),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: AppColors.line),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Long ISP names ("Iran Telecommunication Company PJS") end
              // in "…" before reaching "Details".
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Overline('ISP'),
                    const SizedBox(height: 2),
                    Text(info.isp ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(13, FontWeight.w500, AppColors.text)),
                  ],
                ),
              ),
              // The whole card opens the details; this just says so.
              if (onDetails != null)
                Row(
                  children: [
                    const SizedBox(width: 12),
                    Text('Details', style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
                    const Icon(Icons.chevron_right, size: 16, color: AppColors.text3),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Public IP and DNS servers, right-aligned, for the "Connected from" tile.
/// Every DNS server gets its own line; iOS has none to show.
class _IpDnsSummary extends StatelessWidget {
  const _IpDnsSummary({required this.ip});
  final String? ip;

  @override
  Widget build(BuildContext context) {
    final showDns = !kIsWeb && !Platform.isIOS;
    return StreamBuilder<LocalNetworksResult>(
      stream: bloc.localNetwork,
      builder: (context, snapshot) {
        final dns = snapshot.data?.dns.where((e) => e.isNotEmpty).toList() ?? const <String>[];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _row('Public IP', [ip ?? '—']),
            if (showDns) ...[
              const SizedBox(height: 8),
              _row('DNS', dns.isEmpty ? const ['—'] : dns),
            ],
          ],
        );
      },
    );
  }

  Widget _row(String label, List<String> values) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 3), child: Overline(label)),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final v in values)
                Text(v, style: AppText.mono(13, FontWeight.w500, AppColors.text), textAlign: TextAlign.right),
            ],
          ),
        ),
      ],
    );
  }
}

/// The Connection details screen: where you appear (with the public IP),
/// the location facts, DNS servers and this device's local addresses. IPs
/// and DNS servers copy on click. [compact] = phone layout (stacked).
class ConnectionDetails extends StatelessWidget {
  const ConnectionDetails({
    super.key,
    this.compact = false,
    @visibleForTesting this.testLookup,
    @visibleForTesting this.testNetwork,
  });

  final bool compact;

  /// Used instead of the bloc's streams (tests, screenshots).
  final Map<String, dynamic>? testLookup;
  final LocalNetworksResult? testNetwork;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: testLookup == null ? bloc.ipLookupResult : Stream.value(testLookup),
      initialData: testLookup,
      builder: (context, ipSnap) {
        final info = ConnectionInfo.fromJson(ipSnap.data);
        return StreamBuilder<LocalNetworksResult>(
          stream: testNetwork == null ? bloc.localNetwork : Stream.value(testNetwork!),
          initialData: testNetwork,
          builder: (context, netSnap) {
            final net = netSnap.data;
            final address = _AddressCard(info: info, compact: compact);
            final location = _LocationCard(info: info);
            final dns = _DnsCard(net: net);
            final local = _LocalNetworkCard(net: net);
            const gap = SizedBox(height: 14);
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [address, gap, location, gap, dns, gap, local],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                address,
                gap,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: location),
                    const SizedBox(width: 14),
                    Expanded(child: Column(children: [dns, gap, local])),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Copies [value] and says so.
Future<void> copyToClipboard(BuildContext context, String value) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Row(
      children: [
        const Icon(Icons.check_circle_outline, size: 16, color: AppColors.good),
        const SizedBox(width: 9),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Copied '),
              TextSpan(text: value, style: AppText.mono(12.5, FontWeight.w600, AppColors.text)),
            ]),
            style: AppText.ui(12.5, FontWeight.w500, AppColors.text),
          ),
        ),
      ],
    ),
    duration: const Duration(seconds: 2),
    backgroundColor: AppColors.card2,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
      side: const BorderSide(color: AppColors.line2),
    ),
  ));
}

/// A card's title row: icon, title and an optional one-line caption.
class _CardTitle extends StatelessWidget {
  const _CardTitle(this.icon, this.title, {this.caption});
  final IconData icon;
  final String title;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.ui(14, FontWeight.w600, AppColors.text)),
                if (caption != null) ...[
                  const SizedBox(height: 2),
                  Text(caption!, style: AppText.ui(11.5, FontWeight.w400, AppColors.text3, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of a details card. With [copy], the whole line copies that
/// value on click and shows a copy icon, brighter on hover.
class _DetailRow extends StatefulWidget {
  const _DetailRow({this.leading, required this.title, this.subtitle, this.value, this.copy, this.mono = false});
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final String? copy;
  final bool mono;

  @override
  State<_DetailRow> createState() => _DetailRowState();
}

class _DetailRowState extends State<_DetailRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final value = w.value;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      child: Row(
        children: [
          if (w.leading != null) ...[w.leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(w.title,
                    style: AppText.ui(value == null ? 13 : 12, value == null ? FontWeight.w500 : FontWeight.w400,
                        value == null ? AppColors.text : AppColors.text3)),
                if (w.subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(w.subtitle!, style: AppText.mono(10.5, FontWeight.w400, AppColors.text3)),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 12),
            // Right-aligned, so values (and copy icons) line up at the edge.
            Expanded(
              flex: 2,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: w.mono
                    ? AppText.mono(13, FontWeight.w500, AppColors.text)
                    : AppText.ui(13, FontWeight.w500, AppColors.text),
              ),
            ),
          ],
          if (w.copy != null) ...[
            const SizedBox(width: 10),
            Icon(Icons.copy_rounded, size: 14, color: _hover ? AppColors.accent : AppColors.text3),
          ],
        ],
      ),
    );
    if (w.copy == null) return row;
    return Tooltip(
      message: 'Copy ${w.copy}',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () => copyToClipboard(context, w.copy!),
        onHover: (h) => setState(() => _hover = h),
        hoverColor: AppColors.card2,
        child: row,
      ),
    );
  }
}

const _divider = Divider(height: 1, thickness: 1, indent: 18, endIndent: 18, color: AppColors.line);

/// Where you appear: flag, country, place and ISP, with the public IP.
class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.info, required this.compact});
  final ConnectionInfo info;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final place = [info.city, info.region].whereType<String>().where((e) => e.isNotEmpty).join(', ');
    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Overline('You appear in'),
        const SizedBox(height: 6),
        Row(
          children: [
            Flexible(
              child: Text(info.country ?? 'Detecting…',
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui(compact ? 21 : 24, FontWeight.w700, AppColors.text, height: 1)),
            ),
            if (info.countryCode != null) ...[const SizedBox(width: 8), CodeBadge(info.countryCode!)],
          ],
        ),
        const SizedBox(height: 6),
        Text(place.isEmpty ? 'Resolving location…' : place,
            style: AppText.ui(13, FontWeight.w400, AppColors.text2)),
        if (info.isp != null) ...[
          const SizedBox(height: 2),
          Text(info.isp!, style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
        ],
      ],
    );
    final ip = _PublicIp(ip: info.ip, compact: compact);
    return AppCard(
      gradient: AppGradients.card,
      radius: compact ? 18 : 16,
      padding: EdgeInsets.all(compact ? 16 : 22),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CountryFlagTile(countryCode: info.countryCode, size: 42, iconSize: 22),
                    const SizedBox(width: 14),
                    Expanded(child: who),
                  ],
                ),
                const SizedBox(height: 14),
                Container(height: 1, color: AppColors.line),
                const SizedBox(height: 12),
                ip,
              ],
            )
          : Row(
              children: [
                CountryFlagTile(countryCode: info.countryCode, size: 56, iconSize: 28, radius: 16),
                const SizedBox(width: 20),
                Expanded(child: who),
                const SizedBox(width: 20),
                ip,
              ],
            ),
    );
  }
}

/// The public IP, large, copied on click.
class _PublicIp extends StatefulWidget {
  const _PublicIp({required this.ip, required this.compact});
  final String? ip;
  final bool compact;

  @override
  State<_PublicIp> createState() => _PublicIpState();
}

class _PublicIpState extends State<_PublicIp> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ip = widget.ip;
    final value = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ip ?? '—', style: AppText.mono(widget.compact ? 18 : 20, FontWeight.w700, AppColors.text)),
        if (ip != null) ...[
          const SizedBox(width: 8),
          Icon(Icons.copy_rounded, size: 15, color: _hover ? AppColors.accent : AppColors.text3),
        ],
      ],
    );
    final tappable = ip == null
        ? value
        : Tooltip(
            message: 'Copy $ip',
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => copyToClipboard(context, ip),
              onHover: (h) => setState(() => _hover = h),
              hoverColor: AppColors.card2,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), child: value),
            ),
          );
    if (widget.compact) {
      return Row(
        children: [
          const Overline('Public IP'),
          const SizedBox(width: 10),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: tappable)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Padding(padding: EdgeInsets.only(right: 6), child: Overline('Public IP')),
        const SizedBox(height: 4),
        tappable,
      ],
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.info});
  final ConnectionInfo info;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _DetailRow(
        title: 'Country',
        value: info.country ?? '—',
        leading: CountryFlagTile(countryCode: info.countryCode, size: 16, width: 22, iconSize: 14, radius: 3),
      ),
      _DetailRow(title: 'Region', value: info.region ?? '—', leading: _rowIcon(Icons.map_outlined)),
      _DetailRow(title: 'City', value: info.city ?? '—', leading: _rowIcon(Icons.location_city_outlined)),
      _DetailRow(title: 'Network', value: info.isp ?? '—', leading: _rowIcon(Icons.business_outlined)),
    ];
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardTitle(Icons.location_on_outlined, 'Location',
              caption: 'Where sites see you, from your public IP'),
          for (var i = 0; i < rows.length; i++) ...[if (i > 0) _divider, rows[i]],
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

Widget _rowIcon(IconData icon) => SizedBox(width: 22, child: Icon(icon, size: 16, color: AppColors.text3));

/// "1", "2": a DNS server's place in the lookup order.
Widget _orderBadge(int n) => Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.line2),
      ),
      child: Text('$n', style: AppText.mono(11, FontWeight.w600, AppColors.text3)),
    );

class _DnsCard extends StatelessWidget {
  const _DnsCard({required this.net});
  final LocalNetworksResult? net;

  @override
  Widget build(BuildContext context) {
    final servers = net?.dns.where((e) => e.isNotEmpty).toList() ?? const <String>[];
    final String? empty;
    if (kIsWeb) {
      empty = 'Not available in the browser';
    } else if (Platform.isIOS) {
      empty = 'iOS doesn\'t share its DNS servers with apps';
    } else if (net == null) {
      empty = 'Reading…';
    } else if (servers.isEmpty) {
      empty = 'None found';
    } else {
      empty = null;
    }
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardTitle(Icons.dns_outlined, 'DNS servers', caption: 'Turn site names into addresses for this device'),
          if (empty != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 18, 14),
              child: Text(empty, style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
            )
          else
            for (var i = 0; i < servers.length; i++) ...[
              if (i > 0) _divider,
              _DetailRow(
                title: i == 0 ? 'Primary' : (i == 1 ? 'Secondary' : 'Server ${i + 1}'),
                value: servers[i],
                copy: servers[i].replaceAll(' (Private DNS)', ''),
                mono: true,
                leading: _orderBadge(i + 1),
              ),
            ],
          if (empty == null) const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _LocalNetworkCard extends StatelessWidget {
  const _LocalNetworkCard({required this.net});
  final LocalNetworksResult? net;

  @override
  Widget build(BuildContext context) {
    final interfaces = net?.interfaces ?? const <NetworkInterface>[];
    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardTitle(Icons.lan_outlined, 'Local network',
              caption: 'This device\'s address on each network, for sharing on the same network'),
          if (interfaces.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 18, 14),
              child: Text(kIsWeb ? 'Not available in the browser' : (net == null ? 'Reading…' : 'No network'),
                  style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
            )
          else ...[
            for (var i = 0; i < interfaces.length; i++) ...[
              if (i > 0) _divider,
              _interfaceRow(interfaces[i]),
            ],
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  /// "Wi-Fi (en0)" → "Wi-Fi" over "en0".
  static Widget _interfaceRow(NetworkInterface inf) {
    final m = RegExp(r'^(.*) \(([^)]+)\)$').firstMatch(inf.interfaceName);
    final name = m?.group(1) ?? inf.interfaceName;
    final device = m?.group(2);
    return _DetailRow(
      leading: IconTile(icon: _interfaceIcon(inf.interfaceName), size: 30, iconSize: 16, radius: 9),
      title: name,
      subtitle: device,
      value: inf.ipv4,
      copy: inf.ipv4,
      mono: true,
    );
  }

  static IconData _interfaceIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('vpn') || l.contains('tunnel') || l.contains('irnet')) return Icons.vpn_lock_outlined;
    if (l.contains('wi-fi') || l.contains('wifi') || l.contains('wlan') || l.contains('wireless')) return Icons.wifi;
    if (l.contains('mobile') || l.contains('cellular')) return Icons.signal_cellular_alt;
    if (l.contains('hotspot')) return Icons.wifi_tethering;
    if (l.contains('ethernet') || l.contains('lan') || l.contains('thunderbolt')) return Icons.settings_ethernet;
    return Icons.lan_outlined;
  }
}

/// Small info banner used on the mobile Connection screen.
class InfoNote extends StatelessWidget {
  const InfoNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: const Color(0x05FFFFFF),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 15, color: AppColors.text3),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: AppText.ui(11, FontWeight.w400, AppColors.text3, height: 1.45)),
          ),
        ],
      ),
    );
  }
}
