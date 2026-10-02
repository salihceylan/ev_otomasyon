import 'package:flutter/material.dart';

import '../logic/identify_logic.dart';
import '../service_setup_controller.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 2 - Cihazı Tanı: etiket karekodu / elle UID + PIN (personel) ya da dairedeki pano seçimi (PIN oturumu).
class Step2Identify extends StatefulWidget {
  const Step2Identify({super.key, required this.controller, required this.scanner});

  final ServiceSetupController controller;
  final SetupScanner scanner;

  @override
  State<Step2Identify> createState() => _Step2IdentifyState();
}

class _Step2IdentifyState extends State<Step2Identify> {
  final TextEditingController _uid = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  bool _manual = false;

  @override
  void dispose() {
    _uid.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await widget.scanner(
      context,
      title: 'Cihaz Etiketi',
      hint: 'Pano etiketindeki karekodu çerçeveye hizalayın',
    );
    if (raw == null || !mounted) return;
    await widget.controller.identify.acceptLabel(raw);
  }

  Future<void> _submitManual() async {
    final ok = await widget.controller.identify.acceptManual(_uid.text, _pin.text);
    if (ok && mounted) {
      _pin.clear();
      _uid.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final identify = c.identify;
    return stepScaffold(
      context,
      c,
      2,
      continueHint: c.access.isPinSession
          ? 'Devam etmek için dairedeki panoyu seçin.'
          : 'Devam etmek için cihazı tanıtın: karekodu okutun ya da seri numarası ve PIN\'i yazın.',
      statusText: c.isStepComplete(2) ? 'Cihaz tanındı' : null,
      body: c.access.isPinSession ? _pinBody(context, c) : _staffBody(context, c, identify),
    );
  }

  // ---------------------------------------------------------------------------
  // Geçici servis oturumu: dairedeki panolar
  // ---------------------------------------------------------------------------
  Widget _pinBody(BuildContext context, ServiceSetupController c) {
    final identify = c.identify;
    final devices = identify.homeDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupCard(
          accent: SetupColors.info,
          child: SetupInfoRow(
            icon: Icons.info_outline_rounded,
            text: 'Geçici servis oturumunda cihazı müşteriye bağlama (claim) yapılmaz: pano ev sahibi tarafından '
                'zaten eşlenmiştir. Kurulacak panoyu seçin; 3. ve 4. adımlar atlanır.',
          ),
        ),
        const SetupSectionTitle('Dairedeki panolar'),
        if (!identify.devicesLoaded && !identify.busy && identify.problem == null)
          SetupPrimaryButton(
            key: const Key('btn_load_devices'),
            label: 'Panoları Listele',
            icon: Icons.refresh_rounded,
            onPressed: () => identify.loadHomeDevices(),
          ),
        for (final d in devices)
          Builder(builder: (context) {
            final selected = identify.selectedDevice?.toUpperCase() == d.deviceUuid.toUpperCase();
            return SetupCard(
              key: Key('card_device_${d.deviceUuid}'),
              accent: selected ? SetupColors.ok : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => identify.selectHomeDevice(d.deviceUuid),
                child: Row(
                  children: [
                    Icon(
                      selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      color: selected ? SetupColors.ok : SetupColors.muted(context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.deviceUuid,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w800,
                              color: SetupColors.text(context),
                            ),
                          ),
                          Text(
                            '${d.name.isEmpty ? 'Pano' : d.name} • ${d.online ? 'Sunucuda çevrimiçi' : 'Sunucuda çevrimdışı'}',
                            style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Personel / süper kullanıcı: etiket
  // ---------------------------------------------------------------------------
  Widget _staffBody(BuildContext context, ServiceSetupController c, IdentifyLogic identify) {
    if (c.claim.isComplete) {
      return SetupCard(
        key: const Key('step2_done_card'),
        accent: SetupColors.ok,
        child: SetupInfoRow(
          icon: Icons.check_circle_rounded,
          color: SetupColors.ok,
          bold: true,
          text: 'Cihaz tanındı ve daireye bağlandı: ${c.target?.deviceUuid ?? ''}',
        ),
      );
    }
    if (identify.uid != null && identify.hasPin) return _acceptedCard(context, identify);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        SetupPrimaryButton(
          key: const Key('btn_scan_label'),
          label: 'Etiketi Tara (Karekod)',
          icon: Icons.qr_code_scanner_rounded,
          busy: identify.busy,
          onPressed: _scan,
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('btn_toggle_manual'),
          onPressed: () => setState(() => _manual = !_manual),
          icon: Icon(_manual ? Icons.expand_less_rounded : Icons.keyboard_rounded),
          label: Text(_manual ? 'Elle yazmayı gizle' : 'Karekodu okutamıyorum: elle yazacağım'),
        ),
        if (_manual)
          SetupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SetupTextField(
                  key: const Key('field_uid'),
                  controller: _uid,
                  label: 'Cihaz seri numarası',
                  hint: 'AHBU-S3-A1B2C3',
                  prefixIcon: Icons.tag_rounded,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  monospace: true,
                ),
                SecretField(
                  key: const Key('field_pin'),
                  controller: _pin,
                  label: 'Kurulum PIN (6 rakam)',
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  inputFormatters: [digitsOnly],
                  prefixIcon: Icons.pin_rounded,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submitManual(),
                ),
                const SizedBox(height: 12),
                SetupPrimaryButton(
                  key: const Key('btn_submit_manual'),
                  label: 'Bilgileri Kullan',
                  icon: Icons.check_rounded,
                  busy: identify.busy,
                  onPressed: _submitManual,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _acceptedCard(BuildContext context, IdentifyLogic identify) {
    final String text;
    final IconData icon;
    final Color color;
    switch (identify.inventory) {
      case InventoryCheck.inStock:
        text = 'Sunucuda stokta görünüyor: kuruluma uygun.';
        icon = Icons.verified_rounded;
        color = SetupColors.ok;
      case InventoryCheck.notVisible:
        text = 'Bu hesapla stok durumu görüntülenemiyor. Cihazın kuruluma uygunluğunu sunucu, müşteriye kod '
            'gönderilirken kesin olarak kontrol eder.';
        icon = Icons.info_outline_rounded;
        color = SetupColors.info;
      default:
        if (identify.busy) {
          text = 'Sunucuda kontrol ediliyor...';
          icon = Icons.hourglass_top_rounded;
          color = SetupColors.primaryLight;
        } else {
          // Kontrol tamamlanamadı (ağ hatası vb.): "kontrol ediliyor" yazıp beklenmez; durum açıkça söylenir.
          text = 'Sunucu kontrolü tamamlanamadı: cihazın uygunluğu doğrulanmadı. Aşağıdan "Tekrar dene"ye basın.';
          icon = Icons.error_outline_rounded;
          color = SetupColors.error;
        }
    }
    return SetupCard(
      key: const Key('step2_accepted_card'),
      accent: SetupColors.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SetupInfoRow(icon: Icons.developer_board_rounded, text: 'Cihaz: ${identify.uid}', bold: true),
          const SetupInfoRow(icon: Icons.pin_rounded, text: 'Kurulum PIN: ••••••  (gizli tutulur)'),
          SetupInfoRow(icon: icon, color: color, text: text),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('btn_reset_label'),
            onPressed: identify.busy ? null : identify.reset,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('Başka Cihaz Seç'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ),
    );
  }
}
