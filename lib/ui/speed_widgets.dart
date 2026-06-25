import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';

import 'components.dart';
import 'theme.dart';

String _pingText(double? v) => (v == null || v == 0) ? '--' : '${v.toInt()}';

String _speedText(double? v, {bool upload = false}) {
  if (v == null || v == 0) return '--';
  if (upload && v > 500) return '--'; // mirrors known speedtest upload glitch
  return '${v.toInt()}';
}

/// Run button bound to `bloc.speedTestStatus`.
class SpeedRunButton extends StatelessWidget {
  const SpeedRunButton({super.key, this.expand = true, this.label = 'Run speed test'});
  final bool expand;
  final String label;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: bloc.speedTestStatus,
      builder: (context, snapshot) {
        final running = snapshot.data == 'Running';
        return AppButton(
          label: running ? 'Running…' : label,
          icon: running ? null : Icons.play_arrow,
          height: 52,
          expand: expand,
          onPressed: running ? null : bloc.onConnectionTestClick,
        );
      },
    );
  }
}

/// Full speed-test screen body (mobile Speed tab + desktop Speed section).
class SpeedTestView extends StatelessWidget {
  const SpeedTestView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pingHero(),
        const SizedBox(height: 14),
        _speedRow(Icons.south, 'Download', bloc.downloadSpeed),
        const SizedBox(height: 10),
        _speedRow(Icons.north, 'Upload', bloc.uploadSpeed, upload: true),
        const SizedBox(height: 14),
        const SpeedRunButton(),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.dns_outlined, size: 12, color: AppColors.text3),
            const SizedBox(width: 7),
            Text('via speedtest.jaosing.com',
                style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
          ],
        ),
      ],
    );
  }

  Widget _pingHero() {
    return StreamBuilder<double?>(
      stream: bloc.ping,
      builder: (context, snapshot) {
        final ping = snapshot.data;
        final fraction = ping == null ? 0.0 : (ping / 250).clamp(0.0, 1.0);
        return AppCard(
          gradient: AppGradients.card,
          radius: 18,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.timer_outlined, size: 14, color: AppColors.text3),
                  const SizedBox(width: 7),
                  Text('PING',
                      style: AppText.ui(11, FontWeight.w500, AppColors.text3, letterSpacing: 0.7)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(_pingText(ping),
                      style: AppText.mono(52, FontWeight.w700, AppColors.text, height: 1)),
                  const SizedBox(width: 5),
                  Text('ms', style: AppText.ui(16, FontWeight.w500, AppColors.text3)),
                ],
              ),
              const SizedBox(height: 20),
              _meter(fraction),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('FAST',
                      style: AppText.ui(9, FontWeight.w500, AppColors.text3, letterSpacing: 0.5)),
                  Text('SLOW',
                      style: AppText.ui(9, FontWeight.w500, AppColors.text3, letterSpacing: 0.5)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _meter(double fraction) {
    return SizedBox(
      height: 14,
      child: LayoutBuilder(
        builder: (context, c) {
          const knob = 14.0;
          final x = (c.maxWidth - knob) * fraction.clamp(0.0, 1.0);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: const LinearGradient(
                      colors: [AppColors.good, AppColors.warn, AppColors.bad],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: x,
                top: 0,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.card, width: 3),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _speedRow(IconData icon, String label, Stream<double?> stream, {bool upload = false}) {
    return AppCard(
      radius: 14,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          IconTile(icon: icon, size: 38, iconSize: 19, radius: 11),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.ui(13, FontWeight.w500, AppColors.text)),
                const SizedBox(height: 1),
                Text('Mbps', style: AppText.ui(10, FontWeight.w400, AppColors.text3)),
              ],
            ),
          ),
          StreamBuilder<double?>(
            stream: stream,
            builder: (context, snapshot) {
              final text = _speedText(snapshot.data, upload: upload);
              return Text(text,
                  style: AppText.mono(
                      22, FontWeight.w600, text == '--' ? AppColors.text3 : AppColors.text));
            },
          ),
        ],
      ),
    );
  }
}

/// Overview summary tile with inline Ping / Download / Upload.
class SpeedSummaryCard extends StatelessWidget {
  const SpeedSummaryCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed, size: 17, color: AppColors.accent),
              const SizedBox(width: 8),
              Text('Speed test', style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
              const Spacer(),
              StreamBuilder<String>(
                stream: bloc.speedTestStatus,
                builder: (context, snapshot) {
                  final running = snapshot.data == 'Running';
                  return AppButton(
                    label: running ? 'Running…' : 'Run test',
                    icon: running ? null : Icons.play_arrow,
                    kind: AppButtonKind.ghostAccent,
                    height: 34,
                    onPressed: running ? null : bloc.onConnectionTestClick,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _metric(Icons.timer_outlined, 'Ping', bloc.ping, 'ms', isPing: true)),
              Expanded(child: _metric(Icons.south, 'Download', bloc.downloadSpeed, 'Mbps')),
              Expanded(
                  child: _metric(Icons.north, 'Upload', bloc.uploadSpeed, 'Mbps', upload: true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, String label, Stream<double?> stream, String unit,
      {bool isPing = false, bool upload = false}) {
    return StreamBuilder<double?>(
      stream: stream,
      builder: (context, snapshot) {
        final text = isPing ? _pingText(snapshot.data) : _speedText(snapshot.data, upload: upload);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: AppColors.text3),
                const SizedBox(width: 6),
                Text(label.toUpperCase(),
                    style: AppText.ui(10, FontWeight.w500, AppColors.text3, letterSpacing: 0.5)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(text,
                    style: AppText.mono(
                        24, FontWeight.w600, text == '--' ? AppColors.text3 : AppColors.text)),
                const SizedBox(width: 4),
                Text(unit, style: AppText.ui(12, FontWeight.w500, AppColors.text3)),
              ],
            ),
          ],
        );
      },
    );
  }
}
