import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/automation_models.dart';
import '../../services/automation_api_service.dart';
import '../../services/clock.dart';
import '../../utils/wifi_qr_parser.dart';
import '../pages/claim/qr_scanner_page.dart';
import '../theme/app_theme.dart';
import 'cooldown.dart';
import 'inline_message.dart';
import 'validators.dart';

/// Pano Wi-Fi kurulum bileşeni (WP-E2; **Wi-Fi kurtarma diyaloğu ve servis kurulum sihirbazı
/// (F, adım 5) aynı bileşeni kullanabilir**): bağlantı testi -> ağ tarama -> bilgi girişi -> gönder ->
/// **bağlantı sonucunu bekle**.
///
/// **Güvenlik modeli (CONTRACTS §3d): internet ve giriş GEREKMEZ.** Panonun WPA2 kurulum ağından
/// (SoftAP) gelen istekler için yalnızca Wi-Fi uçları (`GET /api/wifi/scan`, `POST /api/wifi/connect`,
/// `GET /api/wifi/status`) `X-Device-Key` olmadan çalışır (cihaza özel AP parolasını bilmek = fiziksel
/// erişim). Bu bileşen sunucuya hiç istek atmaz; [api].localKey varsa cihaza gönderilir, yoksa
/// gönderilmez.
///
/// * [api]: çağıranın **kendi** [AutomationApiService] örneği (ana durumun adresine dokunulmaz).
///   Kurtarma/kurulum AP'si için `AutomationApiService.recoveryAp(...)` (adres `AppConfig.deviceApHost`).
/// * Başarı **yalnızca** `WifiConnectOutcome.success` ile gösterilir; zaman aşımı/hata/belirsiz
///   (bağlantı koptu: pano AP'yi kapattı) durumlarında açık mesaj ve "Yeniden dene" yolu vardır.
/// * SSID ve parola **kırpılmaz**; SSID <= 32 bayt (UTF-8), parola boş (açık ağ) ya da 8-63 bayt.
/// * Listeden ağ seçilince SSID dolar ve (şifreli ağda) **şifre kutusuna odaklanılır**.
/// * Tarama ve bekleme iptal edilebilir; bileşen kapanınca döngüler durur.
/// * QR (WIFI:...) yalnızca [WifiQrParser] geçerli dediğinde alanları doldurur; ham metin SSID olmaz.
/// * Pano, kısa sürede çok istek alırsa (`429`) bekleme süresi gösterilir ve gönder düğmesi o süre pasif olur.
class WifiProvisionPanel extends StatefulWidget {
  const WifiProvisionPanel({
    super.key,
    required this.api,
    this.onResult,
    this.connectTimeout = const Duration(seconds: 40),
    this.enabled = true,
    this.disabledMessage,
    this.autoCheck = false,
    this.qrScanner,
    this.expectedUid,
    this.onDeviceChecked,
    this.numberedSteps = false,
    this.clock = const SystemClock(),
  });

  final AutomationApiService api;

  /// Bağlanma denemesi sonuçlandığında (başarı, hata, zaman aşımı, belirsiz) çağrılır.
  final ValueChanged<WifiConnectResult>? onResult;

  /// Bağlanma sonucu için en uzun bekleme.
  final Duration connectTimeout;

  /// `false` ise düğmeler pasiftir ve [disabledMessage] gösterilir.
  final bool enabled;
  final String? disabledMessage;

  /// `true` ise bileşen açılınca bağlantı testi otomatik başlar.
  final bool autoCheck;

  /// Yalnızca testlerde/özel akışlarda: Wi-Fi karekodunu okuyan işlev (varsayılan: [QrScannerPage]).
  final Future<String?> Function(BuildContext context)? qrScanner;

  /// Çağıranın beklediği pano kimliği (`AHBU-S3-XXXXXX`). Bağlanılan panonun kimliği farklıysa
  /// **engellemeyen** bir uyarı gösterilir (yanlış panoya bilgi gitmesin).
  final String? expectedUid;

  /// Bağlantı testi sonucunda çağrılır (**taramadan önce beklenir**): başarıda pano durumuyla, pano
  /// bulunamazsa `null` ile. Çağıran, kimliği doğrulanmış panonun önbellekteki anahtarını `api.localKey`'e
  /// verebilir (ya da `null`da önceki panoya ait anahtarı temizler).
  final Future<void> Function(DeviceStatus? status)? onDeviceChecked;

  /// `true` ise bölüm başlıkları "Adım 2/3/4" ile numaralanır (kurtarma sihirbazı adım 1'i kendisi çizer).
  final bool numberedSteps;

  /// 429 bekleme sayacı için zaman kaynağı (testlerde sahte saat).
  final Clock clock;

  @override
  State<WifiProvisionPanel> createState() => WifiProvisionPanelState();
}

enum _Phase { idle, checking, scanning, submitting }

class WifiProvisionPanelState extends State<WifiProvisionPanel> {
  final TextEditingController _ssid = TextEditingController();
  final TextEditingController _pass = TextEditingController();
  final FocusNode _passFocus = FocusNode(debugLabel: 'wifi_password');
  late final Cooldown _rateLimit;

  _Phase _phase = _Phase.idle;
  bool _obscure = true;
  bool _connected = false;
  DeviceStatus? _deviceStatus;
  String? _mismatch;
  List<WifiNetwork> _networks = const <WifiNetwork>[];
  bool _scanned = false;

  /// Seçilen ağın şifreli olup olmadığı (taramadan; elle yazılan ağ için bilinmez).
  bool? _selectedSecured;

  String? _checkError;
  String? _scanError;
  String? _formError;
  WifiConnectResult? _result;

  /// İşlem sıra numarası: iptal ve bayat yanıtları ayırt eder.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _rateLimit = Cooldown(widget.clock, () {
      if (mounted) setState(() {});
    });
    _maybeAutoCheck();
  }

  /// Otomatik bağlantı testi bir kez yapılır: bileşen etkinken açıldığında ya da **pasif açılıp sonradan
  /// etkinleştiğinde** (ör. servis sihirbazı pano kimliğini doğruladıktan sonra).
  bool _autoChecked = false;

  void _maybeAutoCheck() {
    if (!widget.autoCheck || !widget.enabled || _autoChecked) return;
    _autoChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.enabled) {
        _autoChecked = false; // çerçeve gelmeden yeniden pasifleşti: sonraki etkinleşmede yeniden denenir
        return;
      }
      unawaited(_checkConnection());
    });
  }

  @override
  void didUpdateWidget(covariant WifiProvisionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) _maybeAutoCheck();
  }

  @override
  void dispose() {
    _run++; // bekleyen tarama/bekleme döngüleri durur
    _rateLimit.dispose();
    _ssid.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool _alive(int run) => mounted && run == _run;

  // ---------------------------------------------------------------------------
  // İşlemler
  // ---------------------------------------------------------------------------

  Future<void> _checkConnection() async {
    final run = ++_run;
    setState(() {
      _phase = _Phase.checking;
      _checkError = null;
      _formError = null;
      _result = null;
    });
    try {
      final status = await widget.api.fetchPublicStatus();
      if (!_alive(run)) return;
      setState(() {
        _connected = true;
        _deviceStatus = status;
        _mismatch = _mismatchMessage(status);
        if (status.provisioned == false) {
          _phase = _Phase.idle;
          _checkError =
              'Pano henüz kurulmamış görünüyor (fabrika kurulumu gerekir). Wi-Fi bilgileri bu aşamada gönderilemez.';
        }
      });
      if (status.provisioned == false) return;
      try {
        await widget.onDeviceChecked?.call(status); // örn. kimliği doğrulanmış panonun önbellek anahtarı
      } catch (_) {
        // Anahtar isteğe bağlıdır: hazırlanamazsa anahtarsız (AP kaynaklı) yolla devam edilir.
      }
      if (!_alive(run)) return;
      setState(() => _phase = _Phase.idle);
      unawaited(_scan());
    } catch (e) {
      if (!_alive(run)) return;
      setState(() {
        _connected = false;
        _deviceStatus = null;
        _mismatch = null;
        _phase = _Phase.idle;
        _checkError = _deviceError(e, whileChecking: true);
      });
      try {
        await widget.onDeviceChecked?.call(null); // önceki panoya ait durum/anahtar bırakılmaz
      } catch (_) {}
    }
  }

  String? _mismatchMessage(DeviceStatus status) {
    final expected = widget.expectedUid?.trim().toUpperCase();
    final actual = status.uid?.trim().toUpperCase();
    if (expected == null || expected.isEmpty || actual == null || actual.isEmpty) return null;
    if (expected == actual) return null;
    return 'Bağlandığınız pano ($actual), seçili pano ($expected) değil. Doğru panonun kurulum ağına '
        'bağlandığınızdan emin olun; farklı bir panoyu ayarlıyorsanız bu uyarıyı yok sayabilirsiniz.';
  }

  Future<void> _scan() async {
    final run = ++_run;
    setState(() {
      _phase = _Phase.scanning;
      _scanError = null;
    });
    try {
      final networks = await widget.api.scanWifi(refresh: true, isCancelled: () => !_alive(run));
      if (!_alive(run)) return;
      setState(() {
        _networks = networks;
        _scanned = true;
        _phase = _Phase.idle;
      });
    } on LocalApiException catch (e) {
      if (e.isCancelled || !_alive(run)) return;
      setState(() {
        _phase = _Phase.idle;
        _scanError = _deviceError(e);
      });
    } catch (e) {
      if (!_alive(run)) return;
      setState(() {
        _phase = _Phase.idle;
        _scanError = _deviceError(e);
      });
    }
  }

  /// Çalışan tarama / bağlantı bekleme işlemini bırakır.
  void _cancel() {
    final wasSubmitting = _phase == _Phase.submitting;
    _run++;
    setState(() {
      _phase = _Phase.idle;
      if (wasSubmitting) {
        _formError = 'Bekleme iptal edildi. Pano bağlanmayı sürdürüyor olabilir; '
            '"Pano Bağlantısını Test Et" ile durumu kontrol edebilirsiniz.';
      } else if (!_scanned) {
        _scanError = 'Tarama iptal edildi.';
      }
    });
  }

  Future<void> _scanQr() async {
    final scanner = widget.qrScanner ?? _defaultScanner;
    final raw = await scanner(context);
    if (raw == null || !mounted) return;
    final parsed = WifiQrParser.parseDetailed(raw);
    final credentials = parsed.credentials;
    if (credentials == null) {
      // Ham metin ASLA SSID alanına yazılmaz.
      setState(() => _formError = parsed.error?.message ?? 'Okunan karekod geçerli bir Wi-Fi karekodu değil.');
      return;
    }
    final modemError = _modemQrError(credentials);
    if (modemError != null) {
      setState(() => _formError = modemError);
      return;
    }
    setState(() {
      _ssid.text = credentials.ssid;
      _pass.text = credentials.password;
      _selectedSecured = credentials.isOpen ? false : true;
      _formError = null;
      _result = null;
    });
  }

  /// Karekodun **modemin** Wi-Fi bilgisi olarak kullanılamama nedeni (`null` = kullanılabilir): panonun
  /// kendi kurulum ağının (etiketteki ikinci karekod: `AHBU-<MAC6>`) karekodu telefon kamerasıyla okutulup
  /// ağa bağlanmak içindir; ev Wi-Fi bilgisi olarak panoya yüklenemez.
  static String? _modemQrError(WifiQrCredentials credentials) {
    if (!WifiValidators.isBoardSetupNetwork(credentials.ssid)) return null;
    return 'Bu karekod panonun KENDİ kurulum ağına aittir (AHBU-...). Onu telefonunuzun kamerasıyla okutup ağa '
        'bağlanın; burada ise modemin (ev) Wi-Fi karekodunu okutun.';
  }

  static Future<String?> _defaultScanner(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrScannerPage(
          title: 'Wi-Fi Karekodu Tara',
          hintText: 'Modem etiketindeki veya telefonunuzdaki Wi-Fi karekodunu hizalayın',
          validator: (raw) {
            final result = WifiQrParser.parseDetailed(raw);
            final credentials = result.credentials;
            if (credentials == null) return result.error?.message ?? 'Geçerli bir Wi-Fi karekodu değil.';
            return _modemQrError(credentials);
          },
        ),
      ),
    );
  }

  /// Listeden ağ seçimi: SSID dolar; şifreli ağda şifre kutusuna odaklanılır, açık ağda şifre temizlenir.
  void _selectNetwork(WifiNetwork net) {
    setState(() {
      _ssid.text = net.ssid;
      _selectedSecured = net.secured;
      if (!net.secured) _pass.clear();
      _formError = null;
      _result = null;
    });
    if (net.secured) {
      _passFocus.requestFocus();
    } else {
      _passFocus.unfocus();
    }
  }

  Future<void> _submit() async {
    if (_rateLimit.isActive) return;
    final ssid = _ssid.text; // KIRPILMAZ
    final pass = _pass.text;
    final error = WifiValidators.ssidError(ssid) ?? WifiValidators.passwordError(pass, networkSecured: _selectedSecured);
    if (error != null) {
      setState(() => _formError = error);
      return;
    }
    final run = ++_run;
    setState(() {
      _phase = _Phase.submitting;
      _formError = null;
      _result = null;
    });
    try {
      final result = await widget.api.connectWifiAndWait(
        ssid,
        pass,
        timeout: widget.connectTimeout,
        isCancelled: () => !_alive(run),
      );
      if (!_alive(run)) return;
      setState(() {
        _phase = _Phase.idle;
        _result = result;
      });
      widget.onResult?.call(result);
    } on LocalApiException catch (e) {
      if (e.isCancelled || !_alive(run)) return;
      setState(() {
        _phase = _Phase.idle;
        _formError = _deviceError(e);
      });
      if (e.statusCode == 429) _rateLimit.start(e.retryAfter ?? const Duration(seconds: 30));
    } catch (e) {
      if (!_alive(run)) return;
      setState(() {
        _phase = _Phase.idle;
        _formError = _deviceError(e);
      });
    }
  }

  void _retry() {
    setState(() {
      _result = null;
      _formError = null;
    });
  }

  String _deviceError(Object error, {bool whileChecking = false}) {
    if (error is LocalApiException) {
      if (error.isNetwork || error.code == 'not_configured') {
        final base = whileChecking
            ? 'Pano bulunamadı. Telefonunuzun Wi-Fi ayarlarından panonun kurulum ağına bağlı olduğunuzdan emin olup tekrar deneyin.'
            : 'Panoyla bağlantı kurulamadı. Telefonun hâlâ panonun ağına bağlı olduğundan emin olun.';
        final hint = error.hint; // Android: pano ağına yönlenme kurulamadıysa nedeni (BoardNetworkBinding)
        return hint == null ? base : '$base $hint';
      }
      if (error.isUnprovisioned) {
        return 'Pano henüz hazırlanmamış (ilk kurulum yapılmamış). Wi-Fi bilgileri bu ekrandan gönderilemez; '
            'servis kurulum sihirbazını kullanın.';
      }
      if (error.isUnauthorized) {
        // Anahtarsız AP kaynaklı yol: pano yalnızca kendi WPA2 kurulum ağındaki telefonlara izin verir.
        return 'Pano bu isteği kabul etmedi. Telefonunuzun panonun KURULUM ağına (AHBU-..., etiketteki parolayla) '
            'bağlı olduğundan emin olun; ev Wi-Fi ağı veya mobil veri üzerinden bu işlem yapılamaz. '
            'Yeniden bağlanıp tekrar deneyin.';
      }
      if (error.isLocked) {
        final wait = error.retryAfter;
        return 'Çok fazla hatalı deneme nedeniyle pano geçici olarak kilitlendi'
            '${wait == null ? '' : ' (yaklaşık ${wait.inSeconds} sn)'}. Biraz bekleyip tekrar deneyin.';
      }
      if (error.statusCode == 429) {
        final wait = error.retryAfter;
        return 'Pano kısa sürede çok fazla deneme aldı'
            '${wait == null ? '' : ' (yaklaşık ${wait.inSeconds} sn bekleyin)'}. Biraz bekleyip tekrar deneyin.';
      }
      if (error.isBusy) return 'Pano şu an meşgul (başka bir işlem sürüyor). Birkaç saniye sonra tekrar deneyin.';
      return error.message;
    }
    return 'İşlem tamamlanamadı. Pano bağlantısını kontrol edip tekrar deneyin.';
  }

  String _hostLabel() {
    final base = widget.api.baseUrl;
    final uri = Uri.tryParse(base);
    final authority = uri?.authority ?? '';
    return authority.isEmpty ? base : authority;
  }

  // ---------------------------------------------------------------------------
  // Arayüz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.getTextPrimary(context);
    final textMuted = AppTheme.getTextMuted(context);
    final busy = _phase != _Phase.idle;
    final canAct = widget.enabled && !busy;
    final result = _result;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.enabled && widget.disabledMessage != null) ...[
          InlineMessage.warning(widget.disabledMessage!, key: const Key('wifi_disabled_message')),
          const SizedBox(height: 12),
        ],
        _buildConnectionCard(canAct, textPrimary, textMuted),
        const SizedBox(height: 14),
        if (result != null && result.isSuccess)
          _buildSuccess(result)
        else ...[
          _buildForm(canAct, busy, textPrimary, textMuted),
          if (result != null) ...[const SizedBox(height: 12), _buildFailure(result)],
        ],
      ],
    );
  }

  Widget _buildConnectionCard(bool canAct, Color textPrimary, Color textMuted) {
    final connected = _connected;
    final status = _deviceStatus;
    final detail = <String>[
      if (status?.uid != null) 'Pano: ${status!.uid}',
      if (status?.firmware != null) 'Yazılım: ${status!.firmware}',
      'Adres: ${_hostLabel()}',
    ].join('  •  ');
    final idleTitle = widget.numberedSteps ? 'Adım 2: Panoyla bağlantıyı test edin' : 'Pano bağlantısı';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: connected ? AppTheme.accentGreen.withValues(alpha: 0.10) : AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: connected ? AppTheme.accentGreen.withValues(alpha: 0.6) : AppTheme.getCardBorder(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.check_circle : Icons.wifi_find,
                color: connected ? AppTheme.accentGreen : AppTheme.primaryBlueLight,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  connected
                      ? 'Pano ile bağlantı kuruldu${status == null ? '' : ' (${status.deviceName})'}'
                      : idleTitle,
                  key: const Key('wifi_connection_title'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textPrimary),
                ),
              ),
            ],
          ),
          if (connected) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              key: const Key('wifi_connection_detail'),
              style: TextStyle(fontSize: 11.5, color: textMuted, height: 1.35),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_wifi_check'),
              onPressed: canAct ? _checkConnection : null,
              icon: _phase == _Phase.checking
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(connected ? 'Bağlantıyı Yeniden Kontrol Et' : 'Pano Bağlantısını Test Et'),
            ),
          ),
          if (_mismatch != null) ...[
            const SizedBox(height: 10),
            InlineMessage.warning(_mismatch!, key: const Key('wifi_target_mismatch')),
          ],
          if (_checkError != null) ...[
            const SizedBox(height: 10),
            InlineMessage.error(_checkError!, key: const Key('wifi_check_error')),
          ],
        ],
      ),
    );
  }

  Widget _buildForm(bool canAct, bool busy, Color textPrimary, Color textMuted) {
    final cardBg = AppTheme.getCardColor(context);
    final cardBorder = AppTheme.getCardBorder(context);
    final ssidEdge = WifiValidators.hasEdgeWhitespace(_ssid.text);
    final passEdge = WifiValidators.hasEdgeWhitespace(_pass.text);
    final cooling = _rateLimit.isActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap: dar ekranda / büyük yazı ölçeğinde tarama düğmesi başlığın altına geçer (Row taşardı).
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(
              widget.numberedSteps ? 'Adım 3: Ev Wi-Fi bilgilerini girin' : 'Ev Wi-Fi Bilgileri',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: textPrimary),
            ),
            if (_connected)
              _phase == _Phase.scanning
                  ? TextButton.icon(
                      key: const Key('btn_wifi_scan_cancel'),
                      onPressed: _cancel,
                      icon: const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      label: const Text('Taramayı İptal Et', style: TextStyle(fontSize: 12)),
                    )
                  : TextButton.icon(
                      key: const Key('btn_wifi_scan'),
                      onPressed: canAct ? _scan : null,
                      icon: const Icon(Icons.wifi_tethering, size: 16),
                      label: const Text('Ağları Tara', style: TextStyle(fontSize: 12)),
                    ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Pano yalnızca 2,4 GHz Wi-Fi ağlarına bağlanabilir.',
          key: const Key('wifi_24ghz_note'),
          style: TextStyle(fontSize: 11.5, color: textMuted),
        ),
        if (_scanError != null) ...[
          const SizedBox(height: 8),
          InlineMessage.error(
            _scanError!,
            key: const Key('wifi_scan_error'),
            trailing: TextButton(
              key: const Key('btn_wifi_scan_retry'),
              onPressed: canAct ? _scan : null,
              child: const Text('Tekrar Dene'),
            ),
          ),
        ],
        if (_scanned && _networks.isEmpty && _scanError == null) ...[
          const SizedBox(height: 8),
          const InlineMessage.info('Çevrede ağ bulunamadı. Ağ adını elle yazabilirsiniz.', key: Key('wifi_no_networks')),
        ],
        if (_networks.isNotEmpty) ...[
          const SizedBox(height: 8),
          // Dış kutu yalnızca çerçeve çizer; zemin rengi `Material`dadır (ListTile dokunma efekti ve
          // seçili rengi, aradaki renkli bir DecoratedBox tarafından gizlenmesin).
          Container(
            constraints: const BoxConstraints(maxHeight: 190),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cardBorder),
            ),
            child: Material(
              color: cardBg,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: ListView.builder(
                key: const Key('wifi_network_list'),
                shrinkWrap: true,
                itemCount: _networks.length,
                itemBuilder: (context, index) {
                  final net = _networks[index];
                  final selected = _ssid.text == net.ssid;
                  return ListTile(
                    key: Key('wifi_network_$index'),
                    dense: true,
                    selected: selected,
                    leading: Icon(
                      _signalIcon(net.rssi),
                      size: 18,
                      color: AppTheme.primaryBlueLight,
                      semanticLabel: 'Sinyal ${_signalLabel(net.rssi)}',
                    ),
                    title: Text(net.ssid, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: textPrimary)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          net.secured ? Icons.lock_outline : Icons.lock_open,
                          size: 13,
                          color: net.secured ? textMuted : AppTheme.accentGreen,
                          semanticLabel: net.secured ? 'Şifreli ağ' : 'Açık ağ',
                        ),
                        const SizedBox(width: 4),
                        Text('${net.rssi} dBm', style: TextStyle(fontSize: 11, color: textMuted)),
                      ],
                    ),
                    onTap: busy ? null : () => _selectNetwork(net),
                  );
                },
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('btn_wifi_scan_qr'),
          onPressed: canAct ? _scanQr : null,
          icon: const Icon(Icons.qr_code_scanner, color: AppTheme.accentCyan, size: 20),
          label: const Text(
            'Modem Wi-Fi Karekodu Tara (Kamera)',
            style: TextStyle(color: AppTheme.accentCyan, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accentCyan, width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('field_wifi_ssid'),
          controller: _ssid,
          enabled: !busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          style: TextStyle(color: textPrimary, fontSize: 13.5),
          onChanged: (_) => setState(() {
            _selectedSecured = null; // elle düzenlendi: ağ türü bilinmez
            _formError = null;
          }),
          decoration: InputDecoration(
            labelText: 'Wi-Fi Ağ Adı (SSID)',
            hintText: 'Ev Wi-Fi ağınızın adı',
            prefixIcon: const Icon(Icons.wifi, size: 20),
            suffixIcon: IconButton(
              key: const Key('btn_wifi_ssid_qr'),
              tooltip: 'Wi-Fi karekodunu tara',
              icon: const Icon(Icons.qr_code_scanner, size: 20, color: AppTheme.accentCyan),
              onPressed: canAct ? _scanQr : null,
            ),
            helperText: ssidEdge ? 'Dikkat: ağ adının başında/sonunda boşluk var; olduğu gibi gönderilir.' : null,
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('field_wifi_password'),
          controller: _pass,
          focusNode: _passFocus,
          enabled: !busy,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: textPrimary, fontSize: 13.5),
          onChanged: (_) => setState(() => _formError = null),
          decoration: InputDecoration(
            labelText: 'Wi-Fi Şifresi',
            hintText: 'Açık ağlar için boş bırakın',
            prefixIcon: const Icon(Icons.lock_outline, size: 20),
            suffixIcon: IconButton(
              key: const Key('btn_wifi_password_toggle'),
              tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            helperText: passEdge ? 'Dikkat: şifrenin başında/sonunda boşluk var; olduğu gibi gönderilir.' : null,
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 14),
        if (_formError != null) ...[
          InlineMessage.error(_formError!, key: const Key('wifi_form_error')),
          const SizedBox(height: 12),
        ],
        if (_phase == _Phase.submitting) ...[
          InlineMessage.info(
            'Bilgiler panoya gönderildi; pano ev ağına bağlanıyor (en çok ${widget.connectTimeout.inSeconds} sn)...',
            key: const Key('wifi_waiting'),
            trailing: TextButton(
              key: const Key('btn_wifi_cancel'),
              onPressed: _cancel,
              child: const Text('İptal'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (widget.numberedSteps) ...[
          Text(
            'Adım 4: Panoya yükleyin',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: textPrimary),
          ),
          const SizedBox(height: 8),
        ],
        ElevatedButton.icon(
          key: const Key('btn_wifi_submit'),
          onPressed: (canAct && !cooling) ? _submit : null,
          icon: _phase == _Phase.submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, size: 18),
          label: Text(
            cooling
                ? 'Yeni Wi-Fi Şifresini Panoya Yükle (${_rateLimit.remainingSeconds} sn)'
                : 'Yeni Wi-Fi Şifresini Panoya Yükle',
            textAlign: TextAlign.center,
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess(WifiConnectResult result) {
    final ip = result.ipAddress;
    final muted = AppTheme.getTextMuted(context);
    return Container(
      key: const Key('wifi_result_success'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.accentGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline, color: AppTheme.accentGreen, size: 44),
          const SizedBox(height: 10),
          const Text(
            'Pano ev Wi-Fi ağına bağlandı!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.accentGreen),
          ),
          const SizedBox(height: 8),
          Text(
            ip == null
                ? 'Pano modeme bağlandı. Kurtarma modu sona eriyor: kurulum ağı kısa süre içinde kapanır.'
                : 'Pano modeme bağlandı (IP: $ip). Kurtarma modu sona eriyor: kurulum ağı kısa süre içinde kapanır.',
            key: const Key('wifi_success_detail'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: muted, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            'Telefonunuzu ev Wi-Fi ağınıza (veya mobil veriye) geri alın.',
            key: const Key('wifi_success_phone_hint'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppTheme.getTextPrimary(context), fontWeight: FontWeight.w600, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildFailure(WifiConnectResult result) {
    final uncertain = result.outcome == WifiConnectOutcome.lostContact;
    final key = uncertain ? const Key('wifi_result_uncertain') : const Key('wifi_result_failed');
    final retryButton = TextButton(
      key: const Key('btn_wifi_retry'),
      onPressed: _retry,
      child: const Text('Yeniden Dene'),
    );
    return uncertain
        ? InlineMessage.warning(
            '${result.message} Bu bir hata olmayabilir: pano bağlandığında kurulum ağını kapatır. '
            'Telefonunuzu ev Wi-Fi ağınıza alın; pano uygulamada çevrimiçi görünüyorsa kurulum tamamdır.',
            key: key,
            trailing: retryButton,
          )
        : InlineMessage.error(result.message, key: key, trailing: retryButton);
  }

  IconData _signalIcon(int rssi) {
    if (rssi >= -60) return Icons.wifi;
    if (rssi >= -75) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  String _signalLabel(int rssi) {
    if (rssi >= -60) return 'iyi';
    if (rssi >= -75) return 'orta';
    return 'zayıf';
  }
}
