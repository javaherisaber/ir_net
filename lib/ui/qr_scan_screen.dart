import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:ir_net/v2ray/qr_image.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'components.dart';
import 'theme.dart';

/// Full-screen camera QR scanner (Android/iOS). Pops with the code's text.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish(String text) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(text);
  }

  void _onDetect(BarcodeCapture capture) {
    for (final code in capture.barcodes) {
      final text = code.rawValue?.trim();
      if (text != null && text.isNotEmpty) {
        _finish(text);
        return;
      }
    }
  }

  Future<void> _fromImage() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', mimeTypes: ['image/*'], uniformTypeIdentifiers: ['public.image']),
    ]);
    if (file == null) return;
    final text = await decodeQrImage(await file.readAsBytes());
    if (text != null) {
      _finish(text);
    } else if (mounted) {
      setState(() => _message = 'No QR code found in that image');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cut = MediaQuery.sizeOf(context).shortestSide * 0.68;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'IRNet needs camera access to scan QR codes. Allow it in Settings, or pick an image instead.'
                      : 'The camera could not start (${error.errorCode.name}).',
                  textAlign: TextAlign.center,
                  style: AppText.ui(14, FontWeight.w500, AppColors.text),
                ),
              ),
            ),
          ),
          // Dimmed surround with a clear square to aim at.
          IgnorePointer(
            child: ColorFiltered(
              colorFilter: const ColorFilter.mode(Color(0x99000000), BlendMode.srcOut),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(decoration: const BoxDecoration(color: Colors.black, backgroundBlendMode: BlendMode.dstOut)),
                  Center(
                    child: Container(
                      width: cut,
                      height: cut,
                      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(22)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Center(
            child: IgnorePointer(
              child: Container(
                width: cut,
                height: cut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconActionButton(icon: Icons.close, onPressed: () => Navigator.of(context).pop()),
                      const SizedBox(width: 12),
                      Text('Scan a config QR code', style: AppText.ui(16, FontWeight.w700, AppColors.text)),
                      const Spacer(),
                      IconActionButton(icon: Icons.flash_on, onPressed: _controller.toggleTorch),
                    ],
                  ),
                  const Spacer(),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_message!,
                          textAlign: TextAlign.center, style: AppText.ui(13, FontWeight.w500, AppColors.warn)),
                    ),
                  Center(
                    child: AppButton(
                      label: 'Choose an image instead',
                      icon: Icons.image_outlined,
                      kind: AppButtonKind.outline,
                      height: 42,
                      onPressed: _fromImage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
