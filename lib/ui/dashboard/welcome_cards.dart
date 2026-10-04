import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/qr_flow.dart';
import '../motion/motion.dart';
import '../pages/claim/claim_manual_dialog.dart';
import '../pages/family/join_home_dialog.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_pill.dart';
import '../widgets/orb/orb.dart';
import '../widgets/surface_card.dart';
import 'dashboard_states.dart';
import 'labels.dart';

/// Dairesi olmayan kullanıcı karşılaması. **Yalnızca ev listesi başarıyla (boş) alındığında**
/// gösterilir (hata/yükleme "daire yok" sanılmaz). Eve davet koduyla / karekodla katılma ve
/// (yetkiliyse) kendi cihazını eşleme yolları sunulur.
///
/// Düğmeler TEMA stilini kullanır (gradyan hap / çerçeveli hap): çağrı yerinde `shape` / `backgroundColor`
/// geçersiz kılması YOKTUR. Geniş ekranda CTA grubu en çok [kDashboardCtaMaxWidth] genişliğinde ve ortalıdır.
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

    return Column(
      key: const Key('view_homeless'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Ortak cam yüzey ([StateCard] -> SurfaceCard): opak taban + rim + gölge; arkadaki devre izi kartın
        // içinden görünmez (eskiden el yapımı yarı saydam gradyandı).
        StaggeredEntrance(
          index: 0,
          child: StateCard(
            accent: AppFamilies.cyan.base,
            active: true,
            orb: const OrbIconBadge(icon: Icons.key_rounded, family: AppFamilies.cyan, size: OrbSize.xl, active: true),
            title: 'Hoş Geldiniz, ${vm.name}!',
            extra: const _InfoPill(text: 'Henüz kayıtlı bir daireniz yok'),
          ),
        ),
        const SizedBox(height: AppSpace.s24),
        StaggeredEntrance(
          index: 1,
          child: Text(
            'Daireye Katılmak İçin',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppText.caption,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
              color: AppTheme.getTextMuted(context),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.s12),
        StaggeredEntrance(
          index: 2,
          child: StateActions(
            stackBelow: double.infinity,
            maxWidth: kDashboardCtaMaxWidth,
            children: [
              FilledButton.icon(
                key: const Key('btn_join_code'),
                icon: const Icon(Icons.vpn_key_outlined, size: 20),
                label: const Text('Kod ile Bir Eve Katıl'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () async {
                  final joined = await JoinHomeDialog.show(context);
                  if (joined == true && context.mounted) unawaited(state.refresh());
                },
              ),
              OutlinedButton.icon(
                key: const Key('btn_scan_qr'),
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                label: Text(
                  vm.canClaim ? 'Karekod Tara (Katıl / Cihaz Eşle)' : 'Karekod ile Katıl',
                  textAlign: TextAlign.center,
                ),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => scanAndRouteQr(context),
              ),
              if (vm.canClaim)
                TextButton.icon(
                  key: const Key('btn_claim_manual'),
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  label: const Text('Cihaz Kodunu Elle Gir'),
                  onPressed: () => ClaimManualDialog.show(context),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.s24),
        StaggeredEntrance(
          index: 3,
          child: SurfaceCard(
            padding: const EdgeInsets.all(AppSpace.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.help_outline_rounded,
                      color: AppTheme.readableFamily(context, AppFamilies.cyan),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Nasıl Daireye Katılırım?',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.getTextPrimary(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.s12),
                const _Step(
                  step: '1',
                  text: 'Dairenizin sahibinden veya yöneticisinden bir davet kodu alın.',
                  family: AppFamilies.sky,
                ),
                const SizedBox(height: AppSpace.s8),
                const _Step(
                  step: '2',
                  text: '"Kod ile Bir Eve Katıl" düğmesine basın ve size iletilen kodu girin.',
                  family: AppFamilies.cyan,
                ),
                const SizedBox(height: AppSpace.s8),
                const _Step(
                  step: '3',
                  text: 'Katılım onaylandıktan sonra dairenizin kontrolleri otomatik olarak açılır.',
                  family: AppFamilies.emerald,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Henüz kayıtlı bir daireniz yok" bilgi hapı: panodaki diğer tüm haplar gibi ortak rozet ([AppPill]; amber tonlu cam +
/// bilgi simgesi: renk tek ipucu değil).
class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => AppPill(label: text, family: AppFamilies.amber, icon: Icons.info_outline);
}

/// Numaralı adım: aile renkli mini küre rozeti (28 dp) + açıklama. Rakam 12 sp kalın (şartname tabanı).
class _Step extends StatelessWidget {
  const _Step({required this.step, required this.text, required this.family});

  final String step;
  final String text;
  final AccentFamily family;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.4),
              radius: 1.0,
              colors: [
                family.base.withValues(alpha: dark ? 0.42 : 0.30),
                family.base.withValues(alpha: dark ? 0.16 : 0.12),
              ],
            ),
            border: Border.all(color: family.base.withValues(alpha: 0.55)),
          ),
          child: Center(
            child: Text(
              step,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppTheme.readableFamily(context, family),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              text,
              style: TextStyle(fontSize: AppText.body, height: 1.4, color: AppTheme.getTextMuted(context)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Ev sahibinin dairesinde henüz cihaz yokken gösterilen karşılama / cihaz eşleme kartı.
/// **Yalnızca ev sahibine** ve **başarılı boş** uç nokta yanıtında gösterilir.
///
/// Düğmeler tema stilindedir (gradyan hap / çerçeveli hap); CTA grubu geniş ekranda en çok
/// [kDashboardCtaMaxWidth] genişliğinde ve ortalıdır.
///
/// Anahtarlar: `Key('card_welcome_claim')`, `Key('btn_scan_qr')`, `Key('btn_claim_manual')`.
class WelcomeClaimCard extends StatelessWidget {
  const WelcomeClaimCard({super.key});

  @override
  Widget build(BuildContext context) {
    // Boş panoda tek kart: durum kartları gibi tek seferlik giriş (anahtar kartın kendisinde kalır).
    return StaggeredEntrance(
      index: 1,
      child: StateCard(
        key: const Key('card_welcome_claim'),
        accent: AppFamilies.sky.base,
        active: true,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.s24, vertical: AppSpace.s32),
        orb: const OrbIconBadge(
          icon: Icons.qr_code_scanner_rounded,
          family: AppFamilies.sky,
          size: OrbSize.xl,
          active: true,
        ),
        title: 'Evinize Hoş Geldiniz!',
        message:
            'Akıllı panonuzun lamba ve panjurlarını yönetebilmek için pano kapağındaki karekodu '
            'tarayarak kurulumu tamamlayın.',
        actionsStackBelow: double.infinity,
        actionsMaxWidth: kDashboardCtaMaxWidth,
        actions: [
          ElevatedButton.icon(
            key: const Key('btn_scan_qr'),
            onPressed: () => scanAndRouteQr(context),
            icon: const Icon(Icons.camera_alt_outlined, size: 20),
            label: const Text('Karekod ile Cihaz Eşle', textAlign: TextAlign.center),
          ),
          OutlinedButton.icon(
            key: const Key('btn_claim_manual'),
            onPressed: () => ClaimManualDialog.show(context),
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('Kodu Elle Gir (Manuel Eşleme)', textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
