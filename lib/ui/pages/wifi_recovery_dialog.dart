import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/automation_models.dart';
import '../../services/automation_api_service.dart';
import '../../services/automation_state.dart';
import '../../services/board_network_binding.dart';
import '../../services/clock.dart';
import '../../utils/qr_claim_parser.dart';
import '../common/app_dialogs.dart';
import '../common/auth_form.dart' show BalancedText;
import '../common/wifi_provision_panel.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart';
import '../widgets/settings/accent_button.dart';
import '../widgets/surface_card.dart';
import '../theme/feature_accent.dart';
import 'service_setup/service_target.dart' show ServiceSetupAccess;

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

  /// Önbellekteki anahtar okuması için üst süre (PF-43): güvenli depo (Keystore/Keychain) takılırsa sihirbaz
  /// anahtarsız (AP kaynaklı) yolla devam eder. Servis katmanı (PF-02) ayrıca her depo çağrısını ≈6 sn'de
  /// sınırlar; bu ek emniyettir.
  static const Duration keyReadTimeout = Duration(seconds: 3);

  /// [uid] panosunun önbellekteki anahtarı: yalnızca **yerel** güvenli depo okuması (ağ yok). Okuma
  /// [keyReadTimeout] içinde dönmezse ya da hata verirse `null` (anahtarsız devam).
  @visibleForTesting
  static Future<String?> readCachedKey(AutomationState state, String uid) async {
    try {
      return await state.clock.bound<String?>(state.secureStorage.getLocalKey(uid), keyReadTimeout, () => null);
    } catch (_) {
      return null; // depo okunamadı: anahtarsız devam
    }
  }

  static Future<void> show(
    BuildContext context, {
    AutomationApiService? api,
    String? deviceUuid,
    Future<String?> Function(BuildContext context)? qrScanner,
  }) {
    final state = context.read<AutomationState>();
    return showAppDialog<void>(
      context,
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

  /// Parola panoya kopyalandı (simge ✓ olur; parola değişince ya da gizlenince eski haline döner).
  bool _apCopied = false;

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
    final uid = QrClaimParser.normalizeUid(status?.uid);
    // Panonun hazırlık durumu hatırlanır (bireysel-13): sahiplenme diyaloğu hazırlanmamış panoda eşlemeden önce uyarır.
    if (uid != null) _state.noteBoardProvisioned(uid, status?.provisioned);
    if (!_ownsApi) return; // çağıranın verdiği istemciye dokunulmaz
    _api.localKey = null;
    if (uid == null) return;
    final key = await WifiRecoveryDialog.readCachedKey(_state, uid);
    if (!mounted) return;
    if (AutomationApiService.isValidLocalKey(key)) _api.localKey = key;
  }

  /// Pano evin cihaz listesinde çevrimiçi ya da daha önce görülmüş mü (bulut kimliği panoda var; bireysel-1).
  bool _boardSeenOnline(String uid) =>
      _state.devices.any((d) => d.deviceUuid.toUpperCase() == uid && (d.online || d.lastSeenAt != null));

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
    setState(() => _apCopied = true);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Ağ parolası panoya kopyalandı.'), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardBorder = AppTheme.getCardBorder(context);
    final textPrimary = AppTheme.getTextPrimary(context);
    final textMuted = AppTheme.getTextMuted(context);

    // Cam gövde (ReplaceBoardDialog / SystemDoctorDialog ile AYNI dil: SurfaceCard, yarıçap [AppRadius.dialog] 24 — eskiden düz opak
    // yüzey ve 28 dp [AppRadius.sheet]'ti). Yatay boşluklar daraltıldı: 360 dp'de kullanılabilir genişlik 288 (kart içinde 264) dp'ydi
    // ve düğme etiketleri "Yeniden Kontrol / Et", "Panoya / Yükle" gibi yetim sözcüklerle sarıyordu; şimdi 8 dp kenar + 16 dp dolgu
    // ⇒ 312 dp (kart içinde 288).
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SurfaceCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          radius: AppRadius.dialog,
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                // Orb ve kapat düğmesi üstte (başlık/alt başlık 1.5 ölçekte 8 satıra çıkınca ikisi bloğun ortasında yüzmesin).
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OrbIconBadge(icon: Icons.router_rounded, family: AppFeature.wifiRecovery.accentFamily),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Dengeli satır sonu: dar diyalogda "Wi-Fi Kurulum & Kurtarma / Sihirbazı" gibi yetim son sözcük kalmaz
                        // (metin DEĞİŞMEZ; anahtar BalancedText'e verilir: testler yalnız varlığını denetler).
                        BalancedText(
                          'Wi-Fi Kurulum & Kurtarma Sihirbazı',
                          key: const Key('wifi_dialog_title'),
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary),
                        ),
                        Text(
                          'Modem veya şifre değiştiğinde panoyu yeniden bağlayın. İnternet ve giriş gerekmez.',
                          style: TextStyle(fontSize: AppText.caption, color: textMuted),
                        ),
                      ],
                    ),
                  ),
                  GlassIconButton(
                    key: const Key('btn_close'),
                    icon: Icons.close_rounded,
                    semanticLabel: 'Kapat',
                    onTap: () => Navigator.of(context).pop(),
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
                // Servis rolü yoksa hazırlanmamış panoda sihirbaz önerilmez (bireysel-13); eski yazılım uyarısı (bireysel-1).
                serviceMode: ServiceSetupAccess.fromState(_state) != null,
                boardSeenOnline: _boardSeenOnline,
                onResult: (result) {
                  if (result.isSuccess && mounted) setState(() => _done = true);
                },
              ),
              if (_done) ...[
                const SizedBox(height: 14),
                Text(
                  // Sahiplenilmemiş pano buluta bağlanmaz (bireysel-11): eşleme yolu söylenir.
                  'Pano sahiplenildiyse birkaç dakika içinde buluta bağlanır; henüz sahiplenmediyseniz etiketteki 1. '
                  'karekodla eşleyin.',
                  key: const Key('wifi_done_text'),
                  style: TextStyle(fontSize: 12.5, color: textMuted, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  key: const Key('btn_wifi_done'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: accentButtonStyle(AppFamilies.emerald),
                  child: const Text('Tamam'),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }

  /// Adım 1: telefonu panonun kurulum ağına bağlama yönergesi (parola etiketten; sabit parola yok).
  ///
  /// Yönerge tek `Text` kalır (`wifi_step_ap_text`: testler düz metnini okur); numaralı maddeler kalın numarayla ve
  /// geniş satır aralığıyla ayrışır (`Text.rich`; düz metin birebir aynıdır).
  Widget _buildApStep(Color textPrimary, Color textMuted) {
    final hint = _apSsidHint(_expectedUid);
    final numberStyle = TextStyle(fontWeight: FontWeight.w800, color: textPrimary);
    // Maddeler: (numara, metin). Metinler ve sırası DEĞİŞMEZ (pinli test: "4. Telefon ... koruyun", "5. Bağlandıktan ...").
    final items = <(String, String)>[
      ('1. ', 'Telefonunuzun Wi-Fi ayarlarını açın.'),
      (
        '2. ',
        '${hint == null ? 'Pano etiketindeki "KURULUM Wi-Fi AĞI" (AHBU-XXXXXX biçiminde)' : '"$hint"'} ağına bağlanın.',
      ),
      (
        '3. ',
        'Ağ parolası cihaza özeldir: pano etiketindeki "AĞ PAROLASI (AP)" değerini girin. '
            'Kolay yol: etiketteki ikinci karekodu (Wi-Fi karekodu) telefonunuzun kamerasıyla okutup çıkan '
            '"Ağa bağlan" önerisine dokunun.',
      ),
      ('4. ', 'Telefon "internet yok" uyarısı verirse bağlantıyı koruyun${_mobileDataNote()}'),
      ('5. ', 'Bağlandıktan sonra bu ekrana dönüp "Bağlantıyı Test Et"e dokunun.'),
    ];
    return SurfaceCard(
      key: const Key('wifi_step_ap'),
      accent: AppFamilies.sky.base,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Adım 1: Telefonu panonun kurulum ağına bağlayın',
            key: const Key('wifi_step_ap_title'),
            // Açık temada ham primaryBlueLight beyaz üstünde ≈ 2.4:1'di: tema duyarlı AA bağlantı tonu.
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: AppTheme.infoText(context)),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Pano kendi kurulum ağını yayınlar; bu işlem için internet ve hesap girişi gerekmez.\n',
                ),
                for (var i = 0; i < items.length; i++) ...[
                  TextSpan(text: items[i].$1, style: numberStyle),
                  TextSpan(text: items[i].$2 + (i == items.length - 1 ? '' : '\n')),
                ],
              ],
            ),
            key: const Key('wifi_step_ap_text'),
            style: TextStyle(fontSize: 13, color: textMuted, height: 1.5),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('field_ap_password'),
            controller: _apPassword,
            obscureText: _apObscure,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _apCopied = false),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Etiketteki ağ parolası',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              helperText: 'İsteğe bağlı. Yalnızca kopyalamak içindir; kaydedilmez, hiçbir yere gönderilmez.',
              // Gizlilik güvencesinin son sözcüğü ("gönderilmez") 1.5 yazı ölçeğinde kesilmesin.
              helperMaxLines: 6,
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
                    icon: Icon(
                      _apCopied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                      color: _apCopied ? AppTheme.accentTone(context, AppFamilies.emerald) : null,
                    ),
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
