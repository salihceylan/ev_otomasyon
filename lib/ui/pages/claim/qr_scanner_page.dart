import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme/app_theme.dart';
import '../../widgets/settings/accent_button.dart';
import 'scanner_frame.dart';

/// Taranan ham metni doğrular: `null` = kabul (sayfa kapanır ve metni döndürür); metin = reddet
/// (Türkçe neden SnackBar ile gösterilir, **tarama sürer**).
typedef QrCodeValidator = String? Function(String raw);

/// Kamera ile QR tarama sayfası. Kabul edilen ham metni `Navigator.pop<String>` ile döndürür
/// (yönlendirme `QrRouter` ile çağıranda yapılır). Ham karekod içeriği (PIN, davet kodu, Wi-Fi
/// parolası içerebilir) **hiçbir yere yazdırılmaz**.
///
/// * [validator]: geçersiz karekodlar (ör. WEP Wi-Fi karekodu) taramayı bitirmez; neden gösterilir.
/// * Çoklu algılamada yalnızca **bir** kez kapanır.
/// * Mobil olmayan platformda (web/Windows/Linux) çökmez; açık "desteklenmiyor" ekranı gösterir.
/// * Kamera izni reddedilirse platforma uygun ayar yönergesi gösterilir.
class QrScannerPage extends StatefulWidget {
  final VoidCallback? onManualFallback;
  final String hintText;
  final String title;
  final QrCodeValidator? validator;

  /// Yalnızca testlerde: hazır denetleyici.
  @visibleForTesting
  final MobileScannerController? controller;

  /// Yalnızca testlerde: platform desteğini zorla (`null` = gerçek platform).
  @visibleForTesting
  final bool? supportedOverride;

  const QrScannerPage({
    super.key,
    this.onManualFallback,
    this.hintText = 'Pano kapağındaki karekodu çerçeveye hizalayın',
    this.title = 'Karekod Tara',
    this.validator,
    this.controller,
    this.supportedOverride,
  });

  /// Kamera ile tarama bu platformda destekleniyor mu? (Android, iOS, macOS.)
  static bool get platformSupportsCamera {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  State<QrScannerPage> createState() => QrScannerPageState();
}

class QrScannerPageState extends State<QrScannerPage> {
  MobileScannerController? _controller;
  bool _ownsController = false;

  /// İlk kabulden sonra gelen algılamalar yok sayılır (tek pop).
  bool _handled = false;

  /// Kod kabul edildi: tarayıcı çerçevesi ✓ gösterir (sayfa kapanırken; kapanışı geciktirmez).
  bool _accepted = false;
  int? _lastRejectedHash;
  DateTime? _lastRejectedAt;

  bool get _supported => widget.supportedOverride ?? QrScannerPage.platformSupportsCamera;

  @override
  void initState() {
    super.initState();
    if (_supported) {
      _controller = widget.controller ??
          MobileScannerController(
            detectionSpeed: DetectionSpeed.noDuplicates,
            facing: CameraFacing.back,
            formats: const [BarcodeFormat.qrCode],
          );
      _ownsController = widget.controller == null;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  /// Testlerde kameranın yakaladığı bir ham metni taklit eder. `true`: kabul edildi (sayfa kapandı).
  @visibleForTesting
  bool debugHandleRaw(String raw) => _accept(raw.trim());

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      if (_accept(raw)) break;
    }
  }

  bool _accept(String raw) {
    if (_handled || !mounted || raw.isEmpty) return false;
    String? error;
    try {
      error = widget.validator?.call(raw);
    } catch (_) {
      error = 'Karekod doğrulanamadı. Lütfen tekrar deneyin.';
    }
    if (error != null) {
      _showRejection(error, raw);
      return false;
    }
    _handled = true; // senkron: ikinci algılama pop'tan önce gelse bile yok sayılır
    setState(() => _accepted = true);
    Navigator.of(context).pop<String>(raw);
    return true;
  }

  void _showRejection(String message, String raw) {
    final now = DateTime.now();
    final hash = raw.hashCode;
    final last = _lastRejectedAt;
    if (_lastRejectedHash == hash && last != null && now.difference(last) < const Duration(seconds: 2)) {
      return; // aynı geçersiz kod arka arkaya bildirilmez
    }
    _lastRejectedHash = hash;
    _lastRejectedAt = now;
    _snack(message);
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('snack_scan_error'),
          content: Text(message),
          // Beyaz yazılı dolgu tonu (ham kırmızı zeminde beyaz metin ≈3.8:1 idi).
          backgroundColor: AppTheme.filledAccent(AppTheme.accentRed),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller?.toggleTorch();
    } catch (_) {
      _snack('Flaş açılamadı veya bu cihazda kullanılamıyor.');
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _controller?.switchCamera();
    } catch (_) {
      _snack('Kamera değiştirilemedi.');
    }
  }

  Future<void> _restartCamera() async {
    try {
      await _controller?.stop();
      await _controller?.start();
    } catch (_) {
      _snack('Kamera yeniden başlatılamadı. Uygulama izinlerini kontrol edin.');
    }
  }

  void _manualFallback() {
    final callback = widget.onManualFallback;
    Navigator.of(context).pop();
    callback?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return _buildUnsupported(context);
    final controller = _controller!;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: controller,
            builder: (context, state, _) {
              final torch = state.torchState;
              final unavailable = torch == TorchState.unavailable;
              final on = torch == TorchState.on || torch == TorchState.auto;
              return IconButton(
                key: const Key('btn_torch'),
                icon: Icon(
                  torch == TorchState.auto
                      ? Icons.flash_auto_rounded
                      : (on ? Icons.flash_on_rounded : Icons.flash_off_rounded),
                  color: unavailable ? Colors.white38 : (on ? AppTheme.accentAmber : Colors.white),
                ),
                tooltip: unavailable ? 'Flaş bu cihazda kullanılamıyor' : (on ? 'Flaşı kapat' : 'Flaşı aç'),
                onPressed: unavailable ? null : _toggleTorch,
              );
            },
          ),
          IconButton(
            key: const Key('btn_switch_camera'),
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white),
            tooltip: 'Kamera Değiştir',
            onPressed: _switchCamera,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final layout = constraints.biggest;
          final boxSize = (layout.shortestSide * 0.72).clamp(220.0, 320.0);
          // Tarama penceresi: yalnızca vizör çerçevesi içindeki karekodlar okunur.
          final scanWindow = Rect.fromCenter(
            center: layout.center(Offset.zero),
            width: boxSize,
            height: boxSize,
          );
          return Stack(
            children: [
              Positioned.fill(
                child: MobileScanner(
                  controller: controller,
                  onDetect: _onDetect,
                  scanWindow: scanWindow,
                  errorBuilder: (context, error) => _buildCameraError(context, error),
                ),
              ),
              _buildScannerOverlay(context, boxSize),
              Positioned(
                left: 20,
                right: 20,
                bottom: 36,
                child: _buildHintAndFallback(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHintAndFallback() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner, color: AppTheme.primaryBlueLight, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.hintText,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (widget.onManualFallback != null)
          TextButton.icon(
            key: const Key('btn_manual_entry'),
            onPressed: _manualFallback,
            icon: const Icon(Icons.keyboard_alt_outlined, color: AppTheme.primaryBlueLight),
            label: const Text(
              'Kameram Çalışmıyor / Kodu Elle Gir',
              style: TextStyle(
                color: AppTheme.primaryBlueLight,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: AppTheme.surfaceDark.withValues(alpha: 0.8),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
          ),
      ],
    );
  }

  /// Kamera hatası: ham hata kodu gösterilmez; izin reddi için platforma uygun yönerge verilir.
  Widget _buildCameraError(BuildContext context, MobileScannerException error) {
    final String title;
    final String message;
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        title = 'Kamera İzni Gerekli';
        message = _permissionHelp();
      case MobileScannerErrorCode.unsupported:
        title = 'Kamera Desteklenmiyor';
        message = 'Bu cihazda kamera ile karekod tarama desteklenmiyor. Kodu elle girebilirsiniz.';
      default:
        title = 'Kamera Başlatılamadı';
        message = 'Kamera açılamadı. Başka bir uygulamanın kamerayı kullanmadığından emin olup tekrar deneyin.';
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt_outlined, color: AppTheme.accentRed, size: 54),
              const SizedBox(height: 16),
              Text(
                title,
                key: const Key('scanner_error_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                key: const Key('scanner_error_message'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              if (error.errorCode != MobileScannerErrorCode.unsupported)
                ElevatedButton.icon(
                  key: const Key('btn_scanner_retry'),
                  onPressed: _restartCamera,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Tekrar Dene'),
                  style: accentButtonStyle(null),
                ),
              if (widget.onManualFallback != null) ...[
                const SizedBox(height: 10),
                TextButton.icon(
                  key: const Key('btn_scanner_error_manual'),
                  onPressed: _manualFallback,
                  icon: const Icon(Icons.keyboard_alt_outlined),
                  label: const Text('Kodu Elle Gir'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _permissionHelp() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return 'Karekod okumak için kamera izni verilmedi. Telefonunuzun Ayarlar > Ev Otomasyon > Kamera '
            'bölümünden izni açıp bu ekrana dönün.';
      default:
        return 'Karekod okumak için kamera izni verilmedi. Telefonunuzun Ayarlar > Uygulamalar > Ev Otomasyon > '
            'İzinler > Kamera bölümünden izni açıp bu ekrana dönün.';
    }
  }

  Widget _buildUnsupported(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: AppTheme.accentAmber, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Karekod Tarama Desteklenmiyor',
                key: Key('scanner_unsupported_title'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Bu platformda (web / masaüstü) kamera ile karekod okunamıyor. Bilgileri elle girebilir '
                'ya da mobil uygulamadan tarayabilirsiniz.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              if (widget.onManualFallback != null)
                ElevatedButton.icon(
                  key: const Key('btn_manual_entry'),
                  onPressed: _manualFallback,
                  icon: const Icon(Icons.keyboard_alt_outlined),
                  label: const Text('Kodu Elle Gir'),
                  style: accentButtonStyle(null),
                ),
              TextButton(
                key: const Key('btn_scanner_back'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Geri'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScannerOverlay(BuildContext context, double boxSize) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Çerçeve dışı hafif karartma (ortası deliktir).
          CustomPaint(painter: _DimPainter(hole: boxSize)),
          Center(child: ScannerFrame(size: boxSize, accepted: _accepted)),
        ],
      ),
    );
  }
}

/// Tarama penceresi dışını karartır; merkezde yuvarlak köşeli kare delik bırakır.
class _DimPainter extends CustomPainter {
  const _DimPainter({required this.hole});

  final double hole;

  @override
  void paint(Canvas canvas, Size size) {
    final window = RRect.fromRectAndRadius(
      Rect.fromCenter(center: size.center(Offset.zero), width: hole, height: hole),
      const Radius.circular(22),
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(window);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.42));
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole;
}
