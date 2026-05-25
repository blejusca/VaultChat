import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/secure_chat_theme.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  late final MobileScannerController _controller;
  bool _hasResult = false;
  bool _isReturning = false;
  bool _isCameraStopped = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  Future<void> _stopCameraSafely() async {
    if (_isCameraStopped) return;
    _isCameraStopped = true;
    try {
      await _controller.stop();
    } catch (_) {
      // Best-effort only. Camera may already be stopped by Android/plugin.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_hasResult || _isReturning) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _returnResult(value);
      return;
    }
  }

  Future<void> _returnResult(String value) async {
    if (_hasResult || _isReturning) return;
    setState(() {
      _hasResult = true;
      _isReturning = true;
    });

    // Oprim camera înainte de a părăsi ecranul. Pe Samsung/Nokia,
    // pop-ul imediat al ecranului cu preview camera poate lăsa aplicația
    // într-un ecran negru.
    await _stopCameraSafely();
    await Future<void>.delayed(const Duration(milliseconds: 350));

    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  Future<bool> _handleBack() async {
    await _stopCameraSafely();
    return true;
  }

  Future<void> _toggleTorch() async {
    if (_isReturning) return;
    await _controller.toggleTorch();
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    if (_isReturning) return;
    await _controller.switchCamera();
    if (mounted) setState(() {});
  }

  Future<void> _cancelScan() async {
    if (_isReturning) return;
    setState(() => _isReturning = true);
    await _stopCameraSafely();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: SecureChatColors.deepNavy,
        appBar: AppBar(
          title: const Text('Scan QR'),
          backgroundColor: SecureChatColors.deepNavy,
          foregroundColor: SecureChatColors.text,
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _cancelScan,
          ),
          actions: [
            IconButton(
              tooltip: 'Flashlight',
              onPressed: _isReturning ? null : _toggleTorch,
              icon: const Icon(Icons.flashlight_on_rounded),
            ),
            IconButton(
              tooltip: 'Switch camera',
              onPressed: _isReturning ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch_rounded),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (!_isCameraStopped)
              MobileScanner(
                controller: _controller,
                onDetect: _handleCapture,
              )
            else
              const ColoredBox(
                color: SecureChatColors.deepNavy,
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.20),
                  ),
                ),
              ),
            ),
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isReturning
                        ? SecureChatColors.warning
                        : SecureChatColors.turquoise,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (_isReturning
                              ? SecureChatColors.warning
                              : SecureChatColors.turquoise)
                          .withValues(alpha: 0.25),
                      blurRadius: 22,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 42 + MediaQuery.of(context).padding.bottom,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: SecureChatColors.card.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: SecureChatColors.borderSoft.withValues(alpha: 0.70),
                  ),
                ),
                child: Text(
                  _isReturning
                      ? 'Code detected. Closing camera...'
                      : 'Scan the VaultChat QR code from the other phone.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: SecureChatColors.text,
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
