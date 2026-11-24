import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/file_delivery.dart';
import 'package:ir_net/v2ray/app_list.dart';
import 'package:ir_net/v2ray/qr_image.dart';
import 'package:ir_net/v2ray/routing_rules.dart';
import 'package:ir_net/v2ray/share_link.dart';
import 'package:ir_net/v2ray_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zxing2/qrcode.dart';

import 'components.dart';
import 'format.dart';
import 'qr_scan_screen.dart';
import 'theme.dart';

part 'vpn_settings_cards.dart';
part 'vpn_share.dart';

// ───────────────────────────── helpers ─────────────────────────────

/// Delay colours: under 800 ms good, under 1.5 s fair, slower poor.
Color delayColor(int ms) => ms < 800 ? AppColors.good : (ms < 1500 ? AppColors.warn : AppColors.bad);

String _ago(int epochMs) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
  if (d.inSeconds < 45) return 'just now';
  return '${formatDuration(d)} ago';
}

String _timeLeftText(Duration left) {
  if (left.inDays >= 2) return '${left.inDays} days left';
  if (left.inHours >= 1) return '${left.inHours}h left';
  return '${left.inMinutes.clamp(1, 59)}m left';
}

String _date(DateTime t) => '${formatDay(t.millisecondsSinceEpoch / 1000)}, ${t.year}';

/// What the hero and the overview tile name: the connection's (or, when
/// off, the selected) config, or a group's Auto entry. For Auto, [profile]
/// is the config in use right now when the platform reports it.
({V2rayProfile? profile, String? name, String? groupId}) _target(V2rayState s) {
  final c = s.connection;
  final off = c.phase == ConnectionPhase.disconnected;
  final group = AutoSelect.groupOf(off ? s.selectedId : (c.profileId ?? s.selectedId));
  if (group != null) {
    return (
      profile: c.isConnected ? s.profileById(c.activeProfileId) : null,
      name: off ? bloc.v2ray.autoName(group) : (c.profileName ?? bloc.v2ray.autoName(group)),
      groupId: group,
    );
  }
  final profile = s.profileById(c.profileId) ?? s.selected;
  return (profile: profile, name: off ? profile?.name : (c.profileName ?? profile?.name), groupId: null);
}

Widget _sectionTitle(String title, {String? subtitle, Widget? trailing}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.ui(14, FontWeight.w600, AppColors.text)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle, style: AppText.ui(11.5, FontWeight.w400, AppColors.text3, height: 1.4)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing],
      ],
    );

void _toast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Text(message, style: AppText.ui(12.5, FontWeight.w500, AppColors.text)),
    backgroundColor: AppColors.card2,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
      side: const BorderSide(color: AppColors.line2),
    ),
  ));
}

bool get _canUseCamera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

// ───────────────────────────── import ─────────────────────────────

enum VpnImport { clipboard, camera, image, wireGuardFile, manual }

/// Runs one of the import flows and reports the outcome.
Future<void> runVpnImport(BuildContext context, VpnImport how) async {
  String? text;
  String? nameHint;
  switch (how) {
    case VpnImport.clipboard:
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text == null || text.trim().isEmpty) {
        if (context.mounted) _toast(context, 'The clipboard is empty');
        return;
      }
    case VpnImport.camera:
      text = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScanScreen(), fullscreenDialog: true),
      );
      if (text == null) return;
    case VpnImport.image:
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
          mimeTypes: ['image/*'],
          uniformTypeIdentifiers: ['public.image'],
        ),
      ]);
      if (file == null) return;
      text = await decodeQrImage(await file.readAsBytes());
      if (text == null) {
        if (context.mounted) _toast(context, 'No QR code found in that image');
        return;
      }
    case VpnImport.wireGuardFile:
      final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      final file = await openFile(
        acceptedTypeGroups: mobile
            ? const []
            : const [
                XTypeGroup(label: 'WireGuard config', extensions: ['conf'])
              ],
      );
      if (file == null) return;
      text = await file.readAsString();
      if (!ShareLinkParser.hasWireGuardConf(text)) {
        if (context.mounted) _toast(context, 'That file isn\'t a WireGuard config');
        return;
      }
      nameHint = file.name.replaceFirst(RegExp(r'\.conf$', caseSensitive: false), '');
    case VpnImport.manual:
      text = await showDialog<String>(context: context, builder: (_) => const _ManualImportDialog());
      if (text == null || text.trim().isEmpty) return;
  }
  if (!context.mounted) return;
  _toast(context, 'Importing…');
  final result = await bloc.v2ray.importText(text, nameHint: nameHint);
  if (context.mounted) _toast(context, result.message);
}

class _ManualImportDialog extends StatefulWidget {
  const _ManualImportDialog();

  @override
  State<_ManualImportDialog> createState() => _ManualImportDialogState();
}

class _ManualImportDialogState extends State<_ManualImportDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line2)),
      title: Text('Add config or subscription', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
      content: SizedBox(
        width: 460,
        child: _RulesField(
          controller: _controller,
          hint:
              'vless://…, vmess://…, trojan://…, wireguard://… (one per line),\na WireGuard config ([Interface] …) or a subscription URL: https://…',
          minLines: 4,
          autofocus: true,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        AppButton(label: 'Add', height: 36, onPressed: () => Navigator.pop(context, _controller.text)),
      ],
    );
  }
}

/// "Add" button with every import source in a menu.
class VpnAddButton extends StatelessWidget {
  const VpnAddButton({super.key, this.height = 38, this.label = 'Add'});
  final double height;
  final String label;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VpnImport>(
      tooltip: 'Add configs',
      color: AppColors.card2,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.line2)),
      onSelected: (how) => runVpnImport(context, how),
      itemBuilder: (_) => [
        _menuItem(VpnImport.clipboard, Icons.content_paste, 'Paste from clipboard'),
        if (_canUseCamera) _menuItem(VpnImport.camera, Icons.qr_code_scanner, 'Scan QR code'),
        _menuItem(VpnImport.image, Icons.image_outlined, 'QR code from image'),
        _menuItem(VpnImport.wireGuardFile, Icons.description_outlined, 'WireGuard .conf file'),
        _menuItem(VpnImport.manual, Icons.edit_outlined, 'Type or paste a link'),
      ],
      child: IgnorePointer(
        child: AppButton(label: label, icon: Icons.add, height: height, onPressed: () {}),
      ),
    );
  }

  PopupMenuItem<VpnImport> _menuItem(VpnImport value, IconData icon, String text) => PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 17, color: AppColors.text2),
            const SizedBox(width: 11),
            Text(text, style: AppText.ui(13, FontWeight.w500, AppColors.text)),
          ],
        ),
      );
}

// ───────────────────────────── section ─────────────────────────────

/// The VPN screen: status + connect, configs grouped by subscription, and
/// routing (LAN bypass, pass-through rules, geo files).
class VpnSection extends StatefulWidget {
  const VpnSection({super.key, this.compact = false});
  final bool compact;

  @override
  State<VpnSection> createState() => _VpnSectionState();
}

class _VpnSectionState extends State<VpnSection> {
  int _tab = 0;

  /// Focused group (subscription id or [V2rayBloc.manualGroup]); null = all.
  String? _group;
  bool _sortByDelay = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<V2rayState>(
      stream: bloc.v2ray.state,
      initialData: bloc.v2ray.value,
      builder: (context, snapshot) {
        final s = snapshot.data!;
        final groups = _groupIds(s);
        if (_group != null && !groups.contains(_group)) _group = null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VpnHeroCard(state: s, compact: widget.compact),
            const SizedBox(height: 14),
            _tabs(s),
            const SizedBox(height: 14),
            if (_tab == 0) ..._configs(s, groups) else VpnRoutingView(state: s, compact: widget.compact),
          ],
        );
      },
    );
  }

  List<String> _groupIds(V2rayState s) => [
        for (final sub in s.subscriptions) sub.id,
        if (s.profiles.any((p) => p.subscriptionId == null)) V2rayBloc.manualGroup,
      ];

  Widget _tabs(V2rayState s) {
    final issues = bloc.v2ray.compiledRules.issues.length;
    Widget tab(int i, String label, {String? badge}) {
      final active = _tab == i;
      return Expanded(
        child: Material(
          color: active ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _tab = i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: AppText.ui(12.5, active ? FontWeight.w600 : FontWeight.w500,
                          active ? AppColors.accent : AppColors.text2)),
                  if (badge != null) ...[
                    const SizedBox(width: 6),
                    Text(badge, style: AppText.mono(11, FontWeight.w500, AppColors.text3)),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          tab(0, 'Configs', badge: '${s.profiles.length}'),
          const SizedBox(width: 4),
          tab(1, 'Settings', badge: issues > 0 ? '$issues ⚠' : null),
        ],
      ),
    );
  }

  List<Widget> _configs(V2rayState s, List<String> groups) {
    if (s.profiles.isEmpty && s.subscriptions.isEmpty) {
      return [_EmptyConfigs(compact: widget.compact)];
    }
    final visible = _group == null ? groups : [_group!];
    final height = widget.compact ? 34.0 : 38.0;
    return [
      Row(
        children: [
          VpnAddButton(height: height),
          const SizedBox(width: 8),
          AppButton(
            label: s.testingAll ? 'Stop' : (_group == null ? 'Test all' : 'Test group'),
            icon: s.testingAll ? Icons.stop_circle_outlined : Icons.speed,
            kind: AppButtonKind.outline,
            height: height,
            onPressed: s.testingAll ? bloc.v2ray.cancelTests : () => bloc.v2ray.testAll(groupId: _group),
          ),
          if (s.subscriptions.isNotEmpty) ...[
            const SizedBox(width: 8),
            if (widget.compact)
              Tooltip(
                message: 'Update subscriptions',
                child: IconActionButton(
                  icon: Icons.refresh,
                  size: height,
                  onPressed: s.updating.isEmpty ? bloc.v2ray.updateAllSubscriptions : null,
                ),
              )
            else
              AppButton(
                label: 'Update',
                icon: Icons.refresh,
                kind: AppButtonKind.outline,
                height: height,
                onPressed: s.updating.isEmpty ? bloc.v2ray.updateAllSubscriptions : null,
              ),
          ],
          const Spacer(),
          _SortToggle(
            active: _sortByDelay,
            size: height,
            onChanged: (v) => setState(() => _sortByDelay = v),
          ),
        ],
      ),
      if (groups.length > 1) ...[
        const SizedBox(height: 12),
        _groupChips(s, groups),
      ],
      const SizedBox(height: 12),
      for (final id in visible) ...[
        _GroupCard(
          key: ValueKey('group-$id'),
          groupId: id,
          state: s,
          compact: widget.compact,
          sortByDelay: _sortByDelay,
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _groupChips(V2rayState s, List<String> groups) {
    Widget chip(String? id, String label, int count) {
      final active = _group == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: active ? AppColors.accentSoft : AppColors.card,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => setState(() => _group = id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: active ? const Color(0x4D33D6C6) : AppColors.line),
              ),
              child: Text('$label · $count',
                  style: AppText.ui(12, FontWeight.w600, active ? AppColors.accent : AppColors.text2)),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip(null, 'All', s.profiles.length),
          for (final id in groups)
            chip(
              id,
              id == V2rayBloc.manualGroup ? 'My configs' : s.subscriptionById(id)!.title,
              s.profilesOf(id == V2rayBloc.manualGroup ? null : id).length,
            ),
        ],
      ),
    );
  }
}

/// "Fastest first" on/off.
class _SortToggle extends StatelessWidget {
  const _SortToggle({required this.active, required this.size, required this.onChanged});
  final bool active;
  final double size;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active ? 'Showing fastest first' : 'Sort fastest first',
      child: Material(
        color: active ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onChanged(!active),
          child: Container(
            height: size,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: active ? const Color(0x4D33D6C6) : AppColors.line2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt, size: 15, color: active ? AppColors.accent : AppColors.text2),
                const SizedBox(width: 3),
                Icon(Icons.arrow_downward, size: 12, color: active ? AppColors.accent : AppColors.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyConfigs extends StatelessWidget {
  const _EmptyConfigs({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.all(compact ? 20 : 28),
      child: Column(
        children: [
          const IconTile(icon: Icons.vpn_key_outlined, size: 52, iconSize: 26),
          const SizedBox(height: 14),
          Text('No configs yet', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
          const SizedBox(height: 6),
          Text(
            'Add a VLESS, VMess, Trojan or WireGuard config or a subscription URL from the clipboard, '
            'or scan its QR code.',
            textAlign: TextAlign.center,
            style: AppText.ui(12, FontWeight.w400, AppColors.text3, height: 1.45),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              AppButton(
                label: 'Paste from clipboard',
                icon: Icons.content_paste,
                height: 40,
                onPressed: () => runVpnImport(context, VpnImport.clipboard),
              ),
              AppButton(
                label: _canUseCamera ? 'Scan QR code' : 'QR from image',
                icon: Icons.qr_code_scanner,
                kind: AppButtonKind.outline,
                height: 40,
                onPressed: () => runVpnImport(context, _canUseCamera ? VpnImport.camera : VpnImport.image),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── hero ─────────────────────────────

class VpnHeroCard extends StatelessWidget {
  const VpnHeroCard({super.key, required this.state, this.compact = false});
  final V2rayState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = state.connection;
    final target = _target(state);
    final profile = target.profile;
    final auto = target.groupId != null;
    final (word, color) = switch (c.phase) {
      ConnectionPhase.connected => ('Connected', AppColors.good),
      ConnectionPhase.connecting => ('Connecting…', AppColors.warn),
      ConnectionPhase.disconnecting => ('Disconnecting…', AppColors.warn),
      ConnectionPhase.failed => ('Couldn\'t connect', AppColors.bad),
      ConnectionPhase.disconnected => ('Not connected', AppColors.text2),
    };
    final name = target.name;
    final delay = profile == null ? null : state.delays[profile.id];
    final mode = c.mode ?? state.mode;

    return AppCard(
      gradient: AppGradients.card,
      radius: compact ? 18 : 16,
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _PowerButton(
                phase: c.phase,
                size: compact ? 58 : 68,
                onPressed: state.unsupportedReason != null || (state.profiles.isEmpty && !c.isConnected)
                    ? null
                    : bloc.v2ray.toggle,
              ),
              SizedBox(width: compact ? 14 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Overline('V2Ray VPN'),
                        const SizedBox(width: 8),
                        Text('· ${mode.label.toUpperCase()} MODE', style: AppText.overline(AppColors.text3)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        StatusDot(color, size: 8),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(word,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(compact ? 18 : 21, FontWeight.w700, AppColors.text)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (name != null) ...[
                      Row(
                        children: [
                          if (auto) ...[
                            const CodeBadge('AUTO'),
                            const SizedBox(width: 7)
                          ] else if (profile != null) ...[
                            CodeBadge(profile.protocol.label),
                            const SizedBox(width: 7)
                          ],
                          Flexible(
                            child: Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                          ),
                        ],
                      ),
                      if (auto && profile != null) ...[
                        const SizedBox(height: 3),
                        Text('Using ${profile.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.ui(11.5, FontWeight.w400, AppColors.text3)),
                      ],
                    ] else
                      Text(state.profiles.isEmpty ? 'Add a config to get started' : 'Pick a config below',
                          style: AppText.ui(12.5, FontWeight.w400, AppColors.text3)),
                  ],
                ),
              ),
              if (profile != null && !compact) ...[
                const SizedBox(width: 12),
                DelayChip(profileId: profile.id, result: delay, testing: state.testing.contains(profile.id)),
              ],
            ],
          ),
          if (c.isConnected) ...[
            const SizedBox(height: 14),
            _ConnectedDetails(connection: c, compact: compact),
          ],
          if (c.note != null) ...[
            const SizedBox(height: 12),
            _Note(c.note!, color: AppColors.warn),
          ],
          if (c.phase == ConnectionPhase.failed && c.error != null) ...[
            const SizedBox(height: 12),
            _Note(c.error!, color: AppColors.bad),
          ],
          if (state.networkCut && !c.isConnected) ...[
            const SizedBox(height: 12),
            const _Note('Kill switch: Wi-Fi and Ethernet are off until the VPN connects.', color: AppColors.bad),
          ],
          if (state.killSwitchError != null) ...[
            const SizedBox(height: 12),
            _Note(state.killSwitchError!, color: AppColors.warn),
          ],
          if (state.unsupportedReason != null) ...[
            const SizedBox(height: 12),
            _Note(state.unsupportedReason!, color: AppColors.text3),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(text, style: AppText.ui(11.5, FontWeight.w400, color, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

class _ConnectedDetails extends StatelessWidget {
  const _ConnectedDetails({required this.connection, required this.compact});
  final V2rayConnection connection;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
      builder: (context, _) {
        final c = connection;
        final since = c.since == null ? null : DateTime.now().difference(c.since!);
        final items = <(IconData, String)>[
          if (since != null) (Icons.timer_outlined, formatDuration(since)),
          if (c.downloadSpeed != null) (Icons.south, '${formatBytes(c.downloadSpeed!)}/s'),
          if (c.uploadSpeed != null) (Icons.north, '${formatBytes(c.uploadSpeed!)}/s'),
          if (c.downloaded != null && c.uploaded != null) (Icons.data_usage, formatBytes(c.downloaded! + c.uploaded!)),
          if (c.mode == VpnMode.tunnel) (Icons.alt_route, 'All traffic tunnelled'),
          if (!kIsWeb && !Platform.isAndroid && c.systemProxy) (Icons.settings_ethernet, 'System proxy on'),
          if (!kIsWeb && !Platform.isAndroid && c.httpProxy != null && !compact)
            (Icons.lan_outlined, 'HTTP ${c.httpProxy}'),
        ];
        return Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final (icon, text) in items)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: AppColors.text3),
                  const SizedBox(width: 5),
                  Text(text, style: AppText.mono(11.5, FontWeight.w500, AppColors.text2)),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.phase, required this.size, required this.onPressed});
  final ConnectionPhase phase;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final connected = phase == ConnectionPhase.connected;
    final busy = phase == ConnectionPhase.connecting || phase == ConnectionPhase.disconnecting;
    final failed = phase == ConnectionPhase.failed;
    return Tooltip(
      message: connected || phase == ConnectionPhase.connecting ? 'Disconnect' : 'Connect',
      // The glow is painted here, outside the Material: ink decorations are
      // clipped to the Material's square bounds, which cut the glow square.
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: connected
              ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.35), blurRadius: 22, spreadRadius: 1)]
              : null,
        ),
        child: Material(
          shape: const CircleBorder(),
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Ink(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: connected ? AppGradients.brand : null,
                color: connected ? null : (failed ? AppColors.badSoft : AppColors.card2),
                border: Border.all(
                  color: connected
                      ? Colors.transparent
                      : failed
                          ? AppColors.badBorder
                          : busy
                              ? AppColors.warn.withValues(alpha: 0.5)
                              : AppColors.line2,
                  width: 1.5,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: size - 8,
                      height: size - 8,
                      child: const CircularProgressIndicator(strokeWidth: 2, color: AppColors.warn),
                    ),
                  Icon(
                    Icons.power_settings_new,
                    size: size * 0.42,
                    color: connected
                        ? AppColors.onAccent
                        : failed
                            ? AppColors.bad
                            : onPressed == null
                                ? AppColors.text3
                                : AppColors.text,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A config's last delay; tap to test again.
class DelayChip extends StatelessWidget {
  const DelayChip({super.key, required this.profileId, this.result, this.testing = false});
  final String profileId;
  final DelayResult? result;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final Widget label;
    Color border = AppColors.line2;
    if (testing) {
      label = const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.text2),
      );
    } else if (r == null) {
      label = Text('Test', style: AppText.ui(11.5, FontWeight.w600, AppColors.text3));
    } else if (r.ok) {
      final color = delayColor(r.ms!);
      border = color.withValues(alpha: 0.35);
      label = Text('${r.ms} ms', style: AppText.mono(11.5, FontWeight.w600, color));
    } else {
      border = AppColors.badBorder;
      label =
          Text(r.error == 'Timeout' ? 'Timeout' : 'Failed', style: AppText.ui(11.5, FontWeight.w600, AppColors.bad));
    }
    return Tooltip(
      message: r?.error != null && r!.error != 'Timeout' ? r.error! : 'Test delay',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: testing ? null : () => bloc.v2ray.testProfile(profileId),
          child: Container(
            constraints: const BoxConstraints(minWidth: 64),
            height: 28,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
            ),
            child: label,
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── groups ─────────────────────────────

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    super.key,
    required this.groupId,
    required this.state,
    required this.compact,
    required this.sortByDelay,
  });

  final String groupId;
  final V2rayState state;
  final bool compact;
  final bool sortByDelay;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _collapsed = false;

  bool get _isManual => widget.groupId == V2rayBloc.manualGroup;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final sub = _isManual ? null : s.subscriptionById(widget.groupId);
    var profiles = s.profilesOf(sub?.id);
    if (widget.sortByDelay) {
      int rank(V2rayProfile p) {
        final r = s.delays[p.id];
        if (!p.isUsable) return 1 << 30;
        if (r == null) return 1 << 28;
        return r.ms ?? (1 << 29);
      }

      profiles = [...profiles]..sort((a, b) => rank(a).compareTo(rank(b)));
    }
    final updating = sub != null && s.updating.contains(sub.id);
    final testingHere = profiles.any((p) => s.testing.contains(p.id));
    final ok = profiles.where((p) => s.delays[p.id]?.ok == true).length;

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Padding(
              padding: EdgeInsets.fromLTRB(widget.compact ? 14 : 16, 14, 8, 12),
              child: Row(
                children: [
                  IconTile(
                    icon: _isManual ? Icons.bookmark_border : Icons.cloud_sync_outlined,
                    size: 36,
                    iconSize: 18,
                    radius: 10,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sub?.title ?? 'My configs',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.ui(14, FontWeight.w600, AppColors.text)),
                        const SizedBox(height: 2),
                        Text(
                          [
                            '${profiles.length} config${profiles.length == 1 ? '' : 's'}',
                            if (ok > 0) '$ok working',
                            if (sub?.lastUpdated != null) 'updated ${_ago(sub!.lastUpdated!)}',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.ui(11, FontWeight.w400, AppColors.text3),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.compact || sub == null)
                    _iconButton(
                      Icons.speed,
                      'Test this group',
                      testingHere ? null : () => bloc.v2ray.testProfiles(profiles),
                    ),
                  if (sub != null)
                    updating
                        ? const Padding(
                            padding: EdgeInsets.all(11),
                            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.8)),
                          )
                        : _iconButton(
                            Icons.refresh, 'Update subscription', () => bloc.v2ray.updateSubscription(sub.id)),
                  if (sub != null) _subscriptionMenu(sub, profiles, testingHere),
                  if (!widget.compact) ...[
                    Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 18, color: AppColors.text3),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          if (sub != null && (sub.usage != null || sub.lastError != null || sub.announce != null))
            Padding(
              padding: EdgeInsets.fromLTRB(widget.compact ? 14 : 16, 0, widget.compact ? 14 : 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sub.usage != null) SubscriptionUsageView(usage: sub.usage!, compact: widget.compact),
                  if (sub.announce != null && sub.announce!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _Note(sub.announce!, color: AppColors.accent),
                  ],
                  if (sub.lastError != null) ...[
                    const SizedBox(height: 10),
                    _Note('Last update failed: ${sub.lastError}', color: AppColors.warn),
                  ],
                ],
              ),
            ),
          if (!_collapsed) ...[
            const Divider(height: 1, thickness: 1, color: AppColors.line),
            if (s.unsupportedReason == null && profiles.where((p) => p.isUsable).length >= 2) ...[
              _AutoRow(groupId: widget.groupId, state: s, compact: widget.compact),
              const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: AppColors.line),
            ],
            for (var i = 0; i < profiles.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: AppColors.line),
              _ProfileRow(profile: profiles[i], state: s, compact: widget.compact),
            ],
            if (profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No configs in this subscription', style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 18, color: onPressed == null ? AppColors.text3 : AppColors.text2),
      );

  Widget _subscriptionMenu(V2raySubscription sub, List<V2rayProfile> profiles, bool testing) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      color: AppColors.card2,
      icon: const Icon(Icons.more_vert, size: 18, color: AppColors.text2),
      onSelected: (action) async {
        switch (action) {
          case 'test':
            await bloc.v2ray.testProfiles(profiles);
          case 'rename':
            final name = await _askText(context, 'Rename subscription', sub.title);
            if (name != null) await bloc.v2ray.renameSubscription(sub.id, name);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: sub.url));
            if (mounted) _toast(context, 'Subscription link copied');
          case 'support':
            await launchUrl(Uri.parse(sub.supportUrl!), mode: LaunchMode.externalApplication);
          case 'web':
            await launchUrl(Uri.parse(sub.webPageUrl!), mode: LaunchMode.externalApplication);
          case 'remove':
            final ok = await _confirm(context, 'Remove “${sub.title}”?',
                'Its ${widget.state.profilesOf(sub.id).length} configs are removed too.');
            if (ok) await bloc.v2ray.removeSubscription(sub.id);
        }
      },
      itemBuilder: (_) => [
        if (widget.compact && !testing) _item('test', Icons.speed, 'Test this group'),
        _item('rename', Icons.edit_outlined, 'Rename'),
        _item('copy', Icons.link, 'Copy subscription link'),
        if (sub.supportUrl != null) _item('support', Icons.support_agent, 'Contact support'),
        if (sub.webPageUrl != null) _item('web', Icons.open_in_new, 'Open provider page'),
        _item('remove', Icons.delete_outline, 'Remove', danger: true),
      ],
    );
  }
}

PopupMenuItem<String> _item(String value, IconData icon, String text, {bool danger = false}) => PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 17, color: danger ? AppColors.bad : AppColors.text2),
          const SizedBox(width: 11),
          Text(text, style: AppText.ui(13, FontWeight.w500, danger ? AppColors.bad : AppColors.text)),
        ],
      ),
    );

Future<String?> _askText(BuildContext context, String title, String initial) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(title, style: AppText.ui(16, FontWeight.w700, AppColors.text)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: AppText.ui(14, FontWeight.w500, AppColors.text),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        AppButton(label: 'Save', height: 36, onPressed: () => Navigator.pop(context, controller.text)),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(title, style: AppText.ui(16, FontWeight.w700, AppColors.text)),
      content: Text(body, style: AppText.ui(13, FontWeight.w400, AppColors.text2)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        AppButton(
            label: 'Remove', kind: AppButtonKind.danger, height: 36, onPressed: () => Navigator.pop(context, true)),
      ],
    ),
  );
  return ok ?? false;
}

/// Remaining data and time of a subscription.
class SubscriptionUsageView extends StatelessWidget {
  const SubscriptionUsageView({super.key, required this.usage, this.compact = false});
  final SubscriptionUsage usage;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final u = usage;
    final lowData = !u.isUnlimited && u.remainingFraction < 0.1;
    final left = u.timeLeft(now);
    final expired = u.isExpired(now);
    final soon = left != null && left.inDays < 3;

    final data = _metric(
      icon: Icons.data_usage,
      label: 'Data',
      value: u.isUnlimited ? 'Unlimited' : '${formatBytes(u.remaining)} left',
      detail: u.isUnlimited ? '${formatBytes(u.used)} used' : '${formatBytes(u.used)} of ${formatBytes(u.total)} used',
      color: u.isUnlimited
          ? AppColors.text
          : (u.remaining == 0 ? AppColors.bad : (lowData ? AppColors.warn : AppColors.text)),
      bar: u.isUnlimited ? null : u.remainingFraction,
    );
    final time = _metric(
      icon: Icons.event_outlined,
      label: 'Time',
      value: left == null ? 'No expiry' : (expired ? 'Expired' : _timeLeftText(left)),
      detail: u.expiresAt == null ? 'Never expires' : '${expired ? 'Ended' : 'Until'} ${_date(u.expiresAt!)}',
      color: expired ? AppColors.bad : (soon ? AppColors.warn : AppColors.text),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x06FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: data),
            const VerticalDivider(width: 24, thickness: 1, color: AppColors.line),
            Expanded(child: time),
          ],
        ),
      ),
    );
  }

  Widget _metric({
    required IconData icon,
    required String label,
    required String value,
    required String detail,
    required Color color,
    double? bar,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: AppColors.text3),
            const SizedBox(width: 6),
            Overline(label),
          ],
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: AppText.ui(compact ? 15 : 16, FontWeight.w700, color)),
        ),
        if (bar != null) ...[
          const SizedBox(height: 7),
          TrackBar(fraction: bar, height: 5),
        ],
        const SizedBox(height: 5),
        Text(detail,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.ui(10.5, FontWeight.w400, AppColors.text3)),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.profile, required this.state, required this.compact});
  final V2rayProfile profile;
  final V2rayState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final selected = state.selectedId == p.id;
    final c = state.connection;
    final live = c.profileId == p.id && c.isConnected;
    // Carrying an Auto connection right now.
    final inUse = c.isConnected && AutoSelect.isAuto(c.profileId) && c.activeProfileId == p.id;
    final info = p.problem == ShareLinkParser.infoEntryProblem;
    return Material(
      color: selected ? const Color(0x0D33D6C6) : Colors.transparent,
      child: InkWell(
        onTap: info ? null : () => bloc.v2ray.select(p.id),
        onDoubleTap: p.isUsable ? () => bloc.v2ray.connect(p.id) : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 10, 4, 10),
          child: Row(
            children: [
              if (info) const SizedBox(width: 16) else _SelectMark(selected: selected, live: live),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!info) ...[CodeBadge(p.protocol.label), const SizedBox(width: 7)],
                        Flexible(
                          child: Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(13, FontWeight.w600, info ? AppColors.text2 : AppColors.text)),
                        ),
                        if (inUse) ...[
                          const SizedBox(width: 7),
                          Text('IN USE', style: AppText.mono(9.5, FontWeight.w700, AppColors.good)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (info)
                      Text('Info from your provider', style: AppText.ui(11, FontWeight.w400, AppColors.text3))
                    else
                      Text(
                        '${p.stream.label} · ${p.endpoint}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.mono(10.5, FontWeight.w400, AppColors.text3),
                      ),
                    if (p.problem != null && !info) ...[
                      const SizedBox(height: 3),
                      Text(p.problem!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.ui(11, FontWeight.w500, AppColors.warn, height: 1.3)),
                    ] else if (p.stream.insecure && !info) ...[
                      const SizedBox(height: 3),
                      Text('Asks to skip certificate checks; Xray no longer allows that.',
                          maxLines: 2, style: AppText.ui(10.5, FontWeight.w400, AppColors.text3)),
                    ],
                  ],
                ),
              ),
              if (p.isUsable) ...[
                const SizedBox(width: 8),
                DelayChip(profileId: p.id, result: state.delays[p.id], testing: state.testing.contains(p.id)),
              ],
              if (!info) _menu(context) else const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final p = profile;
    final live = state.connection.profileId == p.id && state.connection.isConnected;
    return PopupMenuButton<String>(
      tooltip: 'More',
      color: AppColors.card2,
      icon: const Icon(Icons.more_vert, size: 17, color: AppColors.text3),
      onSelected: (action) async {
        switch (action) {
          case 'connect':
            await bloc.v2ray.connect(p.id);
          case 'disconnect':
            await bloc.v2ray.disconnect();
          case 'test':
            await bloc.v2ray.testProfile(p.id);
          case 'share':
            if (context.mounted) await showShareDialog(context, p);
          case 'copy':
            await Clipboard.setData(ClipboardData(text: p.link));
            if (context.mounted) _toast(context, 'Config link copied');
          case 'remove':
            await bloc.v2ray.removeProfile(p.id);
        }
      },
      itemBuilder: (_) => [
        if (p.isUsable && state.unsupportedReason == null)
          live
              ? _item('disconnect', Icons.power_settings_new, 'Disconnect')
              : _item('connect', Icons.power_settings_new, 'Connect'),
        if (p.isUsable) _item('test', Icons.speed, 'Test delay'),
        if (p.isUsable) _item('share', Icons.qr_code_2, 'Share…'),
        _item('copy', Icons.copy, 'Copy link'),
        if (p.subscriptionId == null) _item('remove', Icons.delete_outline, 'Remove', danger: true),
      ],
    );
  }
}

/// A group's "Fastest server" entry: Xray keeps probing the group's
/// configs and uses the fastest working one, switching when it fails.
class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.groupId, required this.state, required this.compact});
  final String groupId;
  final V2rayState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final id = AutoSelect.idFor(groupId);
    final selected = state.selectedId == id;
    final c = state.connection;
    final live = c.profileId == id && c.isConnected;
    final active = live ? state.profileById(c.activeProfileId) : null;
    final count = bloc.v2ray.autoCandidates(groupId).length;
    final String line;
    if (active != null) {
      line = 'Using ${active.name}';
    } else if (live) {
      line = 'Connected · picking the fastest of $count';
    } else {
      line = 'Uses the fastest of $count working configs and switches if one fails';
    }
    return Material(
      color: selected ? const Color(0x0D33D6C6) : Colors.transparent,
      child: InkWell(
        onTap: () => bloc.v2ray.select(id),
        onDoubleTap: () => bloc.v2ray.connect(id),
        child: Padding(
          padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 10, 4, 10),
          child: Row(
            children: [
              _SelectMark(selected: selected, live: live),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CodeBadge('AUTO'),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text('Fastest server',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(13, FontWeight.w600, AppColors.text)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(11, FontWeight.w400, live ? AppColors.good : AppColors.text3)),
                  ],
                ),
              ),
              IconButton(
                tooltip: live ? 'Disconnect' : 'Connect',
                visualDensity: VisualDensity.compact,
                onPressed: live ? bloc.v2ray.disconnect : () => bloc.v2ray.connect(id),
                icon: Icon(Icons.power_settings_new, size: 17, color: live ? AppColors.good : AppColors.text3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectMark extends StatelessWidget {
  const _SelectMark({required this.selected, required this.live});
  final bool selected;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = live ? AppColors.good : AppColors.accent;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? color : AppColors.line2, width: 1.6),
      ),
      alignment: Alignment.center,
      child: selected
          ? Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color))
          : null,
    );
  }
}

// ───────────────────────────── routing ─────────────────────────────

class VpnRoutingView extends StatefulWidget {
  const VpnRoutingView({super.key, required this.state, this.compact = false});
  final V2rayState state;
  final bool compact;

  @override
  State<VpnRoutingView> createState() => _VpnRoutingViewState();
}

class _VpnRoutingViewState extends State<VpnRoutingView> {
  late final TextEditingController _rules;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _rules = TextEditingController(text: widget.state.settings.rules.join('\n'))..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(VpnRoutingView old) {
    super.didUpdateWidget(old);
    // Rules added from the geo tag browser while nothing was being edited.
    final saved = widget.state.settings.rules.join('\n');
    if (saved != old.state.settings.rules.join('\n') && _rules.text.trim() == old.state.settings.rules.join('\n')) {
      _rules.text = saved;
    }
  }

  bool get _dirty => PassThroughRules.splitLines(_rules.text).join('\n') != widget.state.settings.rules.join('\n');

  Future<void> _save() async {
    setState(() => _saving = true);
    final compiled = await bloc.v2ray.setRules(_rules.text);
    if (!mounted) return;
    setState(() => _saving = false);
    _toast(
      context,
      compiled.issues.isEmpty
          ? 'Rules saved${widget.state.connection.isConnected ? ' and applied' : ''}'
          : 'Saved · ${compiled.issues.length} rule${compiled.issues.length == 1 ? '' : 's'} skipped',
    );
  }

  void _append(String rule) {
    final text = _rules.text.trimRight();
    _rules.text = text.isEmpty ? rule : '$text\n$rule';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final preview = PassThroughRules.compile(PassThroughRules.splitLines(_rules.text), s.assets);
    final pad = EdgeInsets.all(widget.compact ? 16 : 18);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConnectionCard(state: s, compact: widget.compact),
        const SizedBox(height: 12),
        _BehaviourCard(state: s, compact: widget.compact),
        const SizedBox(height: 12),
        _IranCard(state: s, compact: widget.compact),
        const SizedBox(height: 12),
        AppCard(
          padding: pad,
          child: _sectionTitle(
            'Bypass LAN',
            subtitle: 'Your local network (192.168.x.x, 10.x.x.x, printers, NAS, router pages) stays off the VPN.',
            trailing: AppSwitch(value: s.settings.bypassLan, onChanged: bloc.v2ray.setBypassLan),
          ),
        ),
        const SizedBox(height: 12),
        _AppsCard(state: s, compact: widget.compact),
        const SizedBox(height: 12),
        _FragmentCard(state: s, compact: widget.compact),
        const SizedBox(height: 12),
        AppCard(
          padding: pad,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionTitle(
                'Pass-through rules',
                subtitle: 'Traffic matching these goes out directly, like LAN traffic, instead of through the VPN '
                    'server. One rule per line.',
              ),
              const SizedBox(height: 12),
              _RulesField(
                controller: _rules,
                hint: 'geosite:category-ir\ngeoip:ir\next:iran.dat:ir\nexample.com\nkeyword:bank\n192.168.50.0/24',
                minLines: 6,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final example in PassThroughRules.examples) _ExampleChip(example, onTap: () => _append(example)),
                ],
              ),
              if (preview.issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final issue in preview.issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warn),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: issue.rule, style: AppText.mono(11, FontWeight.w600, AppColors.warn)),
                              TextSpan(text: '  ${issue.message}'),
                            ]),
                            style: AppText.ui(11.5, FontWeight.w400, AppColors.text2),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${preview.domains.length} domain and ${preview.ips.length} IP rule'
                      '${preview.ips.length == 1 ? '' : 's'} active',
                      style: AppText.ui(11, FontWeight.w400, AppColors.text3),
                    ),
                  ),
                  AppButton(
                    label: _saving ? 'Saving…' : 'Save rules',
                    icon: Icons.check,
                    height: 36,
                    onPressed: _dirty && !_saving ? _save : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _GeoAssetsCard(state: s, compact: widget.compact, onUseRule: _append),
      ],
    );
  }
}

/// Tunnel / Proxy, and the kill switch.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.state, required this.compact});
  final V2rayState state;
  final bool compact;

  bool get _android => !kIsWeb && Platform.isAndroid;

  String _describe(VpnMode mode) {
    if (_android) {
      return mode == VpnMode.tunnel
          ? 'Everything on this phone goes through the VPN.'
          : 'Only apps you set to use IRNet\'s local SOCKS proxy go through the VPN.';
    }
    final ask = kIsWeb
        ? ''
        : Platform.isWindows
            ? 'Windows asks for administrator permission once to set it up, then it connects without asking.'
            : 'Asks for your password once to set it up, then connects without asking.';
    return mode == VpnMode.tunnel
        ? 'Everything on this computer goes through the VPN, even apps that ignore proxy settings. $ask'
        : 'Browsers and apps that follow the system proxy use the VPN; others connect directly. No password needed.';
  }

  String get _killSwitchText {
    const base = 'Turns Wi-Fi and Ethernet off whenever the VPN isn\'t connected: if it drops, after you '
        'disconnect, and when IRNet quits or starts. Connecting turns them back on; switch this off to get '
        'your normal connection back.';
    if (kIsWeb) return base;
    if (Platform.isWindows) {
      return '$base Once Tunnel mode is set up it needs no prompts; until then Windows asks each time.';
    }
    if (Platform.isMacOS) return '$base Once Tunnel mode is set up it needs no password.';
    if (Platform.isLinux) return '$base Uses NetworkManager.';
    return base;
  }

  Future<void> _toggleKillSwitch(BuildContext context, bool on) async {
    if (on && !state.connection.isConnected) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.card,
          title: Text('Turn on the kill switch?', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
          content: Text(
            'The VPN isn\'t connected, so Wi-Fi and Ethernet turn off right away. Connect to bring them back.',
            style: AppText.ui(13, FontWeight.w400, AppColors.text2, height: 1.45),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            AppButton(label: 'Turn on', height: 36, onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      );
      if (ok != true) return;
    }
    await bloc.v2ray.setKillSwitch(on);
  }

  @override
  Widget build(BuildContext context) {
    final pad = EdgeInsets.all(compact ? 16 : 18);
    Widget option(VpnMode mode, IconData icon) {
      final active = state.mode == mode;
      return Expanded(
        child: Material(
          color: active ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: active ? null : () => bloc.v2ray.setMode(mode),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: active ? const Color(0x6633D6C6) : AppColors.line2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 17, color: active ? AppColors.accent : AppColors.text2),
                      const SizedBox(width: 8),
                      Text(mode.label,
                          style: AppText.ui(13.5, FontWeight.w700, active ? AppColors.accent : AppColors.text)),
                      const Spacer(),
                      if (active) const Icon(Icons.check_circle, size: 16, color: AppColors.accent),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(_describe(mode), style: AppText.ui(11, FontWeight.w400, AppColors.text3, height: 1.4)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AppCard(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(
            'Connection mode',
            subtitle: state.connection.isConnected ? 'Changing it reconnects.' : null,
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                option(VpnMode.tunnel, Icons.alt_route),
                const SizedBox(width: 10),
                option(VpnMode.proxy, Icons.settings_ethernet),
              ],
            ),
          ),
          if (bloc.v2ray.tunnelSetupInstalled) const _TunnelSetupRow(),
          const SizedBox(height: 16),
          const Divider(height: 1, color: AppColors.line),
          const SizedBox(height: 16),
          if (_android)
            _sectionTitle(
              'Kill switch',
              subtitle: 'Android blocks traffic outside the VPN itself: in VPN settings, tap IRNet and turn on '
                  'Always-on VPN and Block connections without VPN.',
              trailing: AppButton(
                label: 'VPN settings',
                icon: Icons.open_in_new,
                kind: AppButtonKind.outline,
                height: 34,
                onPressed: () => const MethodChannel('ir_net/xray').invokeMethod('openVpnSettings'),
              ),
            )
          else if (bloc.v2ray.killSwitchSupported)
            _sectionTitle(
              'Kill switch',
              subtitle: _killSwitchText,
              trailing: AppSwitch(
                value: state.settings.killSwitch,
                onChanged: (v) => _toggleKillSwitch(context, v),
              ),
            )
          else
            _sectionTitle('Kill switch', subtitle: 'Not available on this platform.'),
          if (state.killSwitchError != null) ...[
            const SizedBox(height: 10),
            _Note(state.killSwitchError!, color: AppColors.warn),
          ],
        ],
      ),
    );
  }
}

/// Tunnel mode's one-time setup is in place; offers to remove it.
class _TunnelSetupRow extends StatefulWidget {
  const _TunnelSetupRow();

  @override
  State<_TunnelSetupRow> createState() => _TunnelSetupRowState();
}

class _TunnelSetupRowState extends State<_TunnelSetupRow> {
  bool _removed = false;

  @override
  Widget build(BuildContext context) {
    if (_removed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined, size: 14, color: AppColors.good),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
                !kIsWeb && Platform.isWindows
                    ? 'Tunnel mode is set up to connect without an administrator prompt.'
                    : 'Tunnel mode is set up to connect without your password.',
                style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
          ),
          TextButton(
            onPressed: () async {
              final error = await bloc.v2ray.removeTunnelSetup();
              if (!context.mounted) return;
              if (error == null) {
                setState(() => _removed = true);
                _toast(context, 'Removed. Tunnel mode will ask once again to set itself up.');
              } else {
                _toast(context, error);
              }
            },
            child: Text('Remove', style: AppText.ui(11.5, FontWeight.w600, AppColors.text2)),
          ),
        ],
      ),
    );
  }
}

class _RulesField extends StatelessWidget {
  const _RulesField({required this.controller, required this.hint, this.minLines = 5, this.autofocus = false});
  final TextEditingController controller;
  final String hint;
  final int minLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: minLines + 8,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      style: AppText.mono(12.5, FontWeight.w500, AppColors.text, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppText.mono(12.5, FontWeight.w400, AppColors.text3, height: 1.5),
        filled: true,
        fillColor: AppColors.bg,
        contentPadding: const EdgeInsets.all(12),
        enabledBorder: border(AppColors.line2),
        focusedBorder: border(const Color(0x8033D6C6)),
      ),
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip(this.text, {required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: AppColors.line2),
          ),
          child: Text('+ $text', style: AppText.mono(10.5, FontWeight.w500, AppColors.text2)),
        ),
      ),
    );
  }
}

class _GeoAssetsCard extends StatelessWidget {
  const _GeoAssetsCard({required this.state, required this.compact, required this.onUseRule});
  final V2rayState state;
  final bool compact;
  final ValueChanged<String> onUseRule;

  bool get _supported => state.unsupportedReason == null || !(kIsWeb || Platform.isIOS);

  Future<void> _import(BuildContext context) async {
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final file = await openFile(
      acceptedTypeGroups: mobile
          ? const []
          : const [
              XTypeGroup(label: 'Geo data (.dat)', extensions: ['dat'])
            ],
    );
    if (file == null) return;
    if (!context.mounted) return;
    _toast(context, 'Reading ${file.name}…');
    try {
      final asset = await bloc.v2ray.importGeoAsset(file.name, await file.readAsBytes());
      if (context.mounted) {
        _toast(context, 'Imported ${asset.fileName}: ${asset.kind.label}, ${asset.tags.length} tags');
      }
    } on FormatException catch (e) {
      if (context.mounted) _toast(context, e.message);
    } catch (e) {
      if (context.mounted) _toast(context, 'Could not import the file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.all(compact ? 16 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(
            'Geo files',
            subtitle: 'Import geoip.dat and geosite.dat (or lists like iran.dat) to use geoip:, geosite: and ext: '
                'rules. Tap a file to browse its tags.',
            trailing: _supported && !compact
                ? AppButton(
                    label: 'Import .dat',
                    icon: Icons.upload_file,
                    kind: AppButtonKind.outline,
                    height: 34,
                    onPressed: () => _import(context),
                  )
                : null,
          ),
          if (_supported && compact) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: 'Import .dat file',
                icon: Icons.upload_file,
                kind: AppButtonKind.outline,
                height: 36,
                onPressed: () => _import(context),
              ),
            ),
          ],
          if (state.assets.isNotEmpty) const SizedBox(height: 12),
          for (final asset in state.assets) _GeoAssetRow(asset: asset, state: state, onUseRule: onUseRule),
          if (state.assets.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _supported ? 'No geo files imported yet.' : 'Geo files need the desktop or Android app.',
              style: AppText.ui(11.5, FontWeight.w400, AppColors.text3),
            ),
          ],
        ],
      ),
    );
  }
}

class _GeoAssetRow extends StatelessWidget {
  const _GeoAssetRow({required this.asset, required this.state, required this.onUseRule});
  final GeoAsset asset;
  final V2rayState state;
  final ValueChanged<String> onUseRule;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showDialog(
          context: context,
          builder: (_) => _GeoTagsDialog(asset: asset, onUseRule: onUseRule),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              IconTile(
                icon: asset.kind == GeoKind.ip ? Icons.public : Icons.language,
                size: 34,
                iconSize: 17,
                radius: 9,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(asset.fileName, style: AppText.mono(12.5, FontWeight.w600, AppColors.text)),
                    const SizedBox(height: 2),
                    Text('${asset.kind.label} · ${asset.tags.length} tags · ${formatBytes(asset.size)}',
                        style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.text3),
                onPressed: () async {
                  final used = state.settings.rules.any((r) =>
                      r.toLowerCase().contains(asset.fileName) ||
                      (asset.fileName == 'geoip.dat' && r.toLowerCase().startsWith('geoip:')) ||
                      (asset.fileName == 'geosite.dat' && r.toLowerCase().startsWith('geosite:')));
                  final ok = await _confirm(
                      context,
                      'Remove ${asset.fileName}?',
                      used
                          ? 'Rules that use it will be skipped until you import it again.'
                          : 'You can import it again later.');
                  if (ok) await bloc.v2ray.removeGeoAsset(asset.fileName);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GeoTagsDialog extends StatefulWidget {
  const _GeoTagsDialog({required this.asset, required this.onUseRule});
  final GeoAsset asset;
  final ValueChanged<String> onUseRule;

  @override
  State<_GeoTagsDialog> createState() => _GeoTagsDialogState();
}

class _GeoTagsDialogState extends State<_GeoTagsDialog> {
  String _query = '';
  final _added = <String>{};

  @override
  Widget build(BuildContext context) {
    final tags = widget.asset.tags.where((t) => t.contains(_query.toLowerCase())).toList();
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line2)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.asset.fileName, style: AppText.mono(15, FontWeight.w700, AppColors.text)),
              const SizedBox(height: 4),
              Text('Tap a tag to add it as a pass-through rule.',
                  style: AppText.ui(11.5, FontWeight.w400, AppColors.text3)),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _query = v.trim()),
                style: AppText.ui(13, FontWeight.w500, AppColors.text),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.text3),
                  hintText: 'Search ${widget.asset.tags.length} tags (e.g. ir)',
                  hintStyle: AppText.ui(13, FontWeight.w400, AppColors.text3),
                  filled: true,
                  fillColor: AppColors.bg,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.line2)),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tags.length,
                  itemBuilder: (context, i) {
                    final rule = widget.asset.ruleFor(tags[i]);
                    final added = _added.contains(rule);
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(tags[i], style: AppText.mono(12.5, FontWeight.w500, AppColors.text)),
                      subtitle: Text(rule, style: AppText.mono(10.5, FontWeight.w400, AppColors.text3)),
                      trailing: Icon(added ? Icons.check : Icons.add,
                          size: 18, color: added ? AppColors.good : AppColors.text2),
                      onTap: added
                          ? null
                          : () {
                              widget.onUseRule(rule);
                              setState(() => _added.add(rule));
                            },
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: AppButton(
                  label: _added.isEmpty ? 'Close' : 'Done · save rules to apply',
                  height: 36,
                  kind: _added.isEmpty ? AppButtonKind.outline : AppButtonKind.primary,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── overview tile ─────────────────────────────

/// Overview tile: VPN status, the config in use and its subscription's
/// remaining data/time, with a connect button.
class VpnSummaryCard extends StatelessWidget {
  const VpnSummaryCard({super.key, this.onTap, this.compact = false});
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<V2rayState>(
      stream: bloc.v2ray.state,
      initialData: bloc.v2ray.value,
      builder: (context, snapshot) {
        final s = snapshot.data!;
        final c = s.connection;
        final target = _target(s);
        final profile = target.profile;
        final sub = s.subscriptionById(target.groupId ?? profile?.subscriptionId);
        final delay = profile == null ? null : s.delays[profile.id];
        final cut = s.networkCut && !c.isConnected && !c.isBusy;
        final (word, color, soft) = cut
            ? ('Network off', AppColors.bad, AppColors.badSoft)
            : switch (c.phase) {
                ConnectionPhase.connected => ('Connected', AppColors.good, AppColors.goodSoft),
                ConnectionPhase.connecting => ('Connecting', AppColors.warn, AppColors.warnSoft),
                ConnectionPhase.disconnecting => ('Disconnecting', AppColors.warn, AppColors.warnSoft),
                ConnectionPhase.failed => ('Failed', AppColors.bad, AppColors.badSoft),
                ConnectionPhase.disconnected => ('Off', AppColors.text3, AppColors.card2),
              };

        final lines = <InlineSpan>[];
        if (target.name != null) {
          lines.add(TextSpan(text: target.name));
          if (delay?.ms != null) {
            lines.add(
                TextSpan(text: '  ${delay!.ms} ms', style: AppText.mono(11.5, FontWeight.w600, delayColor(delay.ms!))));
          }
        } else {
          lines.add(TextSpan(text: s.profiles.isEmpty ? 'No configs yet · tap to add' : 'Pick a config'));
        }
        final usage = sub?.usage;
        String? usageText;
        if (usage != null) {
          final left = usage.timeLeft(DateTime.now());
          usageText = [
            usage.isUnlimited ? 'Unlimited data' : '${formatBytes(usage.remaining)} left',
            if (left != null) usage.isExpired(DateTime.now()) ? 'expired' : _timeLeftText(left),
          ].join(' · ');
        }

        final canToggle = s.unsupportedReason == null && (s.profiles.isNotEmpty || c.isConnected);
        final button = AppButton(
          label: c.isConnected || c.phase == ConnectionPhase.connecting ? 'Disconnect' : 'Connect',
          icon: Icons.power_settings_new,
          kind: c.isConnected || c.phase == ConnectionPhase.connecting ? AppButtonKind.outline : AppButtonKind.primary,
          height: 36,
          onPressed: canToggle && !c.isBusy
              ? bloc.v2ray.toggle
              : (c.phase == ConnectionPhase.connecting ? bloc.v2ray.disconnect : null),
        );

        return AppCard(
          onTap: onTap,
          child: Row(
            children: [
              IconTile(icon: Icons.vpn_lock_outlined, size: 44, iconSize: 22, color: color, background: soft),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text('V2Ray VPN',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                        ),
                        const SizedBox(width: 8),
                        Pill(label: word, dotColor: color, textColor: color, background: soft),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text.rich(
                      TextSpan(children: lines),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui(14, FontWeight.w600, AppColors.text),
                    ),
                    if (usageText != null || (c.phase == ConnectionPhase.failed && c.error != null)) ...[
                      const SizedBox(height: 3),
                      Text(
                        c.phase == ConnectionPhase.failed && c.error != null ? c.error! : usageText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui(
                            11, FontWeight.w400, c.phase == ConnectionPhase.failed ? AppColors.bad : AppColors.text3),
                      ),
                    ],
                  ],
                ),
              ),
              if (s.unsupportedReason == null) ...[
                const SizedBox(width: 10),
                if (compact)
                  _PowerButton(
                    phase: c.phase,
                    size: 44,
                    onPressed: canToggle && !c.isBusy
                        ? bloc.v2ray.toggle
                        : (c.phase == ConnectionPhase.connecting ? bloc.v2ray.disconnect : null),
                  )
                else
                  button,
              ],
            ],
          ),
        );
      },
    );
  }
}
