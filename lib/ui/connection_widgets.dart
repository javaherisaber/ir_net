import 'package:flutter/material.dart';
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

/// The "VPN ON" badge shown on connection hero cards.
class VpnPill extends StatelessWidget {
  const VpnPill(this.state, {super.key});
  final VpnState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case VpnState.protected:
        return const Pill(
          label: 'VPN ON',
          dotColor: AppColors.good,
          textColor: AppColors.accent,
          background: Color(0x1433D6C6),
          borderColor: Color(0x5933D6C6),
        );
      case VpnState.exposed:
        return const Pill(
          label: 'NO VPN',
          dotColor: AppColors.bad,
          textColor: AppColors.bad,
          background: AppColors.badSoft,
          borderColor: AppColors.badBorder,
        );
      case VpnState.checking:
        return const Pill(
          label: 'CHECKING',
          dotColor: AppColors.warn,
          textColor: AppColors.text2,
          background: AppColors.card,
          borderColor: AppColors.line,
        );
    }
  }
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
              const Icon(Icons.public, size: 15, color: AppColors.accent),
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
        final state = vpnStateOf(info);
        return compact ? _compact(info, state) : _wide(info, state);
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

  Widget _wide(ConnectionInfo info, VpnState state) {
    final detail =
        [info.city, info.region, info.isp].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    return AppCard(
      gradient: AppGradients.card,
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          const IconTile(icon: Icons.public, size: 56, iconSize: 28, radius: 16),
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
          VpnPill(state),
        ],
      ),
    );
  }

  Widget _compact(ConnectionInfo info, VpnState state) {
    return AppCard(
      gradient: AppGradients.card,
      radius: 18,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const IconTile(icon: Icons.public, size: 42, iconSize: 22),
              VpnPill(state),
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Overline('ISP'),
                  const SizedBox(height: 2),
                  Text(info.isp ?? '—', style: AppText.mono(13, FontWeight.w500, AppColors.text)),
                ],
              ),
              if (onDetails != null)
                GestureDetector(
                  onTap: onDetails,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Text('Details', style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
                      const Icon(Icons.chevron_right, size: 16, color: AppColors.text3),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Country / Region / City / ISP table.
class LocationTableCard extends StatelessWidget {
  const LocationTableCard({super.key, this.withHeader = false});
  final bool withHeader;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final info = ConnectionInfo.fromJson(snapshot.data);
        final rows = <(String, String?)>[
          ('Country', info.country),
          ('Region', info.region),
          ('City', info.city),
          ('ISP', info.isp),
        ];
        return AppCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            children: [
              if (withHeader)
                _row(
                  const Padding(
                    padding: EdgeInsets.only(right: 9),
                    child: Icon(Icons.location_on_outlined, size: 15, color: AppColors.accent),
                  ),
                  'Location',
                  null,
                  isHeader: true,
                  last: false,
                ),
              for (var i = 0; i < rows.length; i++)
                _row(null, rows[i].$1, rows[i].$2, last: i == rows.length - 1),
            ],
          ),
        );
      },
    );
  }

  Widget _row(Widget? leading, String label, String? value,
      {bool isHeader = false, bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        border: last ? null : const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: isHeader
          ? Row(
              children: [
                if (leading != null) leading,
                Text(
                  label.toUpperCase(),
                  style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6),
                ),
              ],
            )
          : Row(
              children: [
                if (leading != null) leading,
                // Fixed-width label column so every value starts at the same x.
                SizedBox(
                  width: 92,
                  child: Text(
                    label.toUpperCase(),
                    style: AppText.ui(11, FontWeight.w500, AppColors.text3, letterSpacing: 0.6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    value ?? '—',
                    style: AppText.mono(13, FontWeight.w500,
                        value == null ? AppColors.text3 : AppColors.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Public IP + DNS + local interfaces. DNS / local IPs come from
/// `bloc.localNetwork`, which is only populated on Windows.
class IpDnsCard extends StatelessWidget {
  const IpDnsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.ipLookupResult,
      builder: (context, ipSnap) {
        final info = ConnectionInfo.fromJson(ipSnap.data);
        return StreamBuilder<LocalNetworksResult>(
          stream: bloc.localNetwork,
          builder: (context, netSnap) {
            final net = netSnap.data;
            return AppCard(
              padding: EdgeInsets.zero,
              clip: true,
              child: Column(
                children: [
                  _header(),
                  _kv('Public IP', info.ip ?? '—'),
                  if (net != null) ...[
                    _kv('DNS records', net.dns.where((e) => e.isNotEmpty).join(', ')),
                    _localIps(net.interfaces),
                  ] else
                    _note('DNS records & local interfaces are available on Windows.'),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.dns_outlined, size: 15, color: AppColors.accent),
          const SizedBox(width: 9),
          Text('IP & DNS',
              style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppColors.line2),
            ),
            child: Text('WINDOWS',
                style: AppText.ui(8, FontWeight.w600, AppColors.text3, letterSpacing: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value, {bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        border: last ? null : const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Text(label, style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
          const Spacer(),
          Flexible(
            child: Text(value,
                style: AppText.mono(13, FontWeight.w500, AppColors.text),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _localIps(List<NetworkInterface> interfaces) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Local IP addresses', style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
          const SizedBox(height: 9),
          if (interfaces.isEmpty)
            Text('—', style: AppText.mono(12, FontWeight.w500, AppColors.text))
          else
            for (final inf in interfaces)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  children: [
                    Text(inf.ipv4, style: AppText.mono(12, FontWeight.w500, AppColors.text)),
                    const Spacer(),
                    Flexible(
                      child: Text(inf.interfaceName,
                          style: AppText.ui(11, FontWeight.w400, AppColors.text3),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _note(String text) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
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
