import 'package:flutter/material.dart';
import 'package:ir_net/data/kerio.dart';
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/kerio.dart';
import 'package:url_launcher/url_launcher.dart';

import 'components.dart';
import 'theme.dart';

const _gb = 1024 * 1024 * 1024;

class _BalanceView {
  _BalanceView(KerioBalance? b)
      : hasData = b != null && b.total > 0,
        remainingNumber = b == null || b.total <= 0
            ? '--'
            : (b.remaining / _gb).toStringAsFixed(2),
        usedText = b == null || b.total <= 0
            ? '--'
            : KerioUtils.formatBytes(b.total - b.remaining),
        totalText =
            b == null || b.total <= 0 ? '--' : KerioUtils.formatBytes(b.total),
        fraction = b == null || b.total <= 0 ? 0.0 : b.remaining / b.total;

  final bool hasData;
  final String remainingNumber;
  final String usedText;
  final String totalText;
  final double fraction;
}

Widget _connectedPill(bool connected) => Pill(
      label: connected ? 'Connected' : 'No data',
      dotColor: connected ? AppColors.good : AppColors.text3,
      textColor: connected ? AppColors.good : AppColors.text3,
      background: connected ? AppColors.goodSoft : AppColors.card,
    );

/// Large remaining-data card. [compact] = mobile.
class BalanceHeroCard extends StatelessWidget {
  const BalanceHeroCard({super.key, this.compact = false, this.showFooter = false});

  final bool compact;
  final bool showFooter;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<KerioBalance>(
      stream: bloc.kerioBalance,
      builder: (context, snapshot) {
        final v = _BalanceView(snapshot.data);
        return AppCard(
          gradient: AppGradients.card,
          radius: compact ? 18 : 16,
          padding: EdgeInsets.all(compact ? 18 : 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (compact)
                    const Overline('Remaining')
                  else
                    Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined,
                            size: 18, color: AppColors.accent),
                        const SizedBox(width: 9),
                        Text('Remaining data',
                            style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
                      ],
                    ),
                  _connectedPill(v.hasData),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(v.remainingNumber,
                      style: AppText.mono(compact ? 40 : 46, FontWeight.w700, AppColors.text,
                          height: 1)),
                  const SizedBox(width: 7),
                  Text('GB', style: AppText.ui(compact ? 16 : 18, FontWeight.w500, AppColors.text3)),
                ],
              ),
              SizedBox(height: compact ? 16 : 20),
              TrackBar(fraction: v.fraction, height: 8),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Used ${v.usedText}',
                      style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
                  Text('Total ${v.totalText}',
                      style: AppText.mono(12, FontWeight.w500, AppColors.text2)),
                ],
              ),
              if (showFooter) _footer(),
            ],
          ),
        );
      },
    );
  }

  Widget _footer() {
    return FutureBuilder<String?>(
      future: AppSharedPreferences.kerioIP,
      builder: (context, snapshot) {
        return Column(
          children: [
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.only(top: 16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.dns_outlined, size: 14, color: AppColors.text3),
                  const SizedBox(width: 9),
                  Text('Kerio Connect · ${snapshot.data ?? '—'}',
                      style: AppText.mono(12, FontWeight.w500, AppColors.text3)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Overview summary tile.
class BalanceSummaryCard extends StatelessWidget {
  const BalanceSummaryCard({super.key, this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<KerioBalance>(
      stream: bloc.kerioBalance,
      builder: (context, snapshot) {
        final v = _BalanceView(snapshot.data);
        return AppCard(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined,
                      size: 17, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text('Data balance', style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
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
                    Text(v.remainingNumber,
                        style: AppText.mono(30, FontWeight.w700, AppColors.text)),
                    const SizedBox(width: 5),
                    Text('GB', style: AppText.ui(14, FontWeight.w500, AppColors.text3)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TrackBar(fraction: v.fraction),
              const SizedBox(height: 9),
              Text('of ${v.totalText} · Kerio Connect',
                  style: AppText.ui(11, FontWeight.w400, AppColors.text3)),
            ],
          ),
        );
      },
    );
  }
}

/// Kerio credentials + login. Mirrors the old KerioLoginView wiring.
class KerioAccountCard extends StatefulWidget {
  const KerioAccountCard({super.key});

  @override
  State<KerioAccountCard> createState() => _KerioAccountCardState();
}

class _KerioAccountCardState extends State<KerioAccountCard> {
  final _ip = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _ip.text = await AppSharedPreferences.kerioIP ?? '';
    _username.text = await AppSharedPreferences.kerioUsername ?? '';
    _password.text = await AppSharedPreferences.kerioPassword ?? '';
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ip.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _openKerioPage() {
    final raw = _ip.text.trim();
    if (raw.isEmpty) return;
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'http://$raw');
    if (uri != null) launchUrl(uri);
  }

  Future<void> _login() async {
    if (_ip.text.isEmpty || _username.text.isEmpty || _password.text.isEmpty) {
      _snack('Please fill in all fields');
      return;
    }
    await AppSharedPreferences.setKerioIP(_ip.text);
    await AppSharedPreferences.setKerioUsername(_username.text);
    await AppSharedPreferences.setKerioPassword(_password.text);
    bloc.onKerioLoginClick();
    _snack('Login request sent');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.card2,
        content: Text(message, style: AppText.ui(13, FontWeight.w500, AppColors.text)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Overline('Kerio account'),
          const SizedBox(height: 14),
          _field(
            controller: _ip,
            hint: 'Kerio login page IP',
            mono: true,
            borderColor: AppColors.line2,
            trailing: GestureDetector(
              onTap: _openKerioPage,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFFE23B3B),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.shield, size: 14, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 11),
          _field(
            controller: _username,
            hint: 'Username',
            mono: true,
            leading: Icons.person_outline,
          ),
          const SizedBox(height: 11),
          _field(
            controller: _password,
            hint: 'Password',
            obscure: _obscure,
            leading: Icons.lock_outline,
            trailing: GestureDetector(
              onTap: () => setState(() => _obscure = !_obscure),
              child: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 15, color: AppColors.text3),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: AppButton(label: 'Login', onPressed: _login, expand: true, height: 48),
              ),
              const SizedBox(width: 14),
              _autoToggle(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _autoToggle() {
    return FutureBuilder<bool>(
      future: AppSharedPreferences.kerioAutoLogin,
      builder: (context, snapshot) {
        final value = snapshot.data ?? false;
        return Row(
          children: [
            Text('Auto', style: AppText.ui(13, FontWeight.w500, AppColors.text2)),
            const SizedBox(width: 9),
            AppSwitch(
              value: value,
              onChanged: (v) async {
                await AppSharedPreferences.setKerioAutoLogin(v);
                if (mounted) setState(() {});
              },
            ),
          ],
        );
      },
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    IconData? leading,
    Widget? trailing,
    bool obscure = false,
    bool mono = false,
    Color borderColor = AppColors.line,
  }) {
    return Container(
      height: 46,
      padding: EdgeInsets.only(left: 14, right: trailing != null ? 8 : 14),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            Icon(leading, size: 15, color: AppColors.text3),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              cursorColor: AppColors.accent,
              style: mono
                  ? AppText.mono(13, FontWeight.w500, AppColors.text)
                  : AppText.ui(13, FontWeight.w500, AppColors.text),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: AppText.ui(13, FontWeight.w400, AppColors.text3),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }
}
