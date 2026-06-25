import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/platform.dart';

import 'components.dart';
import 'connection_widgets.dart';
import 'leak_widgets.dart';
import 'sections.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// Top-level chrome: desktop gets a sidebar, mobile gets a bottom nav bar.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformUtils.isMobile ? const _MobileShell() : const _DesktopShell();
  }
}

class _NavItem {
  const _NavItem(this.title, this.icon, {this.showChip = true});
  final String title;
  final IconData icon;
  final bool showChip;
}

const _navItems = <_NavItem>[
  _NavItem('Overview', Icons.grid_view_rounded),
  _NavItem('Leak detection', Icons.verified_user_outlined),
  _NavItem('Connection', Icons.public),
  _NavItem('Data balance', Icons.account_balance_wallet_outlined),
  _NavItem('Speed test', Icons.speed),
  _NavItem('Settings', Icons.settings_outlined, showChip: false),
];

// ───────────────────────────── Desktop ─────────────────────────────

class _DesktopShell extends StatefulWidget {
  const _DesktopShell();

  @override
  State<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<_DesktopShell> {
  int _index = 0;

  void _select(int index) => setState(() => _index = index);

  Widget _sectionBody(int index) {
    switch (index) {
      case 0:
        return OverviewSection(
          onOpenLeaks: () => _select(1),
          onOpenBalance: () => _select(3),
          onOpenSpeed: () => _select(4),
        );
      case 1:
        return const LeakSection();
      case 2:
        return const ConnectionSection();
      case 3:
        return const BalanceSection();
      case 4:
        return const SpeedSection();
      default:
        return const SettingsView();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _navItems[_index];
    return Scaffold(
      body: Row(
        children: [
          _sidebar(),
          Expanded(
            child: Column(
              children: [
                _header(item),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: _sectionBody(_index),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() {
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(right: BorderSide(color: AppColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 6, 8, 18),
            child: BrandMark(),
          ),
          for (var i = 0; i < _navItems.length; i++) _navTile(i),
          const Spacer(),
          _statusPill(),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Refresh',
                  icon: Icons.refresh,
                  kind: AppButtonKind.outline,
                  height: 38,
                  expand: true,
                  onPressed: bloc.onRefreshButtonClick,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  label: 'Exit',
                  icon: Icons.logout,
                  kind: AppButtonKind.danger,
                  height: 38,
                  expand: true,
                  onPressed: bloc.onExitClick,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _navTile(int i) {
    final item = _navItems[i];
    final active = i == _index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: active ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () => setState(() => _index = i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: active ? AppColors.accent : AppColors.text2),
                const SizedBox(width: 12),
                Text(
                  item.title,
                  style: AppText.ui(13, active ? FontWeight.w600 : FontWeight.w500,
                      active ? AppColors.accent : AppColors.text2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    return StreamBuilder(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final state = vpnStateOf(ConnectionInfo.fromJson(snapshot.data));
        final (word, dot) = switch (state) {
          VpnState.protected => ('Protected', AppColors.good),
          VpnState.exposed => ('Not protected', AppColors.bad),
          VpnState.checking => ('Checking', AppColors.warn),
        };
        final platform =
            Platform.isWindows ? 'Windows' : (Platform.isMacOS ? 'macOS' : 'Linux');
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              StatusDot(dot),
              const SizedBox(width: 9),
              Text('$word · $platform',
                  style: AppText.ui(11, FontWeight.w500, AppColors.text2)),
            ],
          ),
        );
      },
    );
  }

  Widget _header(_NavItem item) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Text(item.title, style: AppText.ui(20, FontWeight.w700, AppColors.text)),
          const Spacer(),
          if (item.showChip) const ConnectionChip(),
        ],
      ),
    );
  }
}

// ───────────────────────────── Mobile ─────────────────────────────

class _MobileTab {
  const _MobileTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _mobileTabs = <_MobileTab>[
  _MobileTab('Home', Icons.grid_view_rounded),
  _MobileTab('Leaks', Icons.verified_user_outlined),
  _MobileTab('Speed', Icons.speed),
  _MobileTab('Balance', Icons.account_balance_wallet_outlined),
];

class _MobileShell extends StatefulWidget {
  const _MobileShell();

  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  int _index = 0;

  void _openConnection() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _MobileConnectionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            _homeTab(),
            _tab('Leak detection', const LeakSection(compact: true),
                trailing: const _LeakOkPill()),
            _tab('Speed test', const SpeedSection(compact: true)),
            _tab('Data balance', const BalanceSection(compact: true)),
          ],
        ),
      ),
      bottomNavigationBar: _bottomNav(),
    );
  }

  Widget _homeTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: BrandMark(size: 24, tagline: 'freedom does not have a price'),
              ),
              const SizedBox(width: 12),
              AppButton(
                label: 'Refresh',
                icon: Icons.refresh,
                kind: AppButtonKind.outline,
                height: 34,
                onPressed: bloc.onRefreshButtonClick,
              ),
              const SizedBox(width: 8),
              IconActionButton(
                  icon: Icons.logout, danger: true, onPressed: bloc.onExitClick),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: OverviewSection(
              compact: true,
              onOpenConnection: _openConnection,
              onOpenLeaks: () => setState(() => _index = 1),
              onOpenSpeed: () => setState(() => _index = 2),
              onOpenBalance: () => setState(() => _index = 3),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tab(String title, Widget body, {Widget? trailing}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              // Returns to Home/Overview (these screens are opened from the
              // Overview cards as well as the bottom nav).
              IconActionButton(
                icon: Icons.arrow_back,
                onPressed: () => setState(() => _index = 0),
              ),
              const SizedBox(width: 12),
              Text(title, style: AppText.ui(19, FontWeight.w700, AppColors.text)),
              if (trailing != null) ...[const Spacer(), trailing],
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _bottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _mobileTabs.length; i++) _navButton(i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navButton(int i) {
    final tab = _mobileTabs[i];
    final active = i == _index;
    final color = active ? AppColors.accent : AppColors.text3;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _index = i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab.icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(tab.label, style: AppText.ui(9.5, FontWeight.w500, color)),
          ],
        ),
      ),
    );
  }
}

class _LeakOkPill extends StatelessWidget {
  const _LeakOkPill();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: bloc.leakChecklist,
      builder: (context, snapshot) {
        final counts = LeakCounts.from(snapshot.data ?? const []);
        final allOk = counts.unreachable == 0 && counts.total > 0;
        return Pill(
          label: '${counts.reachable} / ${counts.total} OK',
          dotColor: allOk ? AppColors.good : AppColors.warn,
          textColor: allOk ? AppColors.good : AppColors.warn,
          background: allOk ? AppColors.goodSoft : const Color(0x1FFBBF24),
        );
      },
    );
  }
}

class _MobileConnectionScreen extends StatelessWidget {
  const _MobileConnectionScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(
                children: [
                  IconActionButton(
                      icon: Icons.arrow_back, onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(width: 12),
                  Text('Connection', style: AppText.ui(17, FontWeight.w700, AppColors.text)),
                ],
              ),
            ),
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: ConnectionSection(compact: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
