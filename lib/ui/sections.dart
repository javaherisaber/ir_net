import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/quality_bloc.dart';

import 'package:ir_net/utils/usage_collectors.dart';

import 'balance_widgets.dart';
import 'call_widgets.dart';
import 'components.dart';
import 'connection_widgets.dart';
import 'export_widgets.dart';
import 'leak_widgets.dart';
import 'quality_widgets.dart';
import 'speed_widgets.dart';
import 'theme.dart';
import 'usage_widgets.dart';

/// Overview / Home.
class OverviewSection extends StatelessWidget {
  const OverviewSection({
    super.key,
    this.compact = false,
    this.onOpenConnection,
    this.onOpenLeaks,
    this.onOpenBalance,
    this.onOpenSpeed,
    this.onOpenQuality,
    this.onOpenUsage,
  });

  final bool compact;
  final VoidCallback? onOpenConnection;
  final VoidCallback? onOpenLeaks;
  final VoidCallback? onOpenBalance;
  final VoidCallback? onOpenSpeed;
  final VoidCallback? onOpenQuality;
  final VoidCallback? onOpenUsage;

  @override
  Widget build(BuildContext context) {
    final gap = compact ? 12.0 : 14.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConnectionHeroCard(compact: compact, onDetails: onOpenConnection),
        SizedBox(height: gap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: LeakSummaryCard(onTap: onOpenLeaks)),
            SizedBox(width: gap),
            Expanded(child: BalanceSummaryCard(onTap: onOpenBalance)),
          ],
        ),
        SizedBox(height: gap),
        if (usageUnsupportedReason() == null && !compact)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: QualitySummaryCard(onTap: onOpenQuality)),
                SizedBox(width: gap),
                Expanded(child: UsageSummaryCard(onTap: onOpenUsage)),
              ],
            ),
          )
        else ...[
          QualitySummaryCard(onTap: onOpenQuality),
          if (usageUnsupportedReason() == null) ...[
            SizedBox(height: gap),
            UsageSummaryCard(onTap: onOpenUsage),
          ],
        ],
        SizedBox(height: gap),
        SpeedSummaryCard(onTap: onOpenSpeed),
        if (!compact && Platform.isWindows) ...[
          SizedBox(height: gap),
          const IpDnsCard(),
        ],
      ],
    );
  }
}

/// Leak detection.
class LeakSection extends StatelessWidget {
  const LeakSection({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LeakInputBar(buttonLabel: compact ? null : 'Add site'),
        const SizedBox(height: 14),
        const Row(
          children: [
            Overline('Monitored sites'),
            Spacer(),
            _LeakReachableLabel(),
          ],
        ),
        const SizedBox(height: 12),
        LeakList(compact: compact),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.refresh, size: 12, color: AppColors.text3),
            const SizedBox(width: 7),
            Text('Re-checked automatically every 20s',
                style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
          ],
        ),
      ],
    );
  }
}

class _LeakReachableLabel extends StatelessWidget {
  const _LeakReachableLabel();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.leakChecklist,
      builder: (context, snapshot) {
        final counts = LeakCounts.from(snapshot.data ?? const []);
        return Text('${counts.reachable} of ${counts.total} reachable',
            style: AppText.ui(11, FontWeight.w500, AppColors.text3));
      },
    );
  }
}

/// Connection details.
class ConnectionSection extends StatelessWidget {
  const ConnectionSection({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConnectionHeroCard(compact: true),
          SizedBox(height: 14),
          LocationTableCard(),
          SizedBox(height: 14),
          InfoNote('Public IP, DNS records & local interfaces are available on the desktop apps.'),
        ],
      );
    }
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: LocationTableCard(withHeader: true)),
        SizedBox(width: 14),
        Expanded(child: IpDnsCard()),
      ],
    );
  }
}

/// Data balance + Kerio account.
class BalanceSection extends StatelessWidget {
  const BalanceSection({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BalanceHeroCard(compact: true),
          SizedBox(height: 14),
          KerioAccountCard(),
        ],
      );
    }
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 6, child: BalanceHeroCard(showFooter: true)),
        SizedBox(width: 14),
        Expanded(flex: 5, child: KerioAccountCard()),
      ],
    );
  }
}

/// Speed test.
class SpeedSection extends StatelessWidget {
  const SpeedSection({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const view = SpeedTestView();
    if (compact) return view;
    // Constrain width on wide desktop so the meter doesn't stretch absurdly.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: view,
      ),
    );
  }
}

/// Network quality: live probes, server comparison and history.
class QualitySection extends StatefulWidget {
  const QualitySection({super.key, this.compact = false});
  final bool compact;

  @override
  State<QualitySection> createState() => _QualitySectionState();
}

class _QualitySectionState extends State<QualitySection> {
  // The cards "Copy screenshot" puts in its image.
  final _liveCard = GlobalKey();
  final _callsCard = GlobalKey();
  final _historyCard = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ReloadOnMount(
      onReload: bloc.quality.reload,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (QualityBloc.isSupported) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [QualityScreenshotButton(cards: [_liveCard, _callsCard, _historyCard])],
            ),
            const SizedBox(height: 12),
          ],
          RepaintBoundary(key: _liveCard, child: QualityLiveCard(compact: widget.compact)),
          const SizedBox(height: 14),
          RepaintBoundary(key: _callsCard, child: CallQualityCard(compact: widget.compact)),
          const SizedBox(height: 18),
          const QualityFilterBar(),
          const SizedBox(height: 12),
          const QualityCompareCard(),
          const SizedBox(height: 14),
          RepaintBoundary(key: _historyCard, child: const QualityHistoryCard()),
        ],
      ),
    );
  }
}

/// Data usage per app, domain and country.
class UsageSection extends StatelessWidget {
  const UsageSection({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ReloadOnMount(
      onReload: bloc.usage.reload,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const UsageFilterBar(),
          const SizedBox(height: 14),
          const UsageStatusBanner(),
          UsageOverviewCard(compact: compact),
          const SizedBox(height: 14),
          const UsageBreakdownCard(),
        ],
      ),
    );
  }
}
