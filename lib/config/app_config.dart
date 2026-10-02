import 'package:flutter/foundation.dart';

/// Derleme zamanı yapılandırması (`--dart-define`).
///
/// Yerel QA arka ucuna / emülatöre bağlanmak için kullanılır:
///
/// ```text
/// flutter run -d emulator-5554 \
///   --dart-define=API_BASE_URL=http://10.0.2.2:5000/api \
///   --dart-define=MQTT_TLS=false \
///   --dart-define=DEVICE_AP_HOST=10.0.2.2:8081
/// ```
///
/// | Değişken | Anlamı | Varsayılan |
/// |---|---|---|
/// | `API_BASE_URL` | REST kök adresi (`/api` dahil, sonunda `/` yok) | [defaultApiBaseUrl] |
/// | `MQTT_TLS` | `false` ise MQTT TLS kapalı | TLS açık |
/// | `DEVICE_AP_HOST` | Cihaz kurtarma/kurulum AP adresi (`host[:port]`) | [defaultDeviceApHost] |
///
/// **GÜVENLİK KURALI:** üç override da `kReleaseMode == true` iken **yok sayılır**; release
/// derlemede her zaman güvenli varsayılan kullanılır (HTTPS, TLS açık, `192.168.4.1`).
/// Böylece bir yanlış `dart-define` ile üretim derlemesi düz metin bağlantıya düşürülemez.
class AppConfig {
  const AppConfig._({
    required this.apiBaseUrl,
    required this.mqttUseTls,
    required this.deviceApHost,
    required this.overridesApplied,
  });

  /// Üretim REST kök adresi.
  static const String defaultApiBaseUrl = 'https://evotomasyon.gudeteknoloji.com.tr/api';

  /// Kurtarma / yerel kurulum erişim noktası (AP) adresi.
  static const String defaultDeviceApHost = '192.168.4.1';

  static const String _apiBaseUrlEnv = String.fromEnvironment('API_BASE_URL');
  static const String _mqttTlsEnv = String.fromEnvironment('MQTT_TLS');
  static const String _deviceApHostEnv = String.fromEnvironment('DEVICE_AP_HOST');

  /// REST kök adresi (`/api` dahil; yol eklerken `/v1/...` eklenir).
  final String apiBaseUrl;

  /// MQTT için TLS kullanılsın mı? (Port/host sunucunun `mqtt-credentials` yanıtından gelir.)
  final bool mqttUseTls;

  /// Cihaz kurtarma/kurulum AP adresi (`host` veya `host:port`, şema/yol yok).
  final String deviceApHost;

  /// Herhangi bir `dart-define` geçersiz kılması uygulandı mı? (yalnızca hata ayıklama/QA)
  final bool overridesApplied;

  static AppConfig _current = AppConfig.fromOverrides(
    apiBaseUrl: _apiBaseUrlEnv,
    mqttTls: _mqttTlsEnv,
    deviceApHost: _deviceApHostEnv,
    releaseMode: kReleaseMode,
  );

  /// Uygulamanın kullandığı yapılandırma (derleme zamanı `dart-define` + `kReleaseMode`).
  static AppConfig get current => _current;

  /// Yalnızca testlerde: etkin yapılandırmayı değiştirir (test sonunda [defaults] ile geri al).
  @visibleForTesting
  static set current(AppConfig value) => _current = value;

  /// Güvenli varsayılanlar.
  static const AppConfig defaults = AppConfig._(
    apiBaseUrl: defaultApiBaseUrl,
    mqttUseTls: true,
    deviceApHost: defaultDeviceApHost,
    overridesApplied: false,
  );

  /// Ham override değerlerinden yapılandırma çözer. [releaseMode] `true` ise override'lar
  /// **tamamen yok sayılır**. Geçersiz bir override değeri de varsayılana düşer.
  ///
  /// Birim testlerde `releaseMode` açıkça verilerek her iki davranış doğrulanır.
  factory AppConfig.fromOverrides({
    String apiBaseUrl = '',
    String mqttTls = '',
    String deviceApHost = '',
    bool releaseMode = kReleaseMode,
  }) {
    if (releaseMode) return defaults;

    final api = _normalizeApiBaseUrl(apiBaseUrl);
    final tlsOverride = _parseTls(mqttTls);
    final ap = _normalizeHost(deviceApHost);

    return AppConfig._(
      apiBaseUrl: api ?? defaultApiBaseUrl,
      mqttUseTls: tlsOverride ?? true,
      deviceApHost: ap ?? defaultDeviceApHost,
      overridesApplied: api != null || tlsOverride != null || ap != null,
    );
  }

  /// Testler için: verilen değerlerle yapılandırma üretir (`releaseMode` varsayılan `false`).
  @visibleForTesting
  factory AppConfig.forTest({
    String apiBaseUrl = '',
    String mqttTls = '',
    String deviceApHost = '',
    bool releaseMode = false,
  }) =>
      AppConfig.fromOverrides(
        apiBaseUrl: apiBaseUrl,
        mqttTls: mqttTls,
        deviceApHost: deviceApHost,
        releaseMode: releaseMode,
      );

  /// Cihaz AP'sinin kök adresi (`http://host[:port]`). Yerel cihaz API'si düz HTTP'dir.
  String get deviceApBaseUrl => 'http://$deviceApHost';

  /// REST API'nin ana makine adı (QR host izin listesi ve diagnostik için).
  String get apiHost => Uri.tryParse(apiBaseUrl)?.host ?? '';

  /// Etiket QR'ındaki talep (claim) adresinin kökü: üretim sitesi (`https://<host>/claim`).
  static String get productionClaimUrl =>
      'https://${Uri.parse(defaultApiBaseUrl).host}/claim';

  /// Üretim sitesinin ana makine adı.
  static String get productionHost => Uri.parse(defaultApiBaseUrl).host;

  static String? _normalizeApiBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    return text;
  }

  static bool? _parseTls(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') return false;
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') return true;
    return null;
  }

  /// `host` veya `host:port` kabul eder; şema, yol, sorgu, boşluk içeren değerleri reddeder.
  static String? _normalizeHost(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (text.contains('/') || text.contains('?') || text.contains('#') || text.contains(' ')) {
      return null;
    }
    final uri = Uri.tryParse('http://$text');
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
    return text;
  }

  @override
  String toString() =>
      'AppConfig(api: $apiBaseUrl, mqttTls: $mqttUseTls, deviceAp: $deviceApHost, '
      'overrides: $overridesApplied)';
}
