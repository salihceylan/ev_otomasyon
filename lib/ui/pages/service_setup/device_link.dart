import '../../../models/automation_models.dart';
import '../../../services/automation_api_service.dart';
import '../../../services/clock.dart';
import 'setup_problem.dart';

/// Pano yerel istemcisi üreticisi (testlerde sahte `http.Client` ile değiştirilir).
///
/// [host] `192.168.4.1`, `192.168.1.40:80` gibi yerel adres; [localKey] verilmişse ilk istekten
/// itibaren gönderilir. Üretici adresi kendisi uygulamalıdır (`updateHost`).
typedef DeviceApiFactory = AutomationApiService Function(String host);

/// Gerçek uygulama için varsayılan üretici.
DeviceApiFactory defaultDeviceApiFactory(Clock clock) =>
    (host) => AutomationApiService(baseUrl: '', clock: clock)..updateHost(host);

/// Anahtarsız `GET /api/status` ile doğrulanan cihaz kimliği.
class DeviceIdentity {
  /// Verilen (anahtarsız) istemciyle panonun kimliğini okur ve [expectedUid] ile eşleştiğini doğrular.
  /// Eşleşmezse [WrongDeviceException] fırlatır: hiçbir gizli bilgi gönderilmeden durulur.
  static Future<DeviceIdentity> verify(AutomationApiService api, String expectedUid) async {
    if (!api.isConfigured) throw LocalApiException.notConfigured();
    final status = await api.fetchPublicStatus();
    final uid = status.uid;
    if (uid == null || uid.toUpperCase() != expectedUid.toUpperCase()) {
      throw WrongDeviceException(expectedUid: expectedUid, foundUid: uid);
    }
    return DeviceIdentity.fromStatus(uid, status);
  }

  /// Durum yanıtından kimlik (Ethernet alanları dahil; eski panoda `null`).
  factory DeviceIdentity.fromStatus(String uid, DeviceStatus status) => DeviceIdentity(
        uid: uid,
        provisioned: status.provisioned,
        wifiConnected: status.wifiConnected,
        firmware: status.firmware,
        name: status.deviceName,
        ethConnected: status.ethConnected ?? (status.netIf == null ? null : status.netIf == 'eth'),
        ethIp: status.ethIp,
      );

  const DeviceIdentity({
    required this.uid,
    required this.provisioned,
    required this.wifiConnected,
    this.firmware,
    this.name = '',
    this.ethConnected,
    this.ethIp = '',
  });

  final String uid;

  /// Pano Ethernet ile bağlı mı (firmware v1.3.0+; yanıtta alan yoksa `null`).
  final bool? ethConnected;

  /// Panonun Ethernet IP'si (biliniyorsa).
  final String ethIp;

  /// Pano ev ağında: Wi-Fi **ya da** Ethernet.
  bool get onHomeNetwork => wifiConnected || ethConnected == true;

  /// Cihazda yerel anahtar tanımlı mı (`null` = bildirmedi).
  final bool? provisioned;
  final bool wifiConnected;
  final String? firmware;
  final String name;
}

/// Sihirbazın pano ile yerel (LAN / AP) bağlantısı.
///
/// **Yanlış cihaz koruması:** anahtar yalnızca, panonun kimliği (`GET /api/status` anahtarsız)
/// beklenen cihazla eşleştiği doğrulandıktan sonra istemciye uygulanır; kimlik doğrulanmadan
/// hiçbir gizli bilgi panoya gönderilmez. Adres değişince doğrulama sıfırlanır.
class DeviceLink {
  DeviceLink(this._factory);

  final DeviceApiFactory _factory;

  /// Yeni (anahtarsız) pano istemcisi üretir; sahibi çağırandır ve `dispose` eder. Kurulum ağı (AP)
  /// adımı kendi istemcisini bundan alır: `X-Device-Key` bu istemciye HİÇ uygulanmaz.
  AutomationApiService createApi(String host) => _factory(host);

  AutomationApiService? _api;
  String _host = '';
  String? _key;
  String? _verifiedUid;
  bool _keyChecked = false;
  DeviceIdentity? _lastIdentity;

  /// Bağlı olunan adres.
  String get host => _host;

  /// Bellekteki cihaz anahtarı (loglanmaz).
  String? get key => _key;

  bool get isIdentityVerified => _verifiedUid != null;

  /// Son başarılı kimlik yoklamasının (anahtarsız `GET /api/status`) sonucu; adres değişince/hata sonrası `null`.
  DeviceIdentity? get lastIdentity => _lastIdentity;

  /// Kimlik doğrulandı **ve** anahtar pano tarafından kabul edildi.
  bool isReadyFor(String host) =>
      _api != null && _host == _normalize(host) && _verifiedUid != null && _keyChecked;

  static String _normalize(String host) => host.trim();

  void _replace(String host) {
    _api?.dispose();
    _api = _factory(host);
    _host = host;
    _verifiedUid = null;
    _keyChecked = false;
    _lastIdentity = null;
    // Kimlik doğrulanana kadar anahtar istemciye UYGULANMAZ.
    _api!.localKey = null;
  }

  /// Adresi seçer (değişirse yeni istemci kurulur, kimlik doğrulaması sıfırlanır).
  void useHost(String host) {
    final clean = _normalize(host);
    if (_api == null || clean != _host) _replace(clean);
  }

  /// Anahtarı bellekte tutar; kimlik doğrulandıysa istemciye uygular.
  void useKey(String? key) {
    _key = key;
    _keyChecked = false;
    _api?.localKey = _verifiedUid != null ? key : null;
  }

  /// Anahtarsız kimlik yoklaması. Beklenen cihaz değilse [WrongDeviceException].
  ///
  /// Kurulum ağında (AP) bu yoklama **tek başına yeterlidir**: Wi-Fi uçları AP'den anahtarsız çalışır
  /// (CONTRACTS §3d); anahtar yalnızca ev ağında (6. adım ve sonrası) gerekir.
  Future<DeviceIdentity> probe(String host, {required String expectedUid}) async {
    useHost(host);
    final api = _api!;
    if (!api.isConfigured) throw LocalApiException.notConfigured();
    _lastIdentity = null;
    final status = await api.fetchPublicStatus();
    final uid = status.uid;
    if (uid == null || uid.toUpperCase() != expectedUid.toUpperCase()) {
      _verifiedUid = null;
      _keyChecked = false;
      api.localKey = null;
      throw WrongDeviceException(expectedUid: expectedUid, foundUid: uid);
    }
    _verifiedUid = uid;
    api.localKey = _key;
    return _lastIdentity = DeviceIdentity.fromStatus(uid, status);
  }

  /// Kimlik doğrulanmış istemci (anahtar uygulanmış olabilir). Doğrulama yoksa fırlatır.
  AutomationApiService get verifiedApi {
    final api = _api;
    if (api == null || !api.isConfigured) throw LocalApiException.notConfigured();
    if (_verifiedUid == null) {
      throw const SetupProblemException(SetupProblem(
        kind: SetupProblemKind.deviceNetwork,
        title: 'Önce panoya bağlanın',
        why: 'Pano henüz doğrulanmadı.',
        todo: '"Panoya Bağlan" düğmesine basın.',
      ));
    }
    return api;
  }

  /// `X-Device-Key` doğrulandıktan sonra çağrılır.
  void markKeyChecked() => _keyChecked = true;

  /// Hata sonrası (bağlantı koptu / anahtar reddedildi): bağlantı yeniden kurulmalı.
  void invalidate({bool dropKey = false}) {
    _keyChecked = false;
    if (dropKey) {
      _key = null;
      _api?.localKey = null;
    }
  }

  void dispose() {
    _api?.dispose();
    _api = null;
    _verifiedUid = null;
    _keyChecked = false;
    _key = null;
    _lastIdentity = null;
  }
}
