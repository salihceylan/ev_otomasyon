import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../utils/qr_router.dart';
import '../pages/claim/claim_manual_dialog.dart';
import '../pages/claim/qr_scanner_page.dart';
import '../pages/family/join_home_dialog.dart';
import 'confirm_dialogs.dart';

/// Kamerayla karekod tarar ve sonucu **türüne göre** yönlendirir (`QrRouter`): pano etiketi ->
/// cihaz eşleştirme, davet / devir kodu -> eve katıl (önizleme + onay), Wi-Fi karekodu -> bu ekranda
/// kullanılamaz uyarısı, tanınmayan içerik -> açık Türkçe hata (**ham metin cihaz kimliği sayılmaz**).
///
/// E1 (ana sayfa) ve diğer ekranlar tek satırla kullanır: `scanAndRouteQr(context)`.
Future<void> scanAndRouteQr(BuildContext context) async {
  final navigator = Navigator.of(context);
  final raw = await navigator.push<String>(
    MaterialPageRoute(
      builder: (_) => QrScannerPage(
        // Wi-Fi ve tanınmayan karekodlar bu akışta anlamsızdır: tarama sürer, neden gösterilir.
        validator: (code) {
          final payload = QrRouter.route(code);
          return switch (payload) {
            QrClaim() || QrInvite() || QrTransfer() => null,
            QrWifi() => 'Bu bir Wi-Fi karekodu. Wi-Fi kurulumu için "Wi-Fi Kurulum & Kurtarma Sihirbazı"nı kullanın.',
            QrUnknown(:final message) => message,
          };
        },
        onManualFallback: () {
          // Tarayıcı kapandıktan sonra çağrılır; bağlam hâlâ geçerliyse elle giriş açılır.
          if (context.mounted) ClaimManualDialog.show(context);
        },
      ),
    ),
  );
  if (raw == null || !context.mounted) return;
  await routeScannedCode(context, raw);
}

/// Taranan/yapıştırılan ham metni yönlendirir (bkz. [scanAndRouteQr]).
Future<void> routeScannedCode(BuildContext context, String raw) async {
  final state = context.read<AutomationState>();
  final payload = QrRouter.route(raw);
  switch (payload) {
    case QrClaim(:final uid, :final pin):
      if (!state.capabilities.canClaimDevice) {
        showFriendlyError(context, ApiException.forbidden('Bu hesapla cihaz eşleştiremezsiniz.'));
        return;
      }
      await ClaimManualDialog.show(context, initialUid: uid, initialPin: pin);
    case QrInvite(:final code):
      await JoinHomeDialog.show(context, initialCode: code);
    case QrTransfer(:final code):
      await JoinHomeDialog.show(context, initialCode: code);
    case QrWifi():
      showFriendlyError(
        context,
        null,
        fallback: 'Bu bir Wi-Fi karekodu. Wi-Fi kurulumu için "Wi-Fi Kurulum & Kurtarma Sihirbazı"nı kullanın.',
      );
    case QrUnknown(:final message):
      showFriendlyError(context, null, fallback: message);
  }
}
