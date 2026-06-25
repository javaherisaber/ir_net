import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/main.dart';
import 'package:url_launcher/url_launcher.dart';

import 'components.dart';
import 'theme.dart';

class LeakCounts {
  const LeakCounts(this.reachable, this.unreachable, this.total);
  final int reachable;
  final int unreachable;
  final int total;

  factory LeakCounts.from(List<LeakItem> items) {
    var ok = 0, bad = 0;
    for (final i in items) {
      if (i.status == LeakStatus.passed) ok++;
      if (i.status == LeakStatus.failed) bad++;
    }
    return LeakCounts(ok, bad, items.length);
  }
}

/// "Add a site to monitor" input. [buttonLabel] null → icon-only add button.
class LeakInputBar extends StatefulWidget {
  const LeakInputBar({super.key, this.buttonLabel});
  final String? buttonLabel;

  @override
  State<LeakInputBar> createState() => _LeakInputBarState();
}

class _LeakInputBarState extends State<LeakInputBar> {
  final _controller = TextEditingController();
  StreamSubscription? _clearSub;

  @override
  void initState() {
    super.initState();
    _clearSub = bloc.clearLeakInput.listen((_) => _controller.clear());
  }

  @override
  void dispose() {
    _clearSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _submit() => bloc.onAddLeakItemClick();

  @override
  Widget build(BuildContext context) {
    final iconOnly = widget.buttonLabel == null;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 50,
            padding: EdgeInsets.only(left: 14, right: iconOnly ? 6 : 14),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppColors.line2),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, size: 16, color: AppColors.text3),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onChanged: bloc.onLeakInputChanged,
                    onSubmitted: (_) => _submit(),
                    keyboardType: TextInputType.url,
                    style: AppText.ui(13, FontWeight.w400, AppColors.text),
                    cursorColor: AppColors.accent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'https://developer.google.com',
                      hintStyle: AppText.ui(13, FontWeight.w400, AppColors.text3),
                    ),
                  ),
                ),
                if (iconOnly) ...[
                  const SizedBox(width: 6),
                  _addButton(square: true),
                ],
              ],
            ),
          ),
        ),
        if (!iconOnly) ...[
          const SizedBox(width: 12),
          _addButton(square: false),
        ],
      ],
    );
  }

  Widget _addButton({required bool square}) {
    return Material(
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(square ? 11 : 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(square ? 11 : 12),
        onTap: _submit,
        child: square
            ? const SizedBox(
                width: 38,
                height: 38,
                child: Icon(Icons.add, size: 18, color: AppColors.onAccent),
              )
            : Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add, size: 16, color: AppColors.onAccent),
                    const SizedBox(width: 8),
                    Text(widget.buttonLabel!,
                        style: AppText.ui(13, FontWeight.w600, AppColors.onAccent)),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The monitored-sites list. [compact] = mobile (status under URL).
class LeakList extends StatelessWidget {
  const LeakList({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LeakItem>>(
      stream: bloc.leakChecklist,
      builder: (context, snapshot) {
        final items = snapshot.data;
        if (items == null) return const SizedBox.shrink();
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('No sites monitored yet',
                  style: AppText.ui(13, FontWeight.w400, AppColors.text3)),
            ),
          );
        }
        return Column(
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _LeakRow(item: item, compact: compact),
              ),
          ],
        );
      },
    );
  }
}

class _LeakRow extends StatelessWidget {
  const _LeakRow({required this.item, required this.compact});
  final LeakItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final failed = item.status == LeakStatus.failed;
    final radius = compact ? 13.0 : 12.0;
    return Material(
      color: failed ? AppColors.badSoft : AppColors.card,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => launchUrl(Uri.parse(item.url)),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 16, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: failed ? AppColors.badBorder : AppColors.line),
          ),
          child: compact ? _compact() : _wide(),
        ),
      ),
    );
  }

  Widget _statusTile() {
    switch (item.status) {
      case LeakStatus.passed:
        return const IconTile(
            icon: Icons.check,
            size: 26,
            iconSize: 15,
            radius: 8,
            background: AppColors.goodSoft,
            color: AppColors.good);
      case LeakStatus.failed:
        return const IconTile(
            icon: Icons.close,
            size: 26,
            iconSize: 15,
            radius: 8,
            background: Color(0x24FB6A6A),
            color: AppColors.bad);
      default:
        return const SizedBox(
          width: 26,
          height: 26,
          child: Padding(
            padding: EdgeInsets.all(5),
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.text3),
          ),
        );
    }
  }

  String get _statusLabel => switch (item.status) {
        LeakStatus.passed => 'Reachable',
        LeakStatus.failed => 'Unreachable',
        _ => 'Checking…',
      };

  Color get _statusColor => switch (item.status) {
        LeakStatus.passed => AppColors.good,
        LeakStatus.failed => AppColors.bad,
        _ => AppColors.text3,
      };

  Widget _deleteButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => bloc.onDeleteLeakItemClick(item),
      child: const Padding(
        padding: EdgeInsets.all(2),
        child: Icon(Icons.close, size: 16, color: AppColors.text3),
      ),
    );
  }

  Widget _compact() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: _statusTile()),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.url,
                  style: AppText.mono(12.5, FontWeight.w500, AppColors.text, height: 1.4)),
              const SizedBox(height: 4),
              Text(
                item.status == LeakStatus.failed ? 'Unreachable · possible leak' : _statusLabel,
                style: AppText.ui(10, FontWeight.w400, _statusColor),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Padding(padding: const EdgeInsets.only(top: 3), child: _deleteButton()),
      ],
    );
  }

  Widget _wide() {
    return Row(
      children: [
        _statusTile(),
        const SizedBox(width: 14),
        Expanded(
          child: Text(item.url,
              style: AppText.mono(13, FontWeight.w500, AppColors.text, height: 1.4)),
        ),
        const SizedBox(width: 14),
        Text(_statusLabel, style: AppText.ui(11, FontWeight.w500, _statusColor)),
        const SizedBox(width: 14),
        _deleteButton(),
      ],
    );
  }
}

/// Overview summary tile.
class LeakSummaryCard extends StatelessWidget {
  const LeakSummaryCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LeakItem>>(
      stream: bloc.leakChecklist,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <LeakItem>[];
        final counts = LeakCounts.from(items);
        return AppCard(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_user_outlined, size: 17, color: AppColors.good),
                  const SizedBox(width: 8),
                  Text('Leak detection',
                      style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                ],
              ),
              const SizedBox(height: 14),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${counts.reachable}',
                        style: AppText.ui(30, FontWeight.w700, AppColors.text)),
                    const SizedBox(width: 6),
                    Text('/ ${counts.total} reachable',
                        style: AppText.ui(15, FontWeight.w500, AppColors.text3)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _segments(items),
              const SizedBox(height: 9),
              Text(
                counts.total == 0
                    ? 'No sites monitored'
                    : counts.unreachable == 0
                        ? 'All sites reachable'
                        : '${counts.unreachable} site${counts.unreachable == 1 ? '' : 's'} unreachable · review',
                style: AppText.ui(
                    11, FontWeight.w400, counts.unreachable == 0 ? AppColors.text3 : AppColors.warn),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _segments(List<LeakItem> items) {
    if (items.isEmpty) {
      return Container(
          height: 6,
          decoration:
              BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(3)));
    }
    return Row(
      children: [
        for (final item in items)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  color: switch (item.status) {
                    LeakStatus.passed => AppColors.good,
                    LeakStatus.failed => AppColors.bad,
                    _ => AppColors.line2,
                  },
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
