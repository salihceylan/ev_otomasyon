import 'api_exception.dart';
import 'ev_cloud_api_service.dart';
import 'push/push_coordinator.dart';

/// Push belirteç uçlarını bulut istemcisine bağlar ([PushCoordinator]'ın `PushTokenApi` arayüzü).
///
/// Hata sözleşmesi: yeniden denemenin sonucu değiştirmeyeceği KALICI hatalar
/// ([PushRegistrationRejected]) ile geçici hatalar (olduğu gibi fırlar; koordinatör geri çekilerek
/// yeniden dener) burada ayrılır. Belirteç içeriği hata nedenine yazılmaz.
class CloudPushTokenApi implements PushTokenApi {
  CloudPushTokenApi(this._api);

  final EvCloudApiService _api;

  /// Kalıcı sayılan HTTP durumları:
  /// * 400: geçersiz belirteç/gövde (yerel doğrulama da 400 üretir);
  /// * 401: oturum bitti (istemci yenilemeyi zaten denedi);
  /// * 403: servis oturumu ya da yetki yok;
  /// * 404: sunucu bu ucu bilmiyor (eski sürüm).
  static const Set<int> _permanentStatuses = <int>{400, 401, 403, 404};

  @override
  Future<void> registerPushToken({required String token, required String platform, String? appVersion}) async {
    try {
      await _api.registerPushToken(token: token, platform: platform, appVersion: appVersion);
    } on ApiException catch (e) {
      if (_permanentStatuses.contains(e.statusCode)) {
        throw PushRegistrationRejected('${e.statusCode}');
      }
      // Ağ/zaman aşımı (0), 429, 5xx ve diğerleri: geçici.
      rethrow;
    }
  }

  /// Silme isteğinin hatası koordinatörde yutulur (çıkış engellenmez); burada sınıflandırma gerekmez.
  @override
  Future<void> unregisterPushToken(String token) => _api.unregisterPushToken(token);
}
