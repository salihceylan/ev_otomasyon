import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/qr_flow.dart';
import '../pages/claim/claim_manual_dialog.dart';
import '../pages/family/join_home_dialog.dart';
import '../theme/app_theme.dart';
import 'labels.dart';

/// Dairesi olmayan kullanıcı karşılaması. **Yalnızca ev listesi başarıyla (boş) alındığında**
/// gösterilir (hata/yükleme "daire yok" sanılmaz). Eve davet koduyla / karekodla katılma ve
/// (yetkiliyse) kendi cihazını eşleme yolları sunulur.
///
/// Anahtarlar: `Key('view_homeless')`, `Key('btn_join_code')`, `Key('btn_scan_qr')`,
/// `Key('btn_claim_manual')`.
class HomelessWelcome extends StatelessWidget {
  const HomelessWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final vm = context.select<AutomationState, ({String name, bool canClaim})>(
      (s) => (
        name: firstNameOf(s.currentUser?.fullName, email: s.currentUser?.email),
        canClaim: s.capabilities.canClaimDevice,
      ),
    );
    final isDark = AppTheme.isDark(context);

    return Column(
      key: const Key('view_homeless'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTheme.primaryBlue.withValues(alpha: isDark ? 0.18 : 0.10),
                AppTheme.primaryBlueLight.withValues(alpha: isDark ? 0.08 : 0.04),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            color: isDark ? null : AppTheme.cardLight,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppTheme.primaryBlueLight.withValues(alpha: isDark ? 0.3 : 0.4),
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.primaryBlue.withValues(alpha: 0.2),
                  border: Border.all(
                    color: AppTheme.primaryBlueLight.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                child: Icon(Icons.key_rounded, color: AppTheme.infoText(context), size: 36),
              ),
              const SizedBox(height: 16),
              Text(
                'Hoş Geldiniz, ${vm.name}!',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.getTextPrimary(context),
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.accentAmber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.accentAmber.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, color: AppTheme.warningText(context), size: 14),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Henüz kayıtlı bir daireniz yok',
                        style: TextStyle(fontSize: 13, color: AppTheme.warningText(context)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Daireye Katılmak İçin',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
            color: AppTheme.getTextMuted(context),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('btn_join_code'),
          icon: const Icon(Icons.vpn_key_outlined, size: 20),
          label: const Text(
            'Kod ile Bir Eve Katıl',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () async {
            final joined = await JoinHomeDialog.show(context);
            if (joined == true && context.mounted) unawaited(state.refresh());
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('btn_scan_qr'),
          icon: const Icon(Icons.qr_code_scanner, size: 20),
          label: Text(
            vm.canClaim ? 'Karekod Tara (Katıl / Cihaz Eşle)' : 'Karekod ile Katıl',
            style: const TextStyle(fontSize: 15),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.infoText(context),
            side: BorderSide(color: AppTheme.infoText(context).withValues(alpha: 0.6)),
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () => scanAndRouteQr(context),
        ),
        if (vm.canClaim) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            key: const Key('btn_claim_manual'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('Cihaz Kodunu Elle Gir'),
            onPressed: () => ClaimManualDialog.show(context),
          ),
        ],
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.cardDecoration(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.help_outline_rounded, color: AppTheme.readableAccent(context, AppTheme.accentCyan), size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Nasıl Daireye Katılırım?',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.getTextPrimary(context),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Step(
                step: '1',
                text: 'Dairenizin sahibinden veya yöneticisinden bir davet kodu alın.',
                color: AppTheme.primaryBlueLight,
              ),
              const SizedBox(height: 8),
              _Step(
                step: '2',
                text: '"Kod ile Bir Eve Katıl" düğmesine basın ve size iletilen kodu girin.',
                color: AppTheme.accentCyan,
              ),
              const SizedBox(height: 8),
              _Step(
                step: '3',
                text: 'Katılım onaylandıktan sonra dairenizin kontrolleri otomatik olarak açılır.',
                color: AppTheme.accentGreen,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.step, required this.text, required this.color});

  final String step;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.2),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppTheme.readableAccent(context, color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, height: 1.4, color: AppTheme.getTextMuted(context)),
          ),
        ),
      ],
    );
  }
}

/// Ev sahibinin dairesinde henüz cihaz yokken gösterilen karşılama / cihaz eşleme kartı.
/// **Yalnızca ev sahibine** ve **başarılı boş** uç nokta yanıtında gösterilir.
///
/// Anahtarlar: `Key('card_welcome_claim')`, `Key('btn_scan_qr')`, `Key('btn_claim_manual')`.
class WelcomeClaimCard extends StatelessWidget {
  const WelcomeClaimCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('card_welcome_claim'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: AppTheme.cardDecoration(context, radius: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.primaryBlueLight.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: Icon(Icons.qr_code_scanner_rounded, color: AppTheme.infoText(context), size: 56),
          ),
          const SizedBox(height: 20),
          Text(
            'Evinize Hoş Geldiniz!',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.getTextPrimary(context),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Akıllı panonuzun lamba ve panjurlarını yönetebilmek için pano kapağındaki karekodu '
            'tarayarak kurulumu tamamlayın.',
            style: TextStyle(fontSize: 14, height: 1.4, color: AppTheme.getTextMuted(context)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('btn_scan_qr'),
              onPressed: () => scanAndRouteQr(context),
              icon: const Icon(Icons.camera_alt_outlined, size: 20),
              label: const Text(
                'Karekod ile Cihaz Eşle',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_claim_manual'),
              onPressed: () => ClaimManualDialog.show(context),
              icon: Icon(
                Icons.keyboard_alt_outlined,
                size: 18,
                color: AppTheme.getTextMuted(context),
              ),
              label: Text(
                'Kodu Elle Gir (Manuel Eşleme)',
                style: TextStyle(fontSize: 14, color: AppTheme.getTextPrimary(context)),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                side: BorderSide(color: AppTheme.getCardBorder(context)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
