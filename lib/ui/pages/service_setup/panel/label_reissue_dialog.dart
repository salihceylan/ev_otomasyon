import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../models/json_utils.dart';
import '../../../../services/automation_state.dart';
import '../../../common/app_dialogs.dart';
import '../secret_clipboard.dart';
import '../secret_value_row.dart';
import '../setup_style.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb_icon_badge.dart';
import 'service_glass.dart';
import '../setup_widgets.dart';

/// `POST /admin/inventory/:uid/reissue-label` yanıtı: yeni kurulum PIN'i + yerel anahtar (+ PIN'li QR
/// bağlantısı) **yalnızca bir kez** gelir. [toString] gizli alanları yazmaz.
class LabelReissueResult {
  const LabelReissueResult({this.pin, this.localKey, this.qrClaimUrl, this.apPass});

  final String? pin;
  final String? localKey;
  final String? qrClaimUrl;
  final String? apPass;

  bool get isEmpty => pin == null && localKey == null && qrClaimUrl == null;

  factory LabelReissueResult.fromJson(Map<String, dynamic> json) => LabelReissueResult(
        pin: asNonEmptyString(json['pin'] ?? json['setup_pin']),
        localKey: asNonEmptyString(json['local_key']),
        qrClaimUrl: asNonEmptyString(json['qr_claim_url'] ?? json['qr_url']),
        apPass: asNonEmptyString(json['ap_pass']),
      );

  @override
  String toString() => 'LabelReissueResult(secrets: ******)';
}

/// Yeni etiket bilgilerini bir kez gösterir. Panoya kopyalanan her değer **45 sn sonra silinir**;
/// diyalog kapanınca pano hemen temizlenir.
class LabelReissueDialog extends StatefulWidget {
  const LabelReissueDialog({super.key, required this.deviceUuid, required this.result});

  final String deviceUuid;
  final LabelReissueResult result;

  static Future<void> show(BuildContext context, {required String deviceUuid, required LabelReissueResult result}) {
    return showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => LabelReissueDialog(deviceUuid: deviceUuid, result: result),
    );
  }

  @override
  State<LabelReissueDialog> createState() => _LabelReissueDialogState();
}

class _LabelReissueDialogState extends State<LabelReissueDialog> {
  String? _copied;
  int _copyCount = 0;

  @override
  void dispose() {
    // Diyalog kapanınca panodaki gizli değer hemen silinir.
    SecretClipboard.wipeNow();
    super.dispose();
  }

  Future<void> _copy(String label, String value) async {
    final clock = context.read<AutomationState>().clock;
    await SecretClipboard.copy(value, clock: clock);
    if (mounted) {
      setState(() {
        _copied = label;
        _copyCount++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final pin = r.pin;
    final formattedPin = (pin != null && pin.length == 6) ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;
    return AlertDialog(
      title: const Row(
        children: [
          OrbIconBadge(icon: Icons.qr_code_2_rounded, family: AppFamilies.cyan),
          SizedBox(width: 12),
          Expanded(child: Text('Yeni Etiket Bilgileri')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ServiceCard(
                key: Key('reissue_warning'),
                accent: SetupColors.warn,
                margin: EdgeInsets.zero,
                child: SetupInfoRow(
                  icon: Icons.warning_amber_rounded,
                  color: SetupColors.warn,
                  bold: true,
                  text: 'Bu bilgiler yalnızca BU KEZ gösterilir. Eski etiket geçersiz oldu: yeni etiketi basıp panoya '
                      'yapıştırın. Kopyaladığınız değer panodan 45 saniye sonra silinir.',
                ),
              ),
              const SizedBox(height: 10),
              // Kimlik tek satır: tireden bölünüp iki satıra yayılmaz, sığmazsa küçülür.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  widget.deviceUuid,
                  maxLines: 1,
                  softWrap: false,
                  style: SetupText.mono(fontSize: AppText.body, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
              if (formattedPin != null)
                SecretValueRow(
                  label: 'Kurulum PIN',
                  shown: formattedPin,
                  copyKey: const Key('btn_copy_reissue_pin'),
                  showWipeRing: false, // kartın kendi 45 sn halkası var (çift halka olmasın)
                  onCopy: () => _copy('Kurulum PIN', pin!),
                ),
              if (r.localKey != null)
                SecretValueRow(
                  label: 'Yerel anahtar',
                  shown: r.localKey!,
                  copyKey: const Key('btn_copy_reissue_key'),
                  showWipeRing: false, // kartın kendi 45 sn halkası var (çift halka olmasın)
                  onCopy: () => _copy('Yerel anahtar', r.localKey!),
                ),
              if (r.apPass != null)
                SecretValueRow(
                  label: 'Kurulum ağı parolası',
                  shown: r.apPass!,
                  copyKey: const Key('btn_copy_reissue_ap'),
                  showWipeRing: false, // kartın kendi 45 sn halkası var (çift halka olmasın)
                  onCopy: () => _copy('Kurulum ağı parolası', r.apPass!),
                ),
              if (r.qrClaimUrl != null) ...[
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppRadius.r12)),
                    child: QrImageView(data: r.qrClaimUrl!, size: 180, backgroundColor: Colors.white),
                  ),
                ),
                TextButton.icon(
                  key: const Key('btn_copy_reissue_qr'),
                  onPressed: () => _copy('Karekod bağlantısı', r.qrClaimUrl!),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Karekod bağlantısını kopyala'),
                ),
              ],
              if (_copied != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      SecretExpiryRing(key: ValueKey<int>(_copyCount)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$_copied panoya kopyalandı (45 sn sonra silinir).',
                          key: const Key('reissue_copied'),
                          style: TextStyle(fontSize: AppText.caption, color: SetupColors.muted(context)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        ElevatedButton(
          key: const Key('btn_reissue_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Kaydettim, Kapat'),
        ),
      ],
    );
  }
}
