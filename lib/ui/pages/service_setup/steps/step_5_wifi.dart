import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../services/board_network_binding.dart';
import '../../../../utils/qr_router.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/orb/orb.dart';
import '../../../widgets/settings/accent_button.dart';
import '../../../common/validators.dart' show WifiValidators;
import '../../../common/wifi_provision_panel.dart';
import '../logic/wifi_logic.dart';
import '../service_setup_controller.dart';
import '../panel/service_glass.dart' show ServiceTintBox;
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';
import 'step_common.dart';

/// Adım 5 - Wi-Fi Kurulumu (**internetsiz ve anahtarsız**): telefonu kurulum ağına bağla -> pano kimliğini
/// anahtarsız doğrula -> ev Wi-Fi bilgisini **E2'nin paylaşılan Wi-Fi bileşeniyle** ([WifiProvisionPanel]:
/// bağlantı testi, ağ taraması, karekod, gönderme, sonuç bekleme) gönder -> sonucu bekle -> telefonu ev
/// Wi-Fi'sine geri al (6. adım internet ister).
///
/// Kurulum ağında internet yoktur: bu adımda hiçbir sunucu çağrısı ve cihaz anahtarı kullanılmaz; Wi-Fi
/// uçları AP'den anahtarsız çalışır (CONTRACTS §3d). Wi-Fi şifresi bu sayfada saklanmaz (bileşen içinde
/// kalır). Etiketteki kurulum ağı parolası yalnızca bellekte tutulur, panoya kopyalanamaz.
class Step5Wifi extends StatefulWidget {
  const Step5Wifi({super.key, required this.controller, required this.scanner});

  final ServiceSetupController controller;
  final SetupScanner scanner;

  @override
  State<Step5Wifi> createState() => _Step5WifiState();
}

class _Step5WifiState extends State<Step5Wifi> {
  final TextEditingController _apPass = TextEditingController();
  final TextEditingController _lanIp = TextEditingController();
  final TextEditingController _key = TextEditingController();
  bool _showLan = false;

  /// Kurulum ağı adı panoya kopyalandı (düğme ✓ gösterir).
  bool _ssidCopied = false;

  /// Etiketteki 2. karekoddan (kurulum ağı Wi-Fi karekodu) okunan parola: yalnızca bellekte, gösterim için.
  String? _labelPassword;
  bool _labelPasswordVisible = false;
  String? _labelScanError;

  @override
  void initState() {
    super.initState();
    // Pano zaten ev ağında görünüyorsa (mevcut cihaz) "IP ile bağlan" kartı baştan açıktır.
    _showLan = !widget.controller.wifi.usingSetupNetwork;
  }

  @override
  void dispose() {
    _apPass.dispose();
    _lanIp.dispose();
    _key.dispose();
    super.dispose();
  }

  WifiLogic get _w => widget.controller.wifi;

  Future<String?> Function(BuildContext)? get _panelScanner {
    // Gerçek kamera tarayıcısı: panelin kendi tarayıcısı (yalnızca geçerli Wi-Fi karekodunu kabul eder).
    if (identical(widget.scanner, defaultSetupScanner)) return null;
    return (context) => widget.scanner(
          context,
          title: 'Wi-Fi Karekodu',
          hint: 'Modem etiketindeki veya telefonunuzdaki Wi-Fi karekodunu çerçeveye hizalayın',
        );
  }

  /// Pano etiketindeki 2. karekod (kurulum ağı): parola ekranda gösterilir (yazmak için) ve ilk hazırlık
  /// alanına aktarılır. Başka panoya ait karekod reddedilir.
  Future<void> _scanApLabel() async {
    final raw = await widget.scanner(
      context,
      title: 'Kurulum ağı karekodu',
      hint: 'Pano etiketindeki Wi-Fi simgeli ikinci karekodu çerçeveye hizalayın',
    );
    if (raw == null || !mounted) return;
    final payload = QrRouter.route(raw);
    if (payload is! QrWifi) {
      setState(() => _labelScanError = payload is QrUnknown ? payload.message : 'Bu karekod bir Wi-Fi karekodu değil.');
      return;
    }
    final expected = WifiLogic.apSsidFor(widget.controller.target?.deviceUuid ?? '');
    final creds = payload.credentials;
    // Modemin (ev) karekodu bu düğmeyle okutuldu: ev Wi-Fi bilgisi ancak telefon kurulum ağına bağlanıp pano
    // doğrulandıktan sonra açılan "2) Müşterinin ev Wi-Fi bilgisi" bölümünde okutulur.
    if (!WifiValidators.isBoardSetupNetwork(creds.ssid)) {
      setState(() => _labelScanError =
          'Bu, modemin (ev) Wi-Fi karekodu (${creds.ssid}). Bu düğme yalnızca pano etiketindeki kurulum ağı (AHBU-...) '
          'karekodu içindir. Ev Wi-Fi karekodunu okutmak için önce telefonu panonun kurulum ağına bağlayıp '
          '"Bağlandım: Panoyu Kontrol Et"e basın (yeni panoda ardından "Panoyu Hazırla"); sonra açılan '
          '"2) Müşterinin ev Wi-Fi bilgisi" bölümündeki "Modem Wi-Fi Karekodu Tara" düğmesini kullanın.');
      return;
    }
    if (expected != null && creds.ssid != expected) {
      setState(() => _labelScanError =
          'Bu karekod başka bir panonun kurulum ağına (${creds.ssid}) ait. Kurulum yaptığınız panonun ($expected) etiketini okutun.');
      return;
    }
    setState(() {
      _labelScanError = null;
      _labelPassword = creds.password;
      _labelPasswordVisible = false;
      if (_apPass.text.isEmpty) _apPass.text = creds.password;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final w = _w;

    return stepScaffold(
      context,
      c,
      5,
      continueHint: 'Devam etmek için panonun ev Wi-Fi ağına bağlandığı pano tarafından doğrulanmalı.',
      statusText: w.connected ? 'Pano ev ağında' : null,
      // Adımın kendi gradyan birincil eylemi ("Bağlandım: Panoyu Kontrol Et" / paneldeki "Yükle") ekrandadır: hata kutusundaki
      // "Tekrar dene" çerçeveli ikincil olur (ekranda tek gradyan birincil).
      retrySecondary: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (w.connected)
            _connectedCard(context)
          else ...[
            _connectCard(context, c),
            if (w.identity != null) _identityCard(context),
            if (w.needsProvision) _provisionCard(context),
            if (w.awaitingReconnect) _reconnectCard(context, c),
            if (w.deviceReady) _panelCard(context, c),
            if (w.lostContact || _showLan) _lanCard(context),
            if (!w.lostContact)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('btn_toggle_lan'),
                  style: setupInlineActionStyle(),
                  onPressed: () => setState(() => _showLan = !_showLan),
                  icon: Icon(
                    _showLan ? Icons.expand_less_rounded : Icons.lan_rounded,
                    size: accentIconSize(context, base: 18),
                  ),
                  label: Text(_showLan ? 'IP ile bağlanmayı gizle' : 'Pano zaten ev ağında: IP ile bağlan'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _connectCard(BuildContext context, ServiceSetupController c) {
    final w = _w;
    final uid = c.target?.deviceUuid ?? '';
    final apSsid = WifiLogic.apSsidFor(uid);
    final muted = SetupColors.muted(context);
    return SetupCard(
      key: const Key('wifi_connect_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '1) Telefonu panonun kurulum ağına bağlayın',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 6),
          if (!w.usingSetupNetwork)
            SetupInfoRow(
              key: const Key('wifi_on_lan_note'),
              icon: Icons.lan_rounded,
              color: SetupColors.info,
              text: 'Pano şu an ev ağında görünüyor (${c.target?.ip ?? ''}). Ev Wi-Fi bilgisini DEĞİŞTİRMEK için telefonu '
                  'panonun kurulum ağına bağlayın (ev ağına ulaşamayan pano kurulum ağını kendiliğinden açar); yalnızca '
                  'bağlantıyı doğrulamak için aşağıdaki "IP ile bağlan" kartını kullanın.',
            ),
          Row(
            children: [
              Expanded(
                child: SetupInfoRow(
                  icon: Icons.wifi_tethering_rounded,
                  bold: true,
                  text: apSsid == null ? 'Ağ adı: "AHBU-" ile başlayan ağ' : 'Ağ adı: $apSsid',
                ),
              ),
              if (apSsid != null)
                GlassIconButton(
                  key: const Key('btn_copy_ap_ssid'),
                  icon: _ssidCopied ? Icons.check_rounded : Icons.copy_rounded,
                  iconColor: _ssidCopied ? SetupColors.readable(context, SetupColors.ok) : null,
                  semanticLabel: 'Ağ adını kopyala',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: apSsid));
                    setState(() => _ssidCopied = true);
                  },
                ),
            ],
          ),
          const SetupInfoRow(
            icon: Icons.lock_outline_rounded,
            text: 'Parola: pano etiketindeki "AĞ PAROLASI (AP)" satırında yazar (cihaza özeldir). Kolay yol: etiketteki '
                'ikinci karekodu (Wi-Fi simgeli) telefon kamerasıyla okutup "Bağlan"a dokunun.',
          ),
          const SetupInfoRow(
            icon: Icons.public_off_rounded,
            text: 'Bu adım internet GEREKTİRMEZ: telefon "bu ağda internet yok" derse "Yine de bağlı kal" deyin.',
          ),
          if (_labelPassword != null) _labelPasswordRow(context),
          TextButton.icon(
            key: const Key('btn_scan_ap_qr'),
            style: setupInlineActionStyle(),
            onPressed: w.busy ? null : _scanApLabel,
            icon: Icon(Icons.qr_code_scanner_rounded, size: accentIconSize(context, base: 18)),
            label: const Text('Etiketteki kurulum ağı karekodunu uygulamayla oku (parolayı göster)'),
          ),
          if (_labelScanError != null)
            SetupInfoRow(
              key: const Key('ap_label_scan_error'),
              icon: Icons.error_outline_rounded,
              color: SetupColors.error,
              text: _labelScanError!,
            ),
          const SizedBox(height: 4),
          Text(
            // Android: uygulama pano ağını kendisi seçer (BoardNetworkBinding); diğer platformlarda eski yönerge.
            BoardNetworkBinding.instance.isSupported
                ? BoardNetworkBinding.mobileDataAdvice
                : 'Mobil veri açıksa ve telefon panoya ulaşamıyorsa mobil veriyi geçici olarak kapatın.',
            key: const Key('wifi_mobile_data_note'),
            style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_check_device'),
            label: 'Bağlandım: Panoyu Kontrol Et',
            icon: Icons.network_check_rounded,
            busy: w.busy && w.busyLabel == WifiLogic.checkLabel,
            onPressed: w.busy ? null : () => w.checkDevice(),
          ),
        ],
      ),
    );
  }

  /// Etiketteki kurulum ağı parolası: gizli gösterilir, göz simgesiyle açılır; KOPYALAMA düğmesi yoktur.
  Widget _labelPasswordRow(BuildContext context) {
    final password = _labelPassword!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.vpn_key_outlined, size: 18, color: SetupColors.muted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _labelPasswordVisible ? password : '•' * password.length.clamp(8, 32),
              key: const Key('ap_label_password'),
              style: SetupText.mono(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: SetupColors.text(context),
              ),
            ),
          ),
          IconButton(
            key: const Key('btn_toggle_ap_password'),
            tooltip: _labelPasswordVisible ? 'Gizle' : 'Göster',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(_labelPasswordVisible ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 20),
            onPressed: () => setState(() => _labelPasswordVisible = !_labelPasswordVisible),
          ),
        ],
      ),
    );
  }

  Widget _identityCard(BuildContext context) {
    final w = _w;
    final id = w.identity!;
    return SetupCard(
      key: const Key('wifi_identity_card'),
      accent: SetupColors.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SetupResultHeader(
            text: 'Doğru pano bulundu: ${id.uid}${(id.firmware ?? '').isEmpty ? '' : ' • yazılım ${id.firmware}'}',
          ),
          if (id.provisioned == false)
            const SetupInfoRow(
              icon: Icons.build_circle_rounded,
              text: 'Pano henüz hazırlanmamış: kurulum ağı şu an parolasız (açık). Önce ilk hazırlık yapılacak.',
              color: SetupColors.warn,
            )
          else
            const SetupInfoRow(
              icon: Icons.key_off_rounded,
              text: 'Wi-Fi ayarları kurulum ağından anahtarsız yapılır; cihaz anahtarı bu adımda gerekmez.',
              color: SetupColors.ok,
            ),
        ],
      ),
    );
  }

  Widget _provisionCard(BuildContext context) {
    final w = _w;
    final hasKey = w.hasProvisionKey;
    return SetupCard(
      key: const Key('wifi_provision_card'),
      accent: SetupColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pano ilk kez hazırlanacak',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 4),
          Text(
            'Etiketteki "AĞ PAROLASI (AP)" değerini yazın. Pano kurulum ağını bu parolayla (WPA2) yeniden başlatır; '
            'telefonunuz Wi-Fi\'dan düşer ve ağa bu parolayla yeniden bağlanmanız gerekir.',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          if (!hasKey) ...[
            SetupCard(
              key: const Key('wifi_provision_nokey'),
              accent: SetupColors.error,
              margin: const EdgeInsets.only(top: 10),
              child: const SetupInfoRow(
                icon: Icons.key_off_rounded,
                color: SetupColors.error,
                text: 'Cihaz anahtarı bellekte yok. Kurulum ağında internet olmadığı için sunucudan alınamıyor: telefonu '
                    'geçici olarak internete bağlayıp "Anahtarı Sunucudan Al"a basın ya da anahtarı elle girin.',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('btn_fetch_key'),
              onPressed: w.busy ? null : () => w.fetchKeyForProvision(),
              icon: Icon(Icons.cloud_download_rounded, size: accentIconSize(context, base: 18)),
              label: const Text('Anahtarı Sunucudan Al (internet gerekir)'),
              // Çerçeve + metin + simge AYNI aileden ve AA (tema varsayılan çerçevesi açıkta ≈ 2.4:1'di).
              style: accentOutlinedButtonStyle(context, AppFamilies.sky),
            ),
            _manualKeyFields(context),
          ],
          SecretField(
            key: const Key('field_ap_pass'),
            controller: _apPass,
            label: 'Kurulum ağı parolası',
            prefixIcon: Icons.wifi_password_rounded,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => w.provision(apPass: _apPass.text),
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_factory_init'),
            label: 'Panoyu Hazırla',
            icon: Icons.build_rounded,
            busy: w.busy && w.busyLabel == WifiLogic.provisionLabel,
            onPressed: w.busy || !hasKey
                ? null
                : () async {
                    final ok = await w.provision(apPass: _apPass.text);
                    if (ok && mounted) _apPass.clear();
                  },
          ),
        ],
      ),
    );
  }

  Widget _manualKeyFields(BuildContext context) {
    final w = _w;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SecretField(
          key: const Key('field_local_key'),
          controller: _key,
          label: 'Cihaz anahtarı (elle)',
          helperText: 'Fabrika/servis kaydındaki 8-32 karakterlik anahtar.',
          prefixIcon: Icons.key_rounded,
          monospace: true,
          onSubmitted: (_) => w.useManualKey(_key.text.trim()),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('btn_use_key'),
          onPressed: w.busy
              ? null
              : () {
                  if (w.useManualKey(_key.text.trim()) && mounted) _key.clear();
                },
          icon: Icon(Icons.vpn_key_rounded, size: accentIconSize(context, base: 18)),
          label: const Text('Bu Anahtarı Kullan'),
          style: accentOutlinedButtonStyle(context, AppFamilies.sky),
        ),
      ],
    );
  }

  Widget _reconnectCard(BuildContext context, ServiceSetupController c) {
    final apSsid = WifiLogic.apSsidFor(c.target?.deviceUuid ?? '');
    return SetupCard(
      key: const Key('wifi_reconnect_card'),
      accent: SetupColors.info,
      child: SetupInfoRow(
        icon: Icons.sync_rounded,
        text: 'Pano hazırlandı. Kurulum ağı şimdi parolalı olarak yeniden başlıyor (birkaç saniye). '
            'Telefonunuzu ${apSsid ?? '"AHBU-..."'} ağına etiketteki parola ile yeniden bağlayın, sonra '
            '"Bağlandım: Panoyu Kontrol Et"e basın.',
      ),
    );
  }

  /// 2) Ev Wi-Fi bilgisi: E2'nin paylaşılan Wi-Fi bileşeni (kopya yok).
  Widget _panelCard(BuildContext context, ServiceSetupController c) {
    final w = _w;
    return SetupCard(
      key: const Key('wifi_form_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '2) Müşterinin ev Wi-Fi bilgisi',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 4),
          Text(
            'Listeden müşterinin ağını seçin (ya da modem karekodunu okutun), şifresini yazıp gönderin. Pano bağlanana '
            'kadar bekleyin; telefonunuz kurulum ağından düşerse beklemeye devam edin.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: SetupColors.muted(context)),
          ),
          const SizedBox(height: 10),
          WifiProvisionPanel(
            key: const Key('wifi_provision_panel'),
            api: w.apApi,
            clock: c.ctx.clock,
            expectedUid: c.target?.deviceUuid,
            enabled: w.deviceReady && !w.busy,
            disabledMessage: 'Önce panonun kimliği doğrulanmalı.',
            autoCheck: true,
            qrScanner: _panelScanner,
            onResult: w.acceptWifiResult,
          ),
        ],
      ),
    );
  }

  Widget _lanCard(BuildContext context) {
    final w = _w;
    return SetupCard(
      key: const Key('wifi_lan_card'),
      accent: w.lostContact ? SetupColors.warn : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w.lostContact ? 'Pano ev ağına bağlanmış olabilir' : 'Pano ev ağında: IP ile bağlan',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 4),
          Text(
            w.lostContact
                ? 'Deneme sırasında panoyla bağlantı koptu: pano kurulum ağını kapatmış olabilir. Telefonunuzu ev '
                    'Wi-Fi ağına bağlayın ve panonun IP adresini yazın (modem arayüzündeki cihaz listesinde görünür). '
                    'Bu doğrulama anahtar ve internet gerektirmez.'
                : 'Pano ev ağına daha önce bağlandıysa telefonunuzu ev Wi-Fi ağına alıp panonun IP adresini yazın.',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          SetupTextField(
            key: const Key('field_lan_ip'),
            controller: _lanIp,
            label: 'Pano IP adresi',
            hint: '192.168.1.40',
            prefixIcon: Icons.lan_rounded,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => w.confirmLanIp(_lanIp.text),
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_confirm_lan'),
            label: 'Bu IP ile Doğrula',
            icon: Icons.verified_rounded,
            busy: w.busy && w.busyLabel == WifiLogic.lanLabel,
            onPressed: w.busy ? null : () => w.confirmLanIp(_lanIp.text),
          ),
        ],
      ),
    );
  }

  Widget _connectedCard(BuildContext context) {
    final w = _w;
    final ip = widget.controller.target?.ip ?? w.homeIp ?? '';
    // Pano ev ağındaki adresini bildirdiyse hedef artık kurulum ağı adresi değildir.
    final ipKnown = ip.isNotEmpty && !w.usingSetupNetwork;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupCard(
          key: const Key('wifi_connected_card'),
          accent: SetupColors.ok,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SetupResultHeader(text: 'Pano ev Wi-Fi ağına bağlandı${ipKnown ? ' (IP: $ip)' : ''}.'),
              const SizedBox(height: 6),
              // Adımın en kritik eylemi: ağ değişimi unutulursa 6. adım hata verir. Sıradan gövde metni değil, amber uyarı kutusu.
              const ServiceTintBox(
                key: Key('wifi_return_home_notice'),
                color: SetupColors.warn,
                child: SetupInfoRow(
                  icon: Icons.phone_android_rounded,
                  color: SetupColors.warn,
                  bold: true,
                  text: 'ŞİMDİ telefonunuzu panonun kurulum ağından çıkarıp müşterinin ev Wi-Fi ağına geri bağlayın '
                      '(internet gelmeli).',
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  '6. adım panoya bu ağdan bağlanır, cihaz anahtarını sunucudan alır ve bulut kimliğini yazar.',
                  style: TextStyle(fontSize: AppText.caption, height: 1.35, color: SetupColors.muted(context)),
                ),
              ),
              if (!ipKnown)
                const SetupInfoRow(
                  icon: Icons.info_outline_rounded,
                  color: SetupColors.warn,
                  text: 'Panonun ev ağındaki adresi (IP) bildirilmedi: 6. adımda modem arayüzündeki cihaz listesinden '
                      'IP adresini yazmanız gerekecek.',
                ),
            ],
          ),
        ),
      ],
    );
  }
}
