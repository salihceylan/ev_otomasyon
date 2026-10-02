import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic/handover_logic.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 10 - Teslim: kontrol listesi özeti, notlar, müşteri onayı, sunucuya devreye alma, kurulum raporu.
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
      body: finished ? _success(context, c) : _form(context, c),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _checkRow(BuildContext context, String title, bool ok, String detail, {int? fixStep}) {
    final color = ok ? SetupColors.ok : SetupColors.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: SetupColors.readable(context, color), size: 22),
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
            onPressed: h.busy ? null : () => h.refreshSummary(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Güncel durumu yeniden oku'),
          ),
        ),
        const SetupSectionTitle('Not ve teslim'),
        SetupTextField(
          key: const Key('field_notes'),
          controller: _notes,
          label: 'Montaj notu (isteğe bağlı)',
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
          label: 'Teslim alan kişi (isteğe bağlı)',
          prefixIcon: Icons.person_outline_rounded,
          maxLength: 100,
          onChanged: h.setReceiver,
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const Key('chk_owner_approved'),
          value: h.ownerApproved,
          onChanged: h.busy ? null : (v) => h.setOwnerApproved(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('Müşteriye kurulumu gösterdim ve teslimi onayladı'),
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
        if (!h.allStepsReady)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Eksik adımlar: ${h.missingSteps.join(', ')}. Sonuçlar gerçek cihaz yanıtlarıyla doğrulandıktan sonra gönderilebilir.',
              key: const Key('handover_missing'),
              style: TextStyle(fontSize: 12.5, color: SetupColors.error),
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
          child: const SetupInfoRow(
            icon: Icons.verified_rounded,
            color: SetupColors.ok,
            bold: true,
            text: 'Kurulum tamamlandı: sunucu tüm testleri doğruladı ve cihazı devreye aldı.',
          ),
        ),
        const SetupSectionTitle('Kurulum raporu'),
        SetupCard(
          child: SelectableText(
            report,
            key: const Key('handover_report'),
            style: TextStyle(fontSize: 13, height: 1.4, fontFamily: 'monospace', color: SetupColors.text(context)),
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
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 18),
          label: Text(_copied ? 'Rapor panoya kopyalandı' : 'Raporu Kopyala / Paylaş'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }
}
