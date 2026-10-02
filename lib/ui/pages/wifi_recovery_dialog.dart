import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_api_service.dart';
import '../../services/automation_state.dart';
import '../../services/board_network_binding.dart';
import '../../utils/qr_claim_parser.dart';
import '../common/wifi_provision_panel.dart';
import '../theme/app_theme.dart';

/// Wi-Fi kurulum & kurtarma sihirbazı: ev Wi-Fi bilgileri değiştiğinde (ya da servis kurulumunda)
/// panoya yenisini yükler. **Giriş yapmış olmak ve internet GEREKMEZ** (canlı test listesi Aşama 16).
///
/// * **Yetki kapısı yoktur** (misafir ve girişsiz kullanıcı dahil): cihaz zaten korunur. Pano, yalnızca
///   kendi WPA2 kurulum ağından (SoftAP) gelen isteklere anahtarsız Wi-Fi uçlarını açar (CONTRACTS §3d);
///   cihaza özel ağ parolasını bilmek = fiziksel erişim. `Capabilities.canOpenWifiRecovery` yalnızca
///   giriş yapmış alanlardaki **giriş noktalarını** (pano / ayarlar kartı) gizlemek içindir.
/// * Sunucuya **hiç istek atılmaz**; cihaz anahtarı sunucudan alınmaz/kaydedilmez. Telefonda önbellekte
///   (güvenli depo), bağlanılan panonun kimliğine ait bir anahtar zaten varsa cihaza gönderilir; yoksa
///   gönderilmez.
/// * Panoya **kendi** [AutomationApiService] örneğiyle (`AppConfig.deviceApHost`, varsayılan
///   `192.168.4.1`; QA'da `10.0.2.2:8081`) bağlanır; ana durumun cihaz adresine dokunulmaz.
/// * Kurulum ağının (AP) adı `AHBU-<MAC son 6>`, parolası **cihaza özeldir** ve pano etiketinde (metin ve
///   ikinci karekod) yazar; sabit ad/parola metni yoktur. Başarı yalnızca pano ev ağına bağlandığında
///   ([WifiProvisionPanel]: `wifi_connect_state == success`) gösterilir.
class WifiRecoveryDialog extends StatefulWidget {
  const WifiRecoveryDialog({super.key, this.api, this.deviceUuid, this.qrScanner});

  /// Yalnızca testlerde/özel akışlarda: hazır cihaz istemcisi (sahipliği çağırandadır).
  final AutomationApiService? api;

  /// Beklenen pano (biliniyorsa): bağlanılan pano farklıysa uyarılır ve kurulum ağı adı ipucu gösterilir.
  final String? deviceUuid;

  /// Yalnızca testlerde: Wi-Fi karekodunu okuyan işlev (varsayılan: kamera tarayıcısı).
  final Future<String?> Function(BuildContext context)? qrScanner;

  /// Sihirbaz rotasının adı: `AuthGate` biyometrik yeniden kilitte itilmiş tüm rotaları kapatırken sihirbazın
  /// açık olduğunu bu adla anlar ve kilit açılınca yeniden açar (kullanıcı telefonun Wi-Fi ayarlarına gidip
  /// 30 sn'den uzun kalmış olabilir).
  static const String routeName = '/wifi-setup';

  static Future<void> show(
    BuildContext context, {
    AutomationApiService? api,
    String? deviceUuid,
    Future<String?> Function(BuildContext context)? qrScanner,
  }) {
    final state = context.read<AutomationState>();
    return showDialog<void>(
      context: context,
      routeSettings: const RouteSettings(name: routeName),
      // Yanlışlıkla dışarı dokunmak yazılan Wi-Fi bilgilerini / bekleyen bağlantıyı kaybettirmesin:
      // kapatmak için "Kapat" düğmesi (ya da geri tuşu) kullanılır.
      barrierDismissible: false,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: WifiRecoveryDialog(api: api, deviceUuid: deviceUuid, qrScanner: qrScanner),
      ),
    );
  }

  @override
  State<WifiRecoveryDialog> createState() => _WifiRecoveryDialogState();
}

class _WifiRecoveryDialogState extends State<WifiRecoveryDialog> {
  late final AutomationState _state;
  late final AutomationApiService _api;
  late final bool _ownsApi;
  late final String? _expectedUid;
  final TextEditingController _apPassword = TextEditingController();

  bool _apObscure = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AutomationState>();
    _ownsApi = widget.api == null;
    _api = widget.api ?? AutomationApiService.recoveryAp(clock: _state.clock);
    _expectedUid = QrClaimParser.normalizeUid(widget.deviceUuid);
  }

  @override
  void dispose() {
    _apPassword.dispose();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  /// Bağlantı testi sonucu: kimliği doğrulanmış panonun önbellekteki anahtarı (varsa) cihaza gönderilir.
  /// Yalnızca **yerel** okuma yapılır (ağ yok); anahtar yoksa istekler anahtarsız (AP kaynaklı) gider.
  /// [status] `null` ise (pano bulunamadı) önceki panoya ait anahtar bırakılmaz.
  Future<void> _onDeviceChecked(DeviceStatus? status) async {
    if (!_ownsApi) return; // çağıranın verdiği istemciye dokunulmaz
    _api.localKey = null;
    final uid = QrClaimParser.normalizeUid(status?.uid);
    if (uid == null) return;
    String? key;
    try {
      key = await _state.secureStorage.getLocalKey(uid);
    } catch (_) {
      key = null; // depo okunamadı: anahtarsız devam
    }
    if (!mounted) return;
    if (AutomationApiService.isValidLocalKey(key)) _api.localKey = key;
  }

  /// Adım 4'ün sonu: Android'de uygulama pano ağını kendisi seçer (mobil veri açık kalabilir); diğer
  /// platformlarda eski yönerge.
  static String _mobileDataNote() => BoardNetworkBinding.instance.isSupported
      ? '. ${BoardNetworkBinding.mobileDataAdvice}'
      : ' (gerekirse mobil veriyi geçici olarak kapatın).';

  /// `AHBU-S3-1A2B3C` -> `AHBU-1A2B3C` (kurulum ağının adı).
  String? _apSsidHint(String? uuid) {
    if (uuid == null) return null;
    final match = RegExp(r'^AHBU-S3-([0-9A-F]{6})$').firstMatch(uuid);
    return match == null ? null : 'AHBU-${match.group(1)}';
  }

  Future<void> _copyApPassword() async {
    final text = _apPassword.text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Ağ parolası panoya kopyalandı.'), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardBorder = AppTheme.getCardBorder(context);
    final textPrimary = AppTheme.getTextPrimary(context);
    final textMuted = AppTheme.getTextMuted(context);

    return Dialog(
      backgroundColor: AppTheme.getSurfaceColor(context),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cardBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.wifi_find, color: AppTheme.primaryBlueLight, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Wi-Fi Kurulum & Kurtarma Sihirbazı',
                          key: const Key('wifi_dialog_title'),
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Modem veya şifre değiştiğinde panoyu yeniden bağlayın. İnternet ve giriş gerekmez.',
                          style: TextStyle(fontSize: 11.5, color: textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_close'),
                    tooltip: 'Kapat',
                    icon: Icon(Icons.close, color: textMuted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Divider(height: 24, color: cardBorder),
              if (!_done) ...[
                _buildApStep(textPrimary, textMuted),
                const SizedBox(height: 16),
              ],
              // Panel her zaman ağaçtadır: başarı görünümü (ve sonuç durumu) panelin içindedir.
              WifiProvisionPanel(
                key: const Key('wifi_provision_panel'),
                api: _api,
                clock: _state.clock,
                expectedUid: _expectedUid,
                numberedSteps: true,
                qrScanner: widget.qrScanner,
                onDeviceChecked: _onDeviceChecked,
                onResult: (result) {
                  if (result.isSuccess && mounted) setState(() => _done = true);
                },
              ),
              if (_done) ...[
                const SizedBox(height: 14),
                Text(
                  'Pano bulut bağlantısını birkaç saniye içinde yeniden kurar; uygulamada çevrimiçi '
                  'görünene kadar bekleyin.',
                  key: const Key('wifi_done_text'),
                  style: TextStyle(fontSize: 12.5, color: textMuted, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  key: const Key('btn_wifi_done'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Tamam'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Adım 1: telefonu panonun kurulum ağına bağlama yönergesi (parola etiketten; sabit parola yok).
  Widget _buildApStep(Color textPrimary, Color textMuted) {
    final hint = _apSsidHint(_expectedUid);
    return Container(
      key: const Key('wifi_step_ap'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Adım 1: Telefonu panonun kurulum ağına bağlayın',
            key: const Key('wifi_step_ap_title'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.primaryBlueLight),
          ),
          const SizedBox(height: 6),
          Text(
            'Pano kendi kurulum ağını yayınlar; bu işlem için internet ve hesap girişi gerekmez.\n'
            '1. Telefonunuzun Wi-Fi ayarlarını açın.\n'
            '2. ${hint == null ? 'Pano etiketindeki "KURULUM Wi-Fi AĞI" (AHBU-XXXXXX biçiminde)' : '"$hint"'} ağına bağlanın.\n'
            '3. Ağ parolası cihaza özeldir: pano etiketindeki "AĞ PAROLASI (AP)" değerini girin. '
            'Kolay yol: etiketteki ikinci karekodu (Wi-Fi karekodu) telefonunuzun kamerasıyla okutup çıkan '
            '"Ağa bağlan" önerisine dokunun.\n'
            '4. Telefon "internet yok" uyarısı verirse bağlantıyı koruyun${_mobileDataNote()}\n'
            '5. Bağlandıktan sonra bu ekrana dönüp "Pano Bağlantısını Test Et"e dokunun.',
            key: const Key('wifi_step_ap_text'),
            style: TextStyle(fontSize: 12, color: textMuted, height: 1.4),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('field_ap_password'),
            controller: _apPassword,
            obscureText: _apObscure,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Etiketteki ağ parolası (isteğe bağlı)',
              helperText: 'Yalnızca kopyalamak içindir; kaydedilmez, hiçbir yere gönderilmez.',
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('btn_ap_password_toggle'),
                    tooltip: _apObscure ? 'Göster' : 'Gizle',
                    icon: Icon(_apObscure ? Icons.visibility_off : Icons.visibility, size: 18),
                    onPressed: () => setState(() => _apObscure = !_apObscure),
                  ),
                  IconButton(
                    key: const Key('btn_copy_ap_password'),
                    tooltip: 'Kopyala',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: _apPassword.text.isEmpty ? null : _copyApPassword,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
