import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/automation_models.dart';
import '../../services/automation_api_service.dart';
import '../../services/clock.dart';
import '../../utils/version_compare.dart';
import '../../utils/wifi_qr_parser.dart';
import '../motion/motion_scope.dart';
import '../motion/skeleton.dart';
import '../pages/claim/qr_scanner_page.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../pages/service_setup/panel/service_glass.dart' show ServiceBalancedLabel, ServiceProgressRing, serviceTallButtonShapeProperty;
import '../pages/service_setup/setup_style.dart' show SetupText;
import '../widgets/orb/orb.dart';
import '../widgets/settings/accent_button.dart';
import '../widgets/surface_card.dart';
import 'arc_spinner.dart';
import 'cooldown.dart';
import 'inline_message.dart';
import 'validators.dart';
import 'wifi_signal_bars.dart';

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
    this.serviceMode = true,
    this.boardSeenOnline,
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

  /// Kullanıcı servis rolünde mi (`ServiceSetupAccess.fromState != null`; servis sihirbazı varsayılanı). `false` iken
  /// hazırlanmamış panoda açamayacağı servis sihirbazı yerine satıcı / servis yönlendirmesi gösterilir (bireysel-13) ve
  /// eski yazılımlı panoda bulut uyarısı verilir (bireysel-1).
  final bool serviceMode;

  /// Bu pano daha önce buluta bağlandı mı (ör. evin cihaz listesinde görülmüş): öyleyse bulut kimliği panoda vardır ve
  /// eski yazılım uyarısı gösterilmez (yalnız Wi-Fi değişikliği yeterli).
  final bool Function(String uid)? boardSeenOnline;

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

  /// Paneldeki tam genişlikli düğmelerin yatay dolgusu 16 dp (tema 22-24): kurtarma diyaloğunda kullanılabilir genişlik 288 dp
  /// (kart içinde 264 dp), tema dolgusuyla etiket payı ≈ 196-218 dp kalıp "Yeniden Kontrol / Et" gibi yetim sözcük çıkıyordu.
  /// Dikey dolgu temadan aynen (çerçeveli 12, dolgulu 14).
  static const WidgetStateProperty<EdgeInsetsGeometry?> _panelButtonPadding =
      WidgetStatePropertyAll<EdgeInsetsGeometry?>(EdgeInsets.symmetric(horizontal: 16, vertical: 12));
  static const WidgetStateProperty<EdgeInsetsGeometry?> _panelSubmitPadding =
      WidgetStatePropertyAll<EdgeInsetsGeometry?>(EdgeInsets.symmetric(horizontal: 16, vertical: 14));

  /// Satır içi metin eylemi ("Ağları Tara", "Yeniden Dene"): varsayılan 12-16 dp iç boşluk simgeyi/yazıyı başlık ve notun sol
  /// kenarından ≈ 13 dp içeri iterdi; dolgu 4 dp ve içerik sola yaslı (dokunma hedefi 48 dp kalır).
  static final ButtonStyle _inlineActionStyle = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    minimumSize: const Size(48, AppTouch.minTarget),
    alignment: AlignmentDirectional.centerStart,
  );

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
          _checkError = widget.serviceMode
              ? 'Pano henüz kurulmamış görünüyor (ilk hazırlık yapılmamış). Wi-Fi bilgileri bu aşamada '
                  'gönderilemez: servis girişinden "Yeni Kurulum Başlat" sihirbazını açın; cihazı tanıtıp daireye bağladıktan '
                  'sonra 5. adımda (Wi-Fi Kurulumu) "Panoyu Hazırla" ile ilk hazırlığı yapın ve ev Wi-Fi bilgisini oradan gönderin.'
              // Servis rolü olmayan kullanıcı sihirbazı açamaz (bireysel-13).
              : kUnprovisionedBoardUserMessage;
        }
      });
      if (status.provisioned == false) {
        // Çağıran panonun hazırlık durumunu da öğrenir (bireysel-13: sahiplenme diyaloğu eşlemeden önce uyarır).
        await _notifyDeviceChecked(status);
        return;
      }
      await _notifyDeviceChecked(status); // örn. kimliği doğrulanmış panonun önbellek anahtarı
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
      await _notifyDeviceChecked(null); // önceki panoya ait durum/anahtar bırakılmaz
    }
  }

  /// [WifiProvisionPanel.onDeviceChecked] için üst süre (PF-43): çağıran (ör. önbellekteki pano anahtarını
  /// güvenli depodan okuyan) takılırsa panel sonsuza dek "kontrol ediliyor" kalmasın; Wi-Fi kurtarma panonun
  /// ACİL yoludur. Kök çözüm servis katmanı süre sınırıdır (PF-02); bu ek emniyettir.
  static const Duration _deviceCheckedTimeout = Duration(seconds: 3);

  /// Çağırana haber verir; **hata ve zaman aşımı yutulur** (anahtar isteğe bağlıdır: hazırlanamazsa anahtarsız
  /// (AP kaynaklı) yolla devam edilir). Zamanlayıcı [WifiProvisionPanel.clock]'tandır (testte sahte saat).
  Future<void> _notifyDeviceChecked(DeviceStatus? status) async {
    final callback = widget.onDeviceChecked;
    if (callback == null) return;
    try {
      await widget.clock.bound<void>(callback(status), _deviceCheckedTimeout, () {});
    } catch (_) {
      // Anahtar isteğe bağlı: yok sayılır.
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
        _formError =
            'Bekleme iptal edildi. Pano bağlanmayı sürdürüyor olabilir; '
            '"Bağlantıyı Test Et" ile durumu kontrol edebilirsiniz.';
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
    final error =
        WifiValidators.ssidError(ssid) ?? WifiValidators.passwordError(pass, networkSecured: _selectedSecured);
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
            ? 'Pano bulunamadı. Telefonunuzun Wi-Fi ayarlarından panonun kurulum ağına bağlı olduğunuzdan emin olup tekrar deneyin. '
                '$apWindowHint'
            : 'Panoyla bağlantı kurulamadı. Telefonun hâlâ panonun ağına bağlı olduğundan emin olun.';
        final hint = error.hint; // Android: pano ağına yönlenme kurulamadıysa nedeni (BoardNetworkBinding)
        return hint == null ? base : '$base $hint';
      }
      if (error.isUnprovisioned) {
        if (!widget.serviceMode) return kUnprovisionedBoardUserMessage; // açamayacağı sihirbaz önerilmez (bireysel-13)
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

  /// Kurulum ağı (AP) penceresi (firmware ApPolicy): açılışta 10 dk açık, kesinti sürerse 15 dk sonra yeniden (bireysel-11).
  /// Kayıtlı ev ağı varken pano önce onu arar: pencere açılıştan yaklaşık 3 dk sonra açılır.
  static const String apWindowHint =
      'Kurulum ağı açılıştan sonra 10 dk açık kalır, sonra 15 dk kapanır; görünmüyorsa panonun elektriğini kapatıp açın. '
      'Pano kayıtlı bir ev ağını arıyorsa kurulum ağı yaklaşık 3 dk sonra açılır.';

  /// Eski yazılımlı (v1.3.0 öncesi) pano bulut kimliğini kendisi alamaz (bireysel-1): yalnız servis rolü olmayan kullanıcıya
  /// ve pano daha önce buluta bağlanmamışsa gösterilir. Sürüm okunamazsa uyarı yok.
  static const String oldFirmwareWarning =
      'Bu pano yazılımı buluta kendiliğinden bağlanamaz; yetkili servisten güncelleme isteyin. Pano daha önce buluta '
      'bağlandıysa Wi-Fi değişikliğinden sonra yeniden bağlanır.';

  bool _showOldFirmwareWarning(DeviceStatus? status) {
    if (widget.serviceMode || status == null || status.provisioned == false) return false;
    if (versionAtLeast(status.firmware, kCloudBootstrapMinFirmware) != false) return false;
    final uid = status.uid?.trim().toUpperCase();
    if (uid != null && uid.isNotEmpty && (widget.boardSeenOnline?.call(uid) ?? false)) return false;
    return true;
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
        // Başarıda TEK başarı kartı: bağlantı kartı (bayat "Bağlantıyı Yeniden Kontrol Et" eylemiyle) gizlenir; iki yığılı yeşil kart
        // aynı şeyi söylüyor ve eylem "Tamam" ile yarışıyordu.
        if (!(result != null && result.isSuccess)) ...[
          _buildConnectionCard(canAct, textPrimary, textMuted),
          const SizedBox(height: 14),
        ],
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
    return SurfaceCard(
      key: const Key('wifi_connection_card'),
      accent: connected ? AppFamilies.emerald.base : null,
      active: connected,
      // Kart içi kart: r16 (sihirbazda SetupCard > bu kart iç içe; ikisi de 20 olunca üç seviye aynı yarıçapta kalıyordu).
      radius: AppRadius.r16,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Başarı yeşil orb ✓ (yalnız bağlantı testi gerçekten başarılıysa); bekleme/tarama sırasında dönen yay.
              Stack(
                alignment: Alignment.center,
                children: [
                  OrbIconBadge(
                    key: const Key('wifi_connection_orb'),
                    icon: connected ? Icons.check_rounded : Icons.network_check_rounded,
                    family: connected ? AppFamilies.emerald : AppFamilies.sky,
                    status: connected ? OrbStatus.success : OrbStatus.none,
                  ),
                  if (_phase == _Phase.checking)
                    Positioned.fill(
                      child: ProgressArc(diameter: OrbSize.sm.diameter, color: AppFamilies.sky.light, strokeWidth: 2.5),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                // Dengeli satır sonu: dar yerde "Adım 2: Panoyla bağlantıyı test / edin" gibi yetim son sözcük kalmaz (metin DEĞİŞMEZ).
                child: ServiceBalancedLabel(
                  connected ? 'Pano ile bağlantı kuruldu${status == null ? '' : ' (${status.deviceName})'}' : idleTitle,
                  textKey: const Key('wifi_connection_title'),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: textPrimary),
                ),
              ),
            ],
          ),
          if (connected) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              key: const Key('wifi_connection_detail'),
              style: TextStyle(fontSize: AppTouch.minFontSize, color: textMuted, height: 1.35),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_wifi_check'),
              onPressed: canAct ? _checkConnection : null,
              icon: _phase == _Phase.checking
                  ? SizedBox(
                      width: accentIconSize(context, base: 16),
                      height: accentIconSize(context, base: 16),
                      // Düğme metniyle AYNI AA ton (ham #60A5FA açık temada ≈ 2.4:1'di).
                      child: ArcSpinner(
                        size: accentIconSize(context, base: 16),
                        color: AppTheme.readableFamily(context, AppFamilies.sky),
                        strokeWidth: 2,
                      ),
                    )
                  : Icon(Icons.refresh_rounded, size: accentIconSize(context, base: 16)),
              label: ServiceBalancedLabel(
                connected ? 'Bağlantıyı Yeniden Kontrol Et' : 'Bağlantıyı Test Et',
                centered: true,
              ),
              // Çerçeve + metin + simge AYNI aileden ve AA (sky; tema varsayılan çerçevesi açıkta ≈ 2.4:1'di ve hemen altındaki
              // karekod düğmesi [accentOutlinedButtonStyle] ile iki farklı çerçeveli düğme dili çıkıyordu); yatay dolgu dar
              // diyalogda etiketin yetim sözcük bırakmaması için daraltılır.
              style: accentOutlinedButtonStyle(context, AppFamilies.sky)
                  .copyWith(padding: _panelButtonPadding, shape: serviceTallButtonShapeProperty),
            ),
          ),
          if (_mismatch != null) ...[
            const SizedBox(height: 10),
            InlineMessage.warning(_mismatch!, key: const Key('wifi_target_mismatch')),
          ],
          if (connected && _showOldFirmwareWarning(status)) ...[
            const SizedBox(height: 10),
            const InlineMessage.warning(oldFirmwareWarning, key: Key('wifi_fw_old_warning')),
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
                      style: _inlineActionStyle,
                      icon: SizedBox(
                        width: accentIconSize(context, base: 14),
                        height: accentIconSize(context, base: 14),
                        child: ArcSpinner(
                          size: accentIconSize(context, base: 14),
                          color: AppTheme.readableFamily(context, AppFamilies.sky),
                          strokeWidth: 2,
                        ),
                      ),
                      label: const Text('Taramayı İptal Et', style: TextStyle(fontSize: 12)),
                    )
                  : TextButton.icon(
                      key: const Key('btn_wifi_scan'),
                      onPressed: canAct ? _scan : null,
                      style: _inlineActionStyle,
                      icon: Icon(Icons.wifi_tethering, size: accentIconSize(context, base: 16)),
                      label: const Text('Ağları Tara', style: TextStyle(fontSize: 12)),
                    ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Pano yalnızca 2,4 GHz Wi-Fi ağlarına bağlanabilir.',
          key: const Key('wifi_24ghz_note'),
          style: TextStyle(fontSize: AppTouch.minFontSize, color: textMuted),
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
          const InlineMessage.info(
            'Çevrede ağ bulunamadı. Ağ adını elle yazabilirsiniz.',
            key: Key('wifi_no_networks'),
          ),
        ],
        if (_phase == _Phase.scanning && _networks.isEmpty) ...[
          const SizedBox(height: 8),
          const _NetworkSkeleton(key: Key('wifi_scan_skeleton')),
        ],
        if (_networks.isNotEmpty) ...[
          const SizedBox(height: 8),
          // Dış kutu yalnızca çerçeve çizer; zemin rengi `Material`dadır (dokunma efekti ve seçili rengi, aradaki
          // renkli bir DecoratedBox tarafından gizlenmesin).
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.r12),
              border: Border.all(color: cardBorder),
            ),
            child: Material(
              color: cardBg,
              borderRadius: BorderRadius.circular(AppRadius.r12),
              clipBehavior: Clip.antiAlias,
              child: ListView.builder(
                key: const Key('wifi_network_list'),
                shrinkWrap: true,
                itemCount: _networks.length,
                itemBuilder: (context, index) {
                  final net = _networks[index];
                  final selected = _ssid.text == net.ssid;
                  return _NetworkTile(
                    key: Key('wifi_network_$index'),
                    network: net,
                    selected: selected,
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
          icon: Icon(Icons.qr_code_scanner, size: accentIconSize(context, base: 20)),
          label: const ServiceBalancedLabel('Modem Wi-Fi Karekodu Tara (Kamera)', centered: true),
          // Metin + simge + çerçeve AYNI cyan ailesinden ve AA: açık temada ham #06B6D4 beyazda 2.4:1'di. Pasifken (tarama /
          // bekleme sırasında) tema'nın soluk çerçevesi/metni geçerlidir: düğme "etkin gibi" parlak kalmaz.
          style: accentOutlinedButtonStyle(context, AppFamilies.cyan)
              .copyWith(padding: _panelButtonPadding, shape: serviceTallButtonShapeProperty),
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
            // Etiket her zaman kenarda durur: iki yanındaki simgeler (ön + karekod) dar ekranda/büyük yazıda etiketi kesmesin.
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hintText: 'Ev Wi-Fi ağınızın adı',
            prefixIcon: const Icon(Icons.wifi, size: 20),
            suffixIcon: IconButton(
              key: const Key('btn_wifi_ssid_qr'),
              tooltip: 'Wi-Fi karekodunu tara',
              icon: Icon(
                Icons.qr_code_scanner,
                size: 20,
                color: canAct ? AppTheme.readableAccent(context, AppFamilies.cyan.base) : null,
              ),
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
            floatingLabelBehavior: FloatingLabelBehavior.always,
            // Tek satırlık kısa ipucu: iki satırlık ipucu alanı yazı girilince de 3 satır yükseklikte tutuyordu.
            hintText: 'Açık ağ: boş bırakın',
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
          _WifiWaitCard(
            key: const Key('wifi_waiting'),
            clock: widget.clock,
            timeout: widget.connectTimeout,
            onCancel: _cancel,
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
              ? SizedBox(
                  width: accentIconSize(context, base: 18),
                  height: accentIconSize(context, base: 18),
                  // Gönderirken düğme pasif cam hap olur: yay rengi temaya göre (koyuda beyaz, açıkta koyu sky) — sabit beyaz yay
                  // açık temada beyaz-üstü-açık-gri olup (≈ 1.2:1) görünmüyordu; SetupPrimaryButton ile aynı kural.
                  child: ProgressArc(
                    diameter: accentIconSize(context, base: 18),
                    color: AppTheme.isDark(context) ? Colors.white : AppFamilies.sky.deep,
                    strokeWidth: 2.2,
                  ),
                )
              : Icon(Icons.send_rounded, size: accentIconSize(context, base: 18)),
          label: ServiceBalancedLabel(
            cooling
                ? 'Yeni Wi-Fi Şifresini Panoya Yükle (${_rateLimit.remainingSeconds} sn)'
                : 'Yeni Wi-Fi Şifresini Panoya Yükle',
            centered: true,
          ),
          // Dar diyalogda (288 dp) etiket payı büyüsün: yatay dolgu 24 -> 16.
          style: ButtonStyle(padding: _panelSubmitPadding),
        ),
      ],
    );
  }

  Widget _buildSuccess(WifiConnectResult result) {
    final ip = result.ipAddress;
    final muted = AppTheme.getTextMuted(context);
    return SurfaceCard(
      key: const Key('wifi_result_success'),
      accent: AppFamilies.emerald.base,
      active: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Başarı YALNIZ `WifiConnectOutcome.success` ile gelir: yeşil orb ✓ (tek seferlik başarı halkası).
          const OrbIconBadge(
            key: Key('wifi_success_orb'),
            icon: Icons.check_rounded,
            family: AppFamilies.emerald,
            size: OrbSize.xl,
            glow: true,
            status: OrbStatus.success,
          ),
          const SizedBox(height: 12),
          Text(
            'Pano ev Wi-Fi ağına bağlandı!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
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
            style: TextStyle(
              fontSize: 12.5,
              color: AppTheme.getTextPrimary(context),
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
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
      // İletiyle aynı sol kenar (varsayılan metin düğmesi dolgusu "Yeniden Dene"yi mesajdan ≈ 10 dp içeri iterdi).
      style: _inlineActionStyle,
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
}

/// Taranan ağ satırı: animasyonlu sinyal çubukları + ağ adı + kilit simgesi + dBm. Anahtar satırın kendisindedir
/// (`wifi_network_<i>`); seçili satır sky vurgulu.
class _NetworkTile extends StatelessWidget {
  const _NetworkTile({super.key, required this.network, required this.selected, required this.onTap});

  final WifiNetwork network;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textPrimary = AppTheme.getTextPrimary(context);
    final textMuted = AppTheme.getTextMuted(context);
    final accent = AppFamilies.sky.base;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: MotionScope.durationOf(context, AppMotion.fast),
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
            border: Border(left: BorderSide(color: selected ? accent : Colors.transparent, width: 3)),
          ),
          child: Builder(
            builder: (context) {
              final ssidText = Text(
                network.ssid,
                maxLines: SetupText.isLargeText(context) ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: textPrimary,
                ),
              );
              final lock = Icon(
                network.secured ? Icons.lock_outline : Icons.lock_open,
                size: accentIconSize(context, base: 15),
                // Açık (şifresiz) ağ "güvenli" yeşili DEĞİL, uyarı tonudur (amber, AA); şifreli ağ nötr.
                color: network.secured ? textMuted : AppTheme.warningText(context),
                semanticLabel: network.secured ? 'Şifreli ağ' : 'Açık ağ',
              );
              final dbm = Text('${network.rssi} dBm', style: TextStyle(fontSize: AppTouch.minFontSize, color: textMuted));
              if (SetupText.isLargeText(context)) {
                // Büyük yazıda kilit + dBm ağ adının ALTINA iner (aynı satırda ağ adını ve dBm'i sıkıştırıp taşırıyordu);
                // Wrap: dar yerde kilit ve dBm de alt alta dizilir.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    WifiSignalBars(rssi: network.rssi),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ssidText,
                          const SizedBox(height: 2),
                          Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [lock, dbm]),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  WifiSignalBars(rssi: network.rssi),
                  const SizedBox(width: 12),
                  Expanded(child: ssidText),
                  const SizedBox(width: 8),
                  lock,
                  const SizedBox(width: 6),
                  dbm,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Tarama sürerken ağ listesi yerine iskelet satırları (spinner yerine).
class _NetworkSkeleton extends StatelessWidget {
  const _NetworkSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Ağlar taranıyor',
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const Skeleton(width: 22, height: 18, radius: 4),
                    const SizedBox(width: 12),
                    Expanded(child: Skeleton(height: 14, radius: 6)),
                    const SizedBox(width: 12),
                    const Skeleton(width: 40, height: 12, radius: 6),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Pano ev ağına bağlanıyor" bekleme kartı: dönen yay + ortada kalan saniye geri sayımı + açıklama + İptal.
/// Geri sayım [clock]'tan (testte sahte saat) türer ve yalnız bu küçük widget'ı saniyede bir yeniden kurar. Süre
/// bitince yalnızca sayaç 0'da durur; sonucu panelin beklemesi belirler (başarı yalnız `success`).
class _WifiWaitCard extends StatefulWidget {
  const _WifiWaitCard({super.key, required this.clock, required this.timeout, required this.onCancel});

  final Clock clock;
  final Duration timeout;
  final VoidCallback onCancel;

  @override
  State<_WifiWaitCard> createState() => _WifiWaitCardState();
}

class _WifiWaitCardState extends State<_WifiWaitCard> {
  late final DateTime _start = widget.clock.now();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = widget.clock.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  int get _remaining {
    final left = widget.timeout - widget.clock.now().difference(_start);
    if (left <= Duration.zero) return 0;
    return (left.inMilliseconds / 1000).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final family = AppFamilies.sky;
    final textPrimary = AppTheme.getTextPrimary(context);
    // Belirli halka: kalan süre / bağlanma zaman aşımı oranıyla boşalır (eskiden belirsiz dönen yay: rakam azalırken halka
    // ilerlemeyi göstermiyordu). Renk açık temada koyu aile tonudur ([AppTheme.accentTone]; ham sky.light ≈ 2.4:1'di).
    final fraction = (widget.timeout.inMilliseconds <= 0
            ? 0.0
            : (widget.timeout - widget.clock.now().difference(_start)).inMilliseconds / widget.timeout.inMilliseconds)
        .clamp(0.0, 1.0);
    return Semantics(
      liveRegion: true,
      container: true,
      child: SurfaceCard(
        accent: family.base,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ServiceProgressRing(
                  value: fraction,
                  size: 56,
                  strokeWidth: 4,
                  color: AppTheme.accentTone(context, family),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '$_remaining',
                        key: const Key('wifi_wait_countdown'),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Bilgiler panoya gönderildi; pano ev ağına bağlanıyor (en çok ${widget.timeout.inSeconds} sn)...',
                    style: TextStyle(fontSize: AppText.caption, height: 1.4, color: textPrimary),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('btn_wifi_cancel'),
                onPressed: widget.onCancel,
                child: const Text('İptal'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
