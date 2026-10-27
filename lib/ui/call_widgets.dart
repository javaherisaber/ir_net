import 'package:flutter/material.dart';
import 'package:ir_net/data/call_quality.dart';
import 'package:ir_net/data/quality.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/quality_bloc.dart';
import 'package:ir_net/utils/call_tester.dart';

import 'components.dart';
import 'format.dart';
import 'quality_widgets.dart';
import 'theme.dart';

String formatMos(double? mos) => mos == null ? '--' : mos.toStringAsFixed(1);

/// Voice / video call quality: continuous estimates from the background
/// probes plus an on-demand simulated call.
class CallQualityCard extends StatelessWidget {
  const CallQualityCard({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QualityLive>(
      stream: bloc.quality.live,
      builder: (context, liveSnap) {
        final live = liveSnap.data;
        if (live == null || !live.supported) return const SizedBox.shrink();
        return StreamBuilder<CallTestState>(
          stream: bloc.quality.callTest,
          builder: (context, stateSnap) {
            final state = stateSnap.data ?? const CallTestState(CallTestStatus.idle);
            return StreamBuilder<List<CallTestEntry>>(
              stream: bloc.quality.callTests,
              builder: (context, testsSnap) {
                final tests = testsSnap.data ?? const <CallTestEntry>[];
                return _card(live, state, tests);
              },
            );
          },
        );
      },
    );
  }

  Widget _card(QualityLive live, CallTestState state, List<CallTestEntry> tests) {
    final server = live.server?.ip;
    CallTestEntry? latestHere;
    for (final t in tests) {
      if (t.result.server == server) {
        latestHere = t;
        break;
      }
    }
    final voice = live.recent.call(CallKind.voice);
    final video = live.recent.call(CallKind.video);
    final tier = latestHere?.result.tier;
    final videoNote = tier == null
        ? 'Run a call test to check bandwidth for video'
        : '${tier.label} · ${formatMbps(latestHere!.result.downMbps)} ↓ / ${formatMbps(latestHere.result.upMbps)} ↑';
    final viaTcp = voice?.viaTcp ?? false;
    final source = viaTcp
        ? 'UDP blocked: call apps fall back to slower TCP relays'
        : 'Last ${QualityLive.liveWindow.inMinutes} min of probes';

    return AppCard(
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.phone_in_talk_outlined, size: 16, color: AppColors.accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text('ONLINE CALLS',
                    style: AppText.ui(12, FontWeight.w600, AppColors.text2, letterSpacing: 0.6)),
              ),
              AppButton(
                label: state.running ? 'Testing ${(state.progress!.fraction * 100).round()}%' : 'Test a call',
                icon: state.running ? null : Icons.play_arrow,
                kind: AppButtonKind.ghostAccent,
                height: 34,
                onPressed: state.running ? null : bloc.quality.runCallTest,
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, c) {
            final tiles = [
              _CallTile(kind: CallKind.voice, quality: voice, note: source),
              _CallTile(kind: CallKind.video, quality: video, note: videoNote),
            ];
            if (c.maxWidth < 520) {
              return Column(children: [tiles[0], const SizedBox(height: 10), tiles[1]]);
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: tiles[0]),
                  const SizedBox(width: 10),
                  Expanded(child: tiles[1]),
                ],
              ),
            );
          }),
          if (state.running) ...[
            const SizedBox(height: 14),
            _Progress(state.progress!),
          ],
          if (state.status == CallTestStatus.failed) ...[
            const SizedBox(height: 14),
            InfoBanner(state.error ?? 'The call test failed', icon: Icons.error_outline),
          ],
          if (tests.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(height: 1, color: AppColors.line),
            const SizedBox(height: 12),
            _RecentTests(tests.take(5).toList()),
          ],
          const SizedBox(height: 12),
          Text(
            'MOS from the ITU-T G.107 E-model (1–4.5; 4.0 and up is a good call). A call test sends '
            '400 voice-sized packets over 8 seconds, like a real call, then checks bandwidth for '
            'video (about 4 MB of data).',
            style: AppText.ui(10.5, FontWeight.w400, AppColors.text3, height: 1.45),
          ),
        ],
      ),
    );
  }
}

String formatMbps(double? mbps) {
  if (mbps == null) return '?';
  return mbps < 10 ? '${mbps.toStringAsFixed(1)} Mbps' : '${mbps.round()} Mbps';
}

class _CallTile extends StatelessWidget {
  const _CallTile({required this.kind, required this.quality, required this.note});

  final CallKind kind;
  final CallQuality? quality;
  final String note;

  @override
  Widget build(BuildContext context) {
    final q = quality;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(kind == CallKind.voice ? Icons.call_outlined : Icons.videocam_outlined,
                  size: 14, color: AppColors.text3),
              const SizedBox(width: 7),
              Expanded(child: Overline(kind.label)),
              _MosGrade(q),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(formatMos(q?.mos), style: AppText.ui(30, FontWeight.w700, q == null ? AppColors.text3 : AppColors.text, height: 1)),
              const SizedBox(width: 6),
              Text('MOS', style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
            ],
          ),
          const SizedBox(height: 10),
          MosMeter(q?.mos),
          const SizedBox(height: 8),
          Text(note, style: AppText.ui(11, FontWeight.w400, AppColors.text3, height: 1.35)),
        ],
      ),
    );
  }
}

class _MosGrade extends StatelessWidget {
  const _MosGrade(this.quality);
  final CallQuality? quality;

  @override
  Widget build(BuildContext context) {
    final grade = quality?.grade;
    return Pill(
      label: grade?.label ?? 'No data',
      dotColor: gradeColor(grade),
      textColor: grade == null ? AppColors.text3 : gradeColor(grade),
      background: grade == null ? AppColors.card2 : gradeColor(grade).withValues(alpha: 0.12),
    );
  }
}

/// MOS on a 1–4.5 track; the fill wears the grade's status colour.
class MosMeter extends StatelessWidget {
  const MosMeter(this.mos, {super.key});
  final double? mos;

  @override
  Widget build(BuildContext context) {
    final value = mos;
    final fraction = value == null ? 0.0 : ((value - 1) / 3.5).clamp(0.0, 1.0);
    final color = value == null ? AppColors.text3 : gradeColor(CallQuality.gradeOfMos(value));
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        height: 6,
        color: AppColors.grid,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction,
          child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.progress);
  final CallTestProgress progress;

  @override
  Widget build(BuildContext context) {
    final text = switch (progress.phase) {
      CallTestPhase.voice => 'Simulating an 8-second voice call (50 packets a second)…',
      CallTestPhase.download => 'Checking download bandwidth for video…',
      CallTestPhase.upload => 'Checking upload bandwidth for video…',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrackBar(fraction: progress.fraction),
        const SizedBox(height: 8),
        Text(text, style: AppText.ui(11.5, FontWeight.w500, AppColors.text2)),
      ],
    );
  }
}

class _RecentTests extends StatelessWidget {
  const _RecentTests(this.tests);
  final List<CallTestEntry> tests;

  @override
  Widget build(BuildContext context) {
    final latest = tests.first.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('LAST CALL TEST', style: AppText.overline(AppColors.text3)),
        const SizedBox(height: 6),
        Text(
          '${latest.sent} packets · ${formatPercent(latest.lossPercent)} lost · '
          '${latest.late} too late · longest dropout ${latest.maxBurst * 20} ms · '
          'jitter ${formatMs(latest.jitter)} · ping ${formatMs(latest.rttMedian)} (p95 ${formatMs(latest.rttP95)})',
          style: AppText.mono(11, FontWeight.w500, AppColors.text2, height: 1.5),
        ),
        if (latest.udpBlocked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('No UDP replies: this connection blocks UDP, so call apps fall back to TCP relays.',
                style: AppText.ui(11, FontWeight.w500, AppColors.warn)),
          ),
        const SizedBox(height: 10),
        for (final t in tests) _TestRow(t),
      ],
    );
  }
}

class _TestRow extends StatelessWidget {
  const _TestRow(this.entry);
  final CallTestEntry entry;

  @override
  Widget build(BuildContext context) {
    final r = entry.result;
    final info = entry.server;
    final title = info == null ? (r.server.isEmpty ? 'Unknown network' : r.server) : serverTitle(info);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          FlagIcon(info?.countryCode, width: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text('$title · ${formatDayClock(r.at.millisecondsSinceEpoch / 1000)}',
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(11.5, FontWeight.w500, AppColors.text2)),
          ),
          _mini(Icons.call_outlined, r.voice.mos),
          const SizedBox(width: 12),
          _mini(Icons.videocam_outlined, r.video.mos),
          const SizedBox(width: 12),
          SizedBox(
            width: 92,
            child: Text(r.tier?.label ?? 'bandwidth ?',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui(11, FontWeight.w500, AppColors.text3)),
          ),
        ],
      ),
    );
  }

  Widget _mini(IconData icon, double mos) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.text3),
          const SizedBox(width: 4),
          StatusDot(gradeColor(CallQuality.gradeOfMos(mos)), size: 5),
          const SizedBox(width: 4),
          Text(formatMos(mos), style: AppText.mono(11.5, FontWeight.w600, AppColors.text)),
        ],
      );
}
