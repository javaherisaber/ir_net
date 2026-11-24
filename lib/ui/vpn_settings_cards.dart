part of 'vpn_widgets.dart';

Widget _toggleRow(String title, String subtitle, bool value, ValueChanged<bool>? onChanged) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: _sectionTitle(title, subtitle: subtitle, trailing: AppSwitch(value: value, onChanged: onChanged)),
    );

/// Connect at launch, reconnect, notifications.
class _BehaviourCard extends StatelessWidget {
  const _BehaviourCard({required this.state, required this.compact});
  final V2rayState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    return AppCard(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 18, 11, compact ? 16 : 18, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toggleRow(
            'Connect when IRNet starts',
            'With "Launch at startup" in IRNet\'s settings, the VPN comes up when you log in.',
            s.connectOnLaunch,
            bloc.v2ray.setConnectOnLaunch,
          ),
          const Divider(height: 1, color: AppColors.line),
          _toggleRow(
            'Reconnect automatically',
            'Checks the connection every minute and after sleep or a network change, and reconnects when it '
                'stops working or drops.',
            s.autoReconnect,
            bloc.v2ray.setAutoReconnect,
          ),
          const Divider(height: 1, color: AppColors.line),
          _toggleRow(
            'Notifications',
            'When the VPN drops or reconnects, and when a subscription is about to expire or run out of data.',
            s.notify,
            bloc.v2ray.setNotify,
          ),
        ],
      ),
    );
  }
}

/// One tap: Iranian websites and IPs skip the VPN.
class _IranCard extends StatelessWidget {
  const _IranCard({required this.state, required this.compact});
  final V2rayState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final on = state.settings.iranDirect;
    final status = state.iranRules;
    final String line;
    if (status.updating) {
      line = 'Downloading the Iran rule lists…';
    } else if (status.updatedAt != null) {
      line = 'Lists updated ${_ago(status.updatedAt!)} · refreshed weekly';
    } else {
      line = 'Downloads about 2 MB of rule lists (Chocolate4U/Iran-v2ray-rules) the first time.';
    }
    return AppCard(
      padding: EdgeInsets.all(compact ? 16 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(
            'Iranian sites go direct',
            subtitle: 'Iranian websites and IP addresses (banks, government services, shops) skip the VPN: they '
                'often refuse foreign IPs, and it saves VPN data.',
            trailing: status.updating
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : AppSwitch(value: on, onChanged: bloc.v2ray.setIranDirect),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(on && status.error == null ? Icons.check_circle_outline : Icons.info_outline,
                  size: 13, color: on && status.error == null ? AppColors.good : AppColors.text3),
              const SizedBox(width: 6),
              Expanded(child: Text(line, style: AppText.ui(11, FontWeight.w400, AppColors.text3))),
              if (on && !status.updating)
                TextButton(
                  onPressed: () async {
                    final error = await bloc.v2ray.updateIranRules();
                    if (context.mounted) _toast(context, error ?? 'Iran rule lists updated');
                  },
                  child: Text('Update now', style: AppText.ui(11.5, FontWeight.w600, AppColors.text2)),
                ),
            ],
          ),
          if (status.error != null) ...[
            const SizedBox(height: 8),
            _Note(status.error!, color: AppColors.warn),
          ],
        ],
      ),
    );
  }
}

/// TLS handshake fragmentation.
class _FragmentCard extends StatefulWidget {
  const _FragmentCard({required this.state, required this.compact});
  final V2rayState state;
  final bool compact;

  @override
  State<_FragmentCard> createState() => _FragmentCardState();
}

class _FragmentCardState extends State<_FragmentCard> {
  late final _length = TextEditingController(text: widget.state.settings.fragmentOptions.length);
  late final _delay = TextEditingController(text: widget.state.settings.fragmentOptions.delay);
  bool _advanced = false;

  static final _range = RegExp(r'^\d{1,5}(-\d{1,5})?$');

  @override
  void dispose() {
    _length.dispose();
    _delay.dispose();
    super.dispose();
  }

  bool get _valid =>
      _range.hasMatch(_length.text.trim()) &&
      _range.hasMatch(_delay.text.trim()) &&
      !_length.text.trim().startsWith('0');

  @override
  Widget build(BuildContext context) {
    final s = widget.state.settings;
    final changed = _length.text.trim() != s.fragmentOptions.length || _delay.text.trim() != s.fragmentOptions.delay;
    InputDecoration deco(String label) => InputDecoration(
          isDense: true,
          labelText: label,
          labelStyle: AppText.ui(11, FontWeight.w500, AppColors.text3),
          filled: true,
          fillColor: AppColors.bg,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9), borderSide: const BorderSide(color: AppColors.line2)),
        );
    return AppCard(
      padding: EdgeInsets.all(widget.compact ? 16 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(
            'Fragment (anti-filtering)',
            subtitle: 'Splits the TLS handshake into small pieces so filters can\'t read the server name, which '
                'often gets TLS and REALITY configs through. Turn it off if a config stops working.',
            trailing: AppSwitch(value: s.fragment, onChanged: bloc.v2ray.setFragment),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _advanced = !_advanced),
              icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 16, color: AppColors.text3),
              label: Text('Piece size ${s.fragmentOptions.length} bytes · delay ${s.fragmentOptions.delay} ms',
                  style: AppText.ui(11, FontWeight.w500, AppColors.text3)),
            ),
          ),
          if (_advanced) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _length,
                    onChanged: (_) => setState(() {}),
                    style: AppText.mono(12.5, FontWeight.w500, AppColors.text),
                    decoration: deco('Piece size (bytes)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _delay,
                    onChanged: (_) => setState(() {}),
                    style: AppText.mono(12.5, FontWeight.w500, AppColors.text),
                    decoration: deco('Delay (ms)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _valid
                        ? 'Ranges like 100-200. Smaller pieces hide more but connect slower.'
                        : 'Use a number or a range like 100-200.',
                    style: AppText.ui(11, FontWeight.w400, _valid ? AppColors.text3 : AppColors.warn),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    _length.text = FragmentOptions.defaults.length;
                    _delay.text = FragmentOptions.defaults.delay;
                    setState(() {});
                  },
                  child: Text('Defaults', style: AppText.ui(11.5, FontWeight.w600, AppColors.text2)),
                ),
                AppButton(
                  label: 'Save',
                  height: 32,
                  onPressed: changed && _valid
                      ? () => bloc.v2ray
                          .setFragmentOptions(FragmentOptions(length: _length.text.trim(), delay: _delay.text.trim()))
                      : null,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Apps that skip the VPN (per-app split tunnelling).
class _AppsCard extends StatefulWidget {
  const _AppsCard({required this.state, required this.compact});
  final V2rayState state;
  final bool compact;

  @override
  State<_AppsCard> createState() => _AppsCardState();
}

class _AppsCardState extends State<_AppsCard> {
  List<AppChoice> _known = const [];

  @override
  void initState() {
    super.initState();
    // Labels for the chosen apps (Android packages, macOS bundles).
    AppLister.list().then((apps) {
      if (mounted) setState(() => _known = apps);
    });
  }

  bool get _android => !kIsWeb && Platform.isAndroid;

  Future<void> _choose() async {
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AppPickerDialog(selected: widget.state.settings.bypassApps, apps: _known),
    );
    if (chosen != null) await bloc.v2ray.setBypassApps(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.state.settings.bypassApps;
    final tunnelOnly = widget.state.mode == VpnMode.proxy;
    return AppCard(
      padding: EdgeInsets.all(widget.compact ? 16 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(
            'Apps that skip the VPN',
            subtitle: _android
                ? 'These apps use your normal connection (e.g. Iranian banking apps). Applies in Tunnel mode.'
                : 'These apps use your normal connection (e.g. Iranian banking apps). Works for all their traffic '
                    'in Tunnel mode; in Proxy mode apps that ignore the proxy go direct anyway.',
            trailing: AppButton(
              label: 'Choose',
              icon: Icons.apps,
              kind: AppButtonKind.outline,
              height: 34,
              onPressed: _choose,
            ),
          ),
          if (apps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final app in apps)
                  InputChip(
                    label:
                        Text(AppLister.labelFor(app, _known), style: AppText.ui(11.5, FontWeight.w500, AppColors.text)),
                    backgroundColor: AppColors.card2,
                    side: const BorderSide(color: AppColors.line2),
                    deleteIconColor: AppColors.text3,
                    onDeleted: () => bloc.v2ray.setBypassApps(apps.where((a) => a != app).toList()),
                    tooltip: app,
                  ),
              ],
            ),
          ],
          if (apps.isNotEmpty && tunnelOnly && _android) ...[
            const SizedBox(height: 10),
            const _Note('You\'re in Proxy mode, where only apps set to use the proxy go through the VPN anyway.',
                color: AppColors.text3),
          ],
        ],
      ),
    );
  }
}

class _AppPickerDialog extends StatefulWidget {
  const _AppPickerDialog({required this.selected, required this.apps});
  final List<String> selected;
  final List<AppChoice> apps;

  @override
  State<_AppPickerDialog> createState() => _AppPickerDialogState();
}

class _AppPickerDialogState extends State<_AppPickerDialog> {
  late final Set<String> _chosen = {...widget.selected};
  late List<AppChoice> _apps = widget.apps;
  String _query = '';
  final _custom = TextEditingController();

  bool get _desktop => !kIsWeb && !Platform.isAndroid && !Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (_apps.isEmpty) {
      AppLister.list().then((apps) {
        if (mounted) setState(() => _apps = apps);
      });
    }
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _addCustom() {
    final v = _custom.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _chosen.add(v);
      _custom.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    // Chosen entries not in the list (typed by hand) stay visible and removable.
    final extra = _chosen.where((v) => !_apps.any((a) => a.value == v)).map((v) => AppChoice(AppLister.labelFor(v), v));
    final shown = [...extra, ..._apps]
        .where((a) => q.isEmpty || a.label.toLowerCase().contains(q) || a.value.toLowerCase().contains(q))
        .toList();
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line2)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Apps that skip the VPN', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
              const SizedBox(height: 10),
              TextField(
                onChanged: (v) => setState(() => _query = v.trim()),
                style: AppText.ui(13, FontWeight.w500, AppColors.text),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.text3),
                  hintText: 'Search apps',
                  hintStyle: AppText.ui(13, FontWeight.w400, AppColors.text3),
                  filled: true,
                  fillColor: AppColors.bg,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.line2)),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(_apps.isEmpty ? 'Loading apps…' : 'No app matches',
                            textAlign: TextAlign.center, style: AppText.ui(12, FontWeight.w400, AppColors.text3)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final app = shown[i];
                          return CheckboxListTile(
                            dense: true,
                            value: _chosen.contains(app.value),
                            onChanged: (on) =>
                                setState(() => on == true ? _chosen.add(app.value) : _chosen.remove(app.value)),
                            title: Text(app.label, style: AppText.ui(13, FontWeight.w500, AppColors.text)),
                            subtitle: app.label == app.value
                                ? null
                                : Text(app.value,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.mono(10, FontWeight.w400, AppColors.text3)),
                          );
                        },
                      ),
              ),
              if (_desktop) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _custom,
                        onSubmitted: (_) => _addCustom(),
                        style: AppText.mono(12, FontWeight.w500, AppColors.text),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Or a process name or path, e.g. Telegram',
                          hintStyle: AppText.ui(12, FontWeight.w400, AppColors.text3),
                          filled: true,
                          fillColor: AppColors.bg,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: AppColors.line2)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppButton(label: 'Add', height: 34, kind: AppButtonKind.outline, onPressed: _addCustom),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('${_chosen.length} chosen', style: AppText.ui(11.5, FontWeight.w500, AppColors.text3)),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 6),
                  AppButton(label: 'Save', height: 36, onPressed: () => Navigator.pop(context, _chosen.toList())),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
