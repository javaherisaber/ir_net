part of 'vpn_widgets.dart';

/// Shows [profile] as a QR code and link (and, for WireGuard, as a config
/// for the WireGuard apps) to pass it to another device or person.
Future<void> showShareDialog(BuildContext context, V2rayProfile profile) =>
    showDialog(context: context, builder: (_) => _ShareDialog(profile: profile));

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.profile});
  final V2rayProfile profile;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  /// WireGuard: show the .conf (for WireGuard apps) instead of the link.
  bool _conf = false;

  bool get _wireGuard => widget.profile.protocol == V2rayProtocol.wireguard;

  String get _text => _conf ? ShareLinkParser.wireGuardConf(widget.profile) : widget.profile.link;

  Future<void> _saveConf() async {
    final name = '${widget.profile.name.replaceAll(RegExp(r'[^\w\- ]'), '').trim().replaceAll(' ', '-')}.conf';
    try {
      final file = await const FileDelivery().deliver(
        name.length > 5 ? name : 'wireguard.conf',
        Uint8List.fromList(utf8.encode(ShareLinkParser.wireGuardConf(widget.profile))),
        mimeType: 'text/plain',
        subject: widget.profile.name,
      );
      if (mounted && !file.shared) _toast(context, 'Saved to ${file.path}');
    } catch (e) {
      if (mounted) _toast(context, 'Could not save the file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), side: const BorderSide(color: AppColors.line2)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Share “${widget.profile.name}”',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.ui(16, FontWeight.w700, AppColors.text)),
              const SizedBox(height: 4),
              Text(
                'Scan it with IRNet or another V2Ray / WireGuard app, or send the link.',
                style: AppText.ui(11.5, FontWeight.w400, AppColors.text3),
              ),
              if (_wireGuard) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final (conf, label) in const [(false, 'Link'), (true, 'WireGuard app')])
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: conf ? 0 : 6),
                          child: _ExampleToggle(
                            label: label,
                            active: _conf == conf,
                            onTap: () => setState(() => _conf = conf),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Center(child: QrCodeView(data: text, size: 240)),
              const SizedBox(height: 14),
              Container(
                constraints: const BoxConstraints(maxHeight: 110),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.line2),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(text, style: AppText.mono(10.5, FontWeight.w400, AppColors.text2, height: 1.4)),
                ),
              ),
              const SizedBox(height: 10),
              const _Note(
                  'Anyone with this config can use it (and your account\'s data). Share it only with people you trust.',
                  color: AppColors.warn),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_wireGuard)
                    AppButton(
                      label: 'Save .conf',
                      icon: Icons.download_outlined,
                      kind: AppButtonKind.outline,
                      height: 36,
                      onPressed: _saveConf,
                    ),
                  AppButton(
                    label: _conf ? 'Copy config' : 'Copy link',
                    icon: Icons.copy,
                    height: 36,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) _toast(context, _conf ? 'Config copied' : 'Link copied');
                    },
                  ),
                  AppButton(
                    label: 'Close',
                    kind: AppButtonKind.outline,
                    height: 36,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A two-way pill toggle.
class _ExampleToggle extends StatelessWidget {
  const _ExampleToggle({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: active ? const Color(0x6633D6C6) : AppColors.line2),
          ),
          child: Text(label, style: AppText.ui(12, FontWeight.w600, active ? AppColors.accent : AppColors.text2)),
        ),
      ),
    );
  }
}

/// A QR code of [data] on a white tile (scanners need the contrast).
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, this.size = 220});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    QRCode? code;
    try {
      code = Encoder.encode(data, ErrorCorrectionLevel.l);
    } catch (_) {}
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: code?.matrix == null
          ? Center(
              child: Text('Too long for a QR code; copy the link instead.',
                  textAlign: TextAlign.center, style: AppText.ui(12, FontWeight.w500, Colors.black54)),
            )
          : CustomPaint(painter: _QrPainter(code!), size: Size.infinite),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code);
  final QRCode code;

  @override
  void paint(Canvas canvas, Size size) {
    final matrix = code.matrix!;
    final cell = size.width / matrix.width;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) == 1) {
          // A hair of overlap so cells don't show seams when scaled.
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.code != code;
}
