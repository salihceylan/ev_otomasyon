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

  /// Kurulum ağı parolasının ikinci yazımı (uygulama-ekranlar-3).
  final TextEditingController _apPassConfirm = TextEditingController();
  final TextEditingController _lanIp = TextEditingController();
  final TextEditingController _key = TextEditingController();

  /// Elle girilen anahtarın ikinci yazımı (servis_kurulum-5).
  final TextEditingController _keyConfirm = TextEditingController();
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
    _apPassConfirm.dispose();
    _lanIp.dispose();
    _key.dispose();
    _keyConfirm.dispose();
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
      // Etiketteki parola esastır: elle yazılmış (belki yanlış) değerin üstüne yazılır (uygulama-ekranlar-3).
      _apPass.text = creds.password;
      _apPassConfirm.text = creds.password;
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
          else if (w.ethernetMode) ...[
            _ethernetChoice(context),
            _ethernetCard(context),
            // Ethernet'le ev ağında ama hazırlanmamış pano: ilk hazırlık Ethernet adresinden (servis_kurulum-1).
            if (w.needsProvision) _provisionCard(context, ethernet: true),
          ] else ...[
            _ethernetChoice(context),
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
            onPressed: w.busy ? null : _checkDevice,
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

  /// İlk hazırlık kartı. [ethernet]: pano Ethernet'le ev ağında (telefon ev ağında, internet var): anahtar sunucudan
  /// otomatik alınır (süper yöneticide elle girilir) ve hazırlık panonun Ethernet adresine yapılır (servis_kurulum-1).
  Widget _provisionCard(BuildContext context, {bool ethernet = false}) {
    final w = _w;
    final hasKey = w.hasProvisionKey;
    final isSuper = widget.controller.access.isSuperUser;
    // Ethernet yolunda personel / servis oturumu anahtarı hazırlık sırasında sunucudan alır.
    final keyFetchedOnTheFly = ethernet && !isSuper;
    final canProvision = hasKey || keyFetchedOnTheFly;
    Future<void> provision() async {
      final ok = ethernet
          ? await w.provisionViaEthernet(
              ip: w.ethProvisionIp ?? _lanIp.text,
              apPass: _apPass.text,
              apPassConfirm: _apPassConfirm.text,
              labelPassword: _labelPassword,
            )
          : await w.provision(apPass: _apPass.text, apPassConfirm: _apPassConfirm.text, labelPassword: _labelPassword);
      // Ethernet yolunda hazırlık yanıtla doğrulanır; kurulum ağı yolunda alanlar yeniden bağlantı doğrulanınca temizlenir.
      if (ok && mounted && ethernet) _clearApPass();
    }

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
            ethernet
                ? 'Etiketteki "AĞ PAROLASI (AP)" değerini yazın. İlk hazırlık panoya cihaz anahtarını ve kurulum ağı '
                    'parolasını Ethernet adresinden yazar; kablolu bağlantı kesilmez.'
                : 'Etiketteki "AĞ PAROLASI (AP)" değerini yazın. Pano kurulum ağını bu parolayla (WPA2) yeniden başlatır; '
                    'telefonunuz Wi-Fi\'dan düşer ve ağa bu parolayla yeniden bağlanmanız gerekir.',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          if (!hasKey && keyFetchedOnTheFly)
            const SetupInfoRow(
              key: Key('wifi_provision_key_auto'),
              icon: Icons.cloud_download_rounded,
              color: SetupColors.info,
              text: 'Cihaz anahtarı hazırlık sırasında sunucudan alınır (telefon ev ağında, internet gerekir).',
            )
          else if (!hasKey && ethernet) ...[
            const SetupInfoRow(
              key: Key('wifi_provision_nokey'),
              icon: Icons.key_off_rounded,
              color: SetupColors.error,
              text: 'Süper yönetici hesabına cihaz anahtarı verilmez: fabrika/servis kaydındaki anahtarı elle girin.',
            ),
            _manualKeyFields(context),
          ] else if (!hasKey) ...[
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
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 8),
          // İkinci yazım (uygulama-ekranlar-3): ilk hazırlık geri alınamaz; uyuşmazsa panoya yazılmaz.
          SecretField(
            key: const Key('field_ap_pass_confirm'),
            controller: _apPassConfirm,
            label: 'Kurulum ağı parolası (tekrar)',
            prefixIcon: Icons.wifi_password_rounded,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!w.busy && canProvision) provision();
            },
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_factory_init'),
            label: 'Panoyu Hazırla',
            icon: Icons.build_rounded,
            busy: w.busy && w.busyLabel == WifiLogic.provisionLabel,
            onPressed: w.busy || !canProvision ? null : provision,
          ),
        ],
      ),
    );
  }

  void _clearApPass() {
    _apPass.clear();
    _apPassConfirm.clear();
  }

  /// "Bağlandım: Panoyu Kontrol Et": hazırlıktan sonra yeniden bağlantı doğrulanınca kurulum ağı parolası alanları
  /// temizlenir (uygulama-ekranlar-3).
  Future<void> _checkDevice() async {
    final ok = await _w.checkDevice();
    if (ok && mounted && !_w.needsProvision) _clearApPass();
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
        ),
        const SizedBox(height: 8),
        // İkinci yazım (servis_kurulum-5): uyuşmazsa anahtar kullanılmaz, "Panoyu Hazırla" kapalı kalır.
        SecretField(
          key: const Key('field_local_key_confirm'),
          controller: _keyConfirm,
          label: 'Cihaz anahtarı (tekrar)',
          prefixIcon: Icons.key_rounded,
          monospace: true,
          onSubmitted: (_) => _useManualKey(),
        ),
        const SetupInfoRow(
          key: Key('manual_key_warning'),
          icon: Icons.warning_amber_rounded,
          color: SetupColors.warn,
          text: 'Yanlış anahtar panonun bulut bağlantısını bozar ve USB gerektirir.',
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('btn_use_key'),
          onPressed: w.busy ? null : _useManualKey,
          icon: Icon(Icons.vpn_key_rounded, size: accentIconSize(context, base: 18)),
          label: const Text('Bu Anahtarı Kullan'),
          style: accentOutlinedButtonStyle(context, AppFamilies.sky),
        ),
      ],
    );
  }

  /// Elle girilen anahtarı iki yazımla birlikte kullanır; başarıda alanlar temizlenir.
  void _useManualKey() {
    if (_w.useManualKey(_key.text.trim(), confirm: _keyConfirm.text.trim()) && mounted) {
      _key.clear();
      _keyConfirm.clear();
    }
  }

  /// "Ağ bağlantısını yeniden kur" (servis_kurulum-7): tamamlanmış 5. adım baştan yapılabilir (meşgulken kapalı).
  Widget _restartNetworkButton(BuildContext context) {
    final w = _w;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('btn_restart_network_setup'),
        style: setupInlineActionStyle(),
        onPressed: w.busy ? null : w.restartNetworkSetup,
        icon: Icon(Icons.restart_alt_rounded, size: accentIconSize(context, base: 18)),
        label: const Text('Ağ bağlantısını yeniden kur'),
      ),
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
            serviceMode: true, // servis sihirbazı: hazırlık yönlendirmesi sihirbaza
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

  /// "Pano kabloyla (Ethernet) bağlı" seçimi: açıkken kurulum ağı / ev Wi-Fi adımları gizlenir.
  Widget _ethernetChoice(BuildContext context) {
    final w = _w;
    return SetupCard(
      key: const Key('wifi_ethernet_choice'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SetupCheckTile(
        key: const Key('check_ethernet_mode'),
        value: w.ethernetMode,
        onChanged: w.busy ? null : (v) => w.setEthernetMode(v),
        label: 'Pano kabloyla (Ethernet) bağlı',
      ),
    );
  }

  /// Ethernet yolu: panonun kablolu IP'si ile doğrulama (kurulum ağı ve Wi-Fi bilgisi gerekmez).
  Widget _ethernetCard(BuildContext context) {
    final w = _w;
    final suggested = w.identity?.ethIp ?? '';
    if (_lanIp.text.isEmpty && suggested.isNotEmpty) _lanIp.text = suggested;
    return SetupCard(
      key: const Key('wifi_ethernet_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pano ev ağına kabloyla bağlı',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
          ),
          const SizedBox(height: 4),
          Text(
            'Kurulum ağına bağlanmanız ve Wi-Fi bilgisi göndermeniz gerekmez. Telefonunuzu ev ağına (Wi-Fi) bağlayın ve '
            'panonun kablolu IP adresini yazın (modem arayüzündeki cihaz listesinde görünür).',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          SetupTextField(
            key: const Key('field_eth_ip'),
            controller: _lanIp,
            label: 'Panonun Ethernet IP adresi',
            hint: '192.168.1.40',
            prefixIcon: Icons.settings_ethernet_rounded,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => w.confirmEthernet(_lanIp.text),
          ),
          const SizedBox(height: 12),
          SetupPrimaryButton(
            key: const Key('btn_confirm_ethernet'),
            label: 'Ethernet ile Doğrula',
            icon: Icons.settings_ethernet_rounded,
            busy: w.busy && w.busyLabel == WifiLogic.ethLabel,
            onPressed: w.busy ? null : () => w.confirmEthernet(_lanIp.text),
          ),
        ],
      ),
    );
  }

  Widget _connectedCard(BuildContext context) {
    final w = _w;
    if (w.viaEthernet) {
      final ethIp = widget.controller.target?.ip ?? w.homeIp ?? '';
      return SetupCard(
        key: const Key('wifi_connected_card'),
        accent: SetupColors.ok,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SetupResultHeader(
              key: const Key('wifi_connected_ethernet'),
              text: 'Pano ev ağına Ethernet ile bağlı${ethIp.isEmpty ? '' : ' (IP: $ethIp)'}.',
            ),
            const SizedBox(height: 6),
            const SetupInfoRow(
              icon: Icons.info_outline_rounded,
              color: SetupColors.info,
              text: '6. adım panoya bu adresten bağlanır ve bulut kimliğini yazar (telefon ev ağında, internet gerekir).',
            ),
            _restartNetworkButton(context),
          ],
        ),
      );
    }
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
              _restartNetworkButton(context),
            ],
          ),
        ),
      ],
    );
  }
}
