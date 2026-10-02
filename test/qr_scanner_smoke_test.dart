import 'package:ev_otomasyon/ui/pages/claim/qr_scanner_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'ui/e2_support.dart';

/// Karekod tarayıcı: doğrulayıcı (geçersiz kodda tarama sürer), tek pop, tarama penceresi, flaş
/// durumu, kamera izni reddi yönergesi, mobil olmayan platformda çökmeyen "desteklenmiyor" ekranı.
/// Kamerayı başlatmayan (platform kanalı yok) sahte denetleyici: çağrılar sayılır, hata enjekte edilir.
class _FakeScannerController extends MobileScannerController {
  _FakeScannerController() : super(autoStart: false);

  bool failTorch = false;
  bool failRestart = false;
  bool failSwitch = false;
  int torchCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int switchCalls = 0;

  @override
  Future<void> toggleTorch() async {
    torchCalls++;
    if (failTorch) throw StateError('flaş yok');
  }

  @override
  Future<void> start({CameraFacing? cameraDirection, CameraLensType? cameraLensType}) async {
    startCalls++;
    if (failRestart) throw StateError('kamera açılamadı');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> switchCamera([SwitchCameraOption option = const ToggleDirection()]) async {
    switchCalls++;
    if (failSwitch) throw StateError('kamera değişmedi');
  }
}

void main() {
  /// Hazır sahte denetleyici; durum elle ayarlanır.
  _FakeScannerController fakeController({TorchState torch = TorchState.off, MobileScannerException? error}) {
    final controller = _FakeScannerController();
    controller.value = controller.value.copyWith(isInitialized: true, torchState: torch, error: error);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<Opened<String>> openScanner(
    WidgetTester tester, {
    QrCodeValidator? validator,
    MobileScannerController? controller,
    bool? supported = true,
    VoidCallback? onManualFallback,
    Size size = const Size(800, 1400),
  }) {
    final env = e2Env(role: null, authenticated: false);
    return openFromHost<String>(
      tester,
      env.state,
      size: size,
      (context) => Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => QrScannerPage(
            validator: validator,
            controller: controller ?? fakeController(),
            supportedOverride: supported,
            onManualFallback: onManualFallback,
          ),
        ),
      ),
    );
  }

  QrScannerPageState scannerState(WidgetTester tester) => tester.state<QrScannerPageState>(find.byType(QrScannerPage));

  group('doğrulayıcı ve tek pop', () {
    testWidgets('doğrulayıcı reddederse tarama SÜRER: sayfa kapanmaz, neden SnackBar ile gösterilir', (tester) async {
      final opened = await openScanner(
        tester,
        validator: (raw) => raw.startsWith('AHBU-') ? null : 'Bu bir pano karekodu değil.',
      );

      final accepted = scannerState(tester).debugHandleRaw('merhaba');
      await settle(tester);

      expect(accepted, isFalse);
      expect(opened.done, isFalse);
      expect(find.byType(QrScannerPage), findsOneWidget);
      expect(find.text('Bu bir pano karekodu değil.'), findsOneWidget);
    });

    testWidgets('geçerli kod kabul edilir: ham metin (kırpılmış) çağırana döner ve sayfa kapanır', (tester) async {
      final opened = await openScanner(tester, validator: (raw) => raw.startsWith('AHBU-') ? null : 'Geçersiz.');

      final accepted = scannerState(tester).debugHandleRaw('  AHBU-INVITE:AHBU-AB12CD34EF  ');
      await tester.pumpAndSettle();

      expect(accepted, isTrue);
      expect(opened.result, 'AHBU-INVITE:AHBU-AB12CD34EF');
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('doğrulayıcı yoksa her boş olmayan kod kabul edilir (eski çağıranlar uyumludur)', (tester) async {
      final opened = await openScanner(tester);
      scannerState(tester).debugHandleRaw('herhangi-bir-metin');
      await settle(tester);
      expect(opened.result, 'herhangi-bir-metin');
    });

    testWidgets('çoklu algılamada TEK pop: ikinci kod yok sayılır, çağırana ilk kod döner', (tester) async {
      final opened = await openScanner(tester);
      final state = scannerState(tester);

      final first = state.debugHandleRaw('ILK-KOD');
      final second = state.debugHandleRaw('IKINCI-KOD'); // pop tamamlanmadan ikinci algılama
      await settle(tester);

      expect(first, isTrue);
      expect(second, isFalse);
      expect(opened.result, 'ILK-KOD');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('open_host')), findsOneWidget, reason: 'yalnızca bir sayfa kapandı: ana sayfa duruyor');
    });

    testWidgets('doğrulayıcı istisna fırlatırsa çökmez; kod reddedilir ve genel mesaj gösterilir', (tester) async {
      final opened = await openScanner(tester, validator: (raw) => throw StateError('beklenmeyen'));

      final accepted = scannerState(tester).debugHandleRaw('X');
      await settle(tester);

      expect(accepted, isFalse);
      expect(opened.done, isFalse);
      expect(find.text('Karekod doğrulanamadı. Lütfen tekrar deneyin.'), findsOneWidget);
      expect(find.textContaining('beklenmeyen'), findsNothing);
    });

    testWidgets('boş içerik (yalnızca boşluk) yok sayılır', (tester) async {
      final opened = await openScanner(tester);
      expect(scannerState(tester).debugHandleRaw('   '), isFalse);
      expect(opened.done, isFalse);
    });
  });

  group('görünüm', () {
    testWidgets('başlık, ipucu, flaş ve kamera değiştirme düğmeleri görünür; elle giriş çağrısı çalışır', (tester) async {
      var fallbackCalled = false;
      final opened = await openScanner(tester, onManualFallback: () => fallbackCalled = true);

      expect(find.text('Karekod Tara'), findsOneWidget);
      expect(find.textContaining('Pano kapağındaki karekodu'), findsOneWidget);
      expect(find.byKey(const Key('btn_torch')), findsOneWidget);
      expect(find.byIcon(Icons.flip_camera_ios_rounded), findsOneWidget);

      await tapKey(tester, 'btn_manual_entry');
      await tester.pumpAndSettle();

      expect(fallbackCalled, isTrue);
      expect(opened.done, isTrue);
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('vizör çerçevesi ortalı bir TARAMA PENCERESİ olarak kameraya verilir', (tester) async {
      await openScanner(tester);

      final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
      final window = scanner.scanWindow;
      expect(window, isNotNull);
      final body = tester.getRect(find.byType(MobileScanner));
      expect(window!.center.dx, closeTo(body.width / 2, 0.5));
      expect(window.center.dy, closeTo(body.height / 2, 0.5));
      expect(window.width, window.height);
      expect(window.width, inInclusiveRange(220, 320));
    });

    testWidgets('küçük ekranda tarama penceresi ekrana sığar (taşma yok)', (tester) async {
      await openScanner(tester, size: const Size(320, 480));
      expect(tester.takeException(), isNull);
      final window = tester.widget<MobileScanner>(find.byType(MobileScanner)).scanWindow!;
      expect(window.width, lessThanOrEqualTo(320));
    });
  });

  group('flaş simgesi torchState\'e bağlıdır', () {
    testWidgets('kullanılamıyor -> pasif; kapalı -> etkin; açık -> dolu amber simge', (tester) async {
      final controller = fakeController(torch: TorchState.unavailable);
      await openScanner(tester, controller: controller);

      IconButton button() => tester.widget<IconButton>(find.byKey(const Key('btn_torch')));
      expect(button().onPressed, isNull, reason: 'flaş yoksa düğme pasif');
      expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);

      controller.value = controller.value.copyWith(torchState: TorchState.off);
      await tester.pump();
      expect(button().onPressed, isNotNull);
      expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);

      controller.value = controller.value.copyWith(torchState: TorchState.on);
      await tester.pump();
      expect(find.byIcon(Icons.flash_on_rounded), findsOneWidget);
      expect(find.byTooltip('Flaşı kapat'), findsOneWidget);

      controller.value = controller.value.copyWith(torchState: TorchState.auto);
      await tester.pump();
      expect(find.byIcon(Icons.flash_auto_rounded), findsOneWidget);
    });

    testWidgets('flaş açılamazsa SnackBar ile bildirilir (sessizce yutulmaz)', (tester) async {
      final controller = fakeController(torch: TorchState.off)..failTorch = true;
      await openScanner(tester, controller: controller);

      await tapKey(tester, 'btn_torch');

      expect(controller.torchCalls, 1);
      expect(find.text('Flaş açılamadı veya bu cihazda kullanılamıyor.'), findsOneWidget);
    });

    testWidgets('kamera değiştirme hatası da bildirilir', (tester) async {
      final controller = fakeController()..failSwitch = true;
      await openScanner(tester, controller: controller);

      await tapKey(tester, 'btn_switch_camera');

      expect(controller.switchCalls, 1);
      expect(find.text('Kamera değiştirilemedi.'), findsOneWidget);
    });
  });

  group('kamera izni ve hatalar', () {
    testWidgets('izin reddi: Android için ayar yönergesi, ham hata kodu YOK', (tester) async {
      await openScanner(
        tester,
        controller: fakeController(error: const MobileScannerException(errorCode: MobileScannerErrorCode.permissionDenied)),
      );

      expect(textOf(tester, 'scanner_error_title'), 'Kamera İzni Gerekli');
      expect(textOf(tester, 'scanner_error_message'), contains('Ayarlar > Uygulamalar > Ev Otomasyon > İzinler > Kamera'));
      expect(find.textContaining('permissionDenied'), findsNothing);
      expect(find.byKey(const Key('btn_scanner_retry')), findsOneWidget);
    });

    testWidgets('izin reddi: iOS için iOS yönergesi gösterilir', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await openScanner(
          tester,
          controller: fakeController(error: const MobileScannerException(errorCode: MobileScannerErrorCode.permissionDenied)),
        );
        expect(textOf(tester, 'scanner_error_message'), contains('Ayarlar > Ev Otomasyon > Kamera'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('desteklenmeyen cihaz: yeniden dene yok; elle giriş sunulur', (tester) async {
      await openScanner(
        tester,
        controller: fakeController(error: const MobileScannerException(errorCode: MobileScannerErrorCode.unsupported)),
        onManualFallback: () {},
      );

      expect(textOf(tester, 'scanner_error_title'), 'Kamera Desteklenmiyor');
      expect(find.byKey(const Key('btn_scanner_retry')), findsNothing);
      expect(find.text('Kodu Elle Gir'), findsOneWidget);
    });

    testWidgets('genel kamera hatası: açıklayıcı mesaj; "Tekrar Dene" başarısız olursa hata gösterilir (çökmez)', (tester) async {
      final controller = fakeController(error: const MobileScannerException(errorCode: MobileScannerErrorCode.genericError))
        ..failRestart = true;
      await openScanner(tester, controller: controller);
      expect(textOf(tester, 'scanner_error_title'), 'Kamera Başlatılamadı');

      await tapKey(tester, 'btn_scanner_retry');

      expect(controller.stopCalls, 1);
      expect(controller.startCalls, 1);
      expect(find.text('Kamera yeniden başlatılamadı. Uygulama izinlerini kontrol edin.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('mobil olmayan platform (web / Windows / Linux)', () {
    test('platformSupportsCamera yalnızca Android, iOS ve macOS için true', () {
      final results = <TargetPlatform, bool>{};
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        results[platform] = QrScannerPage.platformSupportsCamera;
      }
      debugDefaultTargetPlatformOverride = null;
      expect(results[TargetPlatform.android], isTrue);
      expect(results[TargetPlatform.iOS], isTrue);
      expect(results[TargetPlatform.macOS], isTrue);
      expect(results[TargetPlatform.windows], isFalse);
      expect(results[TargetPlatform.linux], isFalse);
    });

    testWidgets('Windows: çökmez, açık "desteklenmiyor" ekranı gösterir; kamera widget\'ı kurulmaz', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final env = e2Env(role: null, authenticated: false);
        var fallback = false;
        final opened = await openFromHost<String>(
          tester,
          env.state,
          (context) => Navigator.of(context).push<String>(
            MaterialPageRoute(builder: (_) => QrScannerPage(onManualFallback: () => fallback = true)),
          ),
        );

        expect(find.byKey(const Key('scanner_unsupported_title')), findsOneWidget);
        expect(find.byType(MobileScanner), findsNothing);
        expect(tester.takeException(), isNull);

        await tapKey(tester, 'btn_manual_entry');
        await tester.pumpAndSettle();
        expect(fallback, isTrue);
        expect(opened.done, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('desteklenmeyen ekranda "Geri" sayfayı kapatır', (tester) async {
      final opened = await openScanner(tester, supported: false);
      expect(find.byKey(const Key('scanner_unsupported_title')), findsOneWidget);

      await tapKey(tester, 'btn_scanner_back');
      await tester.pumpAndSettle();

      expect(opened.done, isTrue);
      expect(opened.result, isNull);
    });
  });
}
