import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../motion/pulse_ring.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb.dart';
import '../../../widgets/settings/accent_button.dart';

import '../logic/handover_logic.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 10 - Teslim: kontrol listesi özeti, notlar, müşteri onayı, sunucuya devreye alma, kurulum raporu.

/// Teslimde müşteriye söylenen bildirim notu (müşterinin telefonu her platformda olabilir; teknisyenin telefonu değil).
const String kHandoverAlarmNotificationNote =
    'Uygulama kapalıyken alarm bildirimi yalnız Android telefonda gelir: müşterinin telefonunda Ayarlar > '
    '"Arka planda alarm bildirimi"ni açın (iPhone\'da gelmez). Yine de siren takmanız önerilir.';

class Step10Handover extends StatefulWidget {
  const Step10Handover({super.key, required this.controller, required this.onFinish});

  final ServiceSetupController controller;

  /// "Bitir": sihirbazı kapatır.
  final VoidCallback onFinish;

  @override
  State<Step10Handover> createState() => _Step10HandoverState();
}

class _Step10HandoverState extends State<Step10Handover> {
  final TextEditingController _notes = TextEditingController();
  final TextEditingController _receiver = TextEditingController();
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _notes.text = widget.controller.handover.notes;
    _receiver.text = widget.controller.handover.receiver;
  }

  @override
  void dispose() {
    _notes.dispose();
    _receiver.dispose();
    super.dispose();
  }

  HandoverLogic get _h => widget.controller.handover;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final h = _h;
    final finished = h.isComplete;
    return stepScaffold(
      context,
      c,
      10,
      continueLabel: 'Bitir',
      canContinue: finished,
      onContinue: widget.onFinish,
      continueHint: 'Bitirmek için sunucunun devreye almayı onaylaması gerekir.',
      statusText: finished ? 'Devreye alındı' : null,
      // "Devreye Almayı Tamamla" etkinse hata kutusundaki "Tekrar dene" aynı işi yapar: çerçeveli ikincil (tek gradyan birincil).
      retrySecondary: h.canSubmit,
      body: finished ? _success(context, c) : _form(context, c),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _checkRow(BuildContext context, String title, bool ok, String detail, {int? fixStep}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SetupMiniOrb(
            family: ok ? AppFamilies.emerald : AppFamilies.rose,
            icon: ok ? Icons.check_rounded : Icons.close_rounded,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context))),
                Text(detail, style: TextStyle(fontSize: 12.5, height: 1.3, color: SetupColors.muted(context))),
              ],
            ),
          ),
          if (!ok && fixStep != null)
            TextButton(
              key: Key('btn_fix_step_$fixStep'),
              onPressed: () => widget.controller.goToStep(fixStep),
              style: setupInlineActionStyle(),
              child: Text('Adım $fixStep'),
            ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, ServiceSetupController c) {
    final h = _h;
    final checks = h.buildChecks();
    final canSubmit = h.canSubmit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SetupSectionTitle('Kontrol listesi'),
        SetupCard(
          key: const Key('handover_checklist'),
          child: Column(
            children: [
              _checkRow(context, 'Wi-Fi', checks.network.ok, checks.network.detail, fixStep: SetupSteps.wifi),
              _checkRow(context, 'Bulut', checks.cloud.ok, checks.cloud.detail, fixStep: SetupSteps.cloud),
              _checkRow(context, 'Röleler', checks.relays.ok, checks.relays.detail, fixStep: SetupSteps.relays),
              _checkRow(context, 'Panjurlar', checks.shutters.ok, checks.shutters.detail, fixStep: SetupSteps.shutters),
              _checkRow(context, 'Duvar butonları', checks.buttons.ok, checks.buttons.detail, fixStep: SetupSteps.buttons),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('btn_refresh_summary'),
            style: setupInlineActionStyle(),
            onPressed: h.busy ? null : () => h.refreshSummary(),
            icon: Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 18)),
            label: const Text('Güncel durumu yeniden oku'),
          ),
        ),
        const SetupSectionTitle('Not ve teslim'),
        SetupTextField(
          key: const Key('field_notes'),
          controller: _notes,
          // Kısa etiket + "isteğe bağlı" yardımcı metinde (1.5 yazı ölçeğinde "Montaj notu (isteğe b…" diye kesiliyordu).
          label: 'Montaj notu',
          helperText: 'İsteğe bağlı',
          hint: 'Örn: 2 lamba çıkışı kullanılmıyor.',
          prefixIcon: Icons.notes_rounded,
          maxLines: 3,
          maxLength: HandoverLogic.maxNotesLength,
          onChanged: (v) {
            h.setNotes(v);
          },
        ),
        SetupTextField(
          key: const Key('field_receiver'),
          controller: _receiver,
          label: 'Teslim alan kişi',
          helperText: 'İsteğe bağlı',
          prefixIcon: Icons.person_outline_rounded,
          maxLength: 100,
          onChanged: h.setReceiver,
        ),
        const SizedBox(height: 8),
        SetupCheckTile(
          key: const Key('chk_owner_approved'),
          value: h.ownerApproved,
          onChanged: h.busy ? null : (v) => h.setOwnerApproved(v),
          label: 'Müşteriye kurulumu gösterdim ve teslimi onayladı',
        ),
        const SizedBox(height: 8),
        SetupPrimaryButton(
          key: const Key('btn_commission'),
          label: 'Devreye Almayı Tamamla',
          icon: Icons.verified_rounded,
          color: SetupColors.ok,
          busy: h.busy && h.busyLabel == 'Devreye alma sunucuya gönderiliyor',
          onPressed: canSubmit ? () => h.submit() : null,
        ),
        // Pasif düğmenin nedeni düğmenin ALTINDA yazar: tüm adımlar hazırsa tek eksik müşteri onayıdır (eskiden neden yalnız alt
        // çubuktaki "Bitir" ipucundaydı; asıl eylem ekrandaki en sessiz öğeydi).
        if (h.allStepsReady && !h.ownerApproved && !h.busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Devreye almak için yukarıdaki müşteri onay kutusunu işaretleyin.',
              key: const Key('commission_locked_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppText.caption, height: 1.3, color: SetupColors.muted(context)),
            ),
          ),
        if (!h.allStepsReady)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SetupInfoRow(
              key: const Key('handover_missing'),
              icon: Icons.error_outline_rounded,
              color: SetupColors.error,
              text:
                  'Eksik adımlar: ${h.missingSteps.join(', ')}. Sonuçlar gerçek cihaz yanıtlarıyla doğrulandıktan sonra gönderilebilir.',
            ),
          ),
      ],
    );
  }

  Widget _success(BuildContext context, ServiceSetupController c) {
    final h = _h;
    final report = h.buildReport(
      roleLabel: c.access.isPinSession
          ? 'Geçici servis oturumu'
          : (c.access.isSuperUser ? 'Süper yönetici' : 'Servis personeli'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupCard(
          key: const Key('handover_success_card'),
          accent: SetupColors.ok,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Tek seferlik kutlama (<= 900 ms): nabız halkası + ✓ orb. Konfeti yok; hareket kapalıyken çizilmez.
              const Center(child: HandoverCelebration()),
              const SizedBox(height: 4),
              const SetupInfoRow(
                icon: Icons.verified_rounded,
                color: SetupColors.ok,
                bold: true,
                text: 'Kurulum tamamlandı: sunucu tüm testleri doğruladı ve cihazı devreye aldı.',
              ),
              // Faz 2 F2.C.2: gerçek push ağ geçidi (WP-N4) gelene kadar kalan risk müşteriye söylenir.
              const SetupInfoRow(
                key: Key('handover_push_note'),
                icon: Icons.notifications_off_outlined,
                color: SetupColors.warn,
                text: kHandoverAlarmNotificationNote,
              ),
            ],
          ),
        ),
        const SetupSectionTitle('Kurulum raporu'),
        SetupCard(
          child: SelectableText(
            report,
            key: const Key('handover_report'),
            style: SetupText.mono(fontSize: 13, height: 1.4, color: SetupColors.text(context)),
          ),
        ),
        Text(
          'Rapor PIN, cihaz anahtarı, bulut kimliği ve Wi-Fi şifresi içermez.',
          style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('btn_copy_report'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (mounted) setState(() => _copied = true);
          },
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: accentIconSize(context, base: 18)),
          label: Text(_copied ? 'Rapor panoya kopyalandı' : 'Raporu Kopyala / Paylaş'),
          // Çerçeve + metin + simge AYNI aileden ve AA (tema varsayılan çerçevesi açıkta ≈ 2.4:1'di).
          style: accentOutlinedButtonStyle(context, AppFamilies.sky),
        ),
      ],
    );
  }
}

/// Devreye alma başarısı: ✓ orb (emerald, tek seferlik başarı halkası) + bağlanışta tek nabız halkası.
/// Toplam süre en çok 700 ms; sonlu animasyondur (ambient/döngü/konfeti YOK; `MotionMode.off`'ta halka çizilmez).
/// Anlamdan hariçtir (başarı metni yanında). Testler için herkese açık.
class HandoverCelebration extends StatelessWidget {
  const HandoverCelebration({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const Key('handover_celebration'),
        dimension: 104,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Halka rengi açık temada koyu ton (`family.light` açık zeminde ≈ 1.3:1: kutlama fiilen görünmüyordu).
            PulseRing(
              color: AppTheme.accentTone(context, AppFamilies.emerald),
              diameter: OrbSize.lg.diameter,
              playOnMount: true,
              duration: const Duration(milliseconds: 700),
              maxScale: 1.9,
              strokeWidth: 3,
            ),
            const SetupResultOrb(
              icon: Icons.check_rounded,
              family: AppFamilies.emerald,
              size: OrbSize.lg,
              glow: true,
              status: OrbStatus.success,
            ),
          ],
        ),
      ),
    );
  }
}
