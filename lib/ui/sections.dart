import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';

import 'balance_widgets.dart';
import 'components.dart';
import 'connection_widgets.dart';
import 'leak_widgets.dart';
import 'speed_widgets.dart';
import 'theme.dart';

/// Overview / Home.
class OverviewSection extends StatelessWidget {
  const OverviewSection({
    super.key,
    this.compact = false,
    this.onOpenConnection,
    this.onOpenLeaks,
    this.onOpenBalance,
    this.onOpenSpeed,
  });

  final bool compact;
  final VoidCallback? onOpenConnection;
  final VoidCallback? onOpenLeaks;
  final VoidCallback? onOpenBalance;
  final VoidCallback? onOpenSpeed;

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
