import 'package:flutter/foundation.dart';

/// Push (FCM) istemci yapılandırması: yalnızca veri.
///
/// Bu sürümde push gönderim katmanı yapılandırılmadı (Firebase/APNs kullanılmaz): [createPushGateway] bu
/// yapılandırmayı yok sayar ve her zaman hareketsiz ağ geçidi döndürür. Sınıf, ileride gerçek push istenirse
/// diye saklanır (ENTEGRASYON.md, "Ek: Firebase ileride istenirse").
///
/// Değerler depoya yazılmaz; derleme sırasında `--dart-define` ile verilir (eski kurulum rehberi:
/// PUSH_KURULUM_ARSIV.md): `FCM_API_KEY`, `FCM_APP_ID`, `FCM_SENDER_ID`, `FCM_PROJECT_ID`.
///
/// Dört değerden biri bile eksikse [fromEnvironment] `null` döner; yapılandırması olmayan bir derleme (CI,
/// geliştirici makinesi) eskisi gibi çalışır.
///
/// Değerler hiçbir yerde loglanmaz: [toString] içeriği bilerek gizler.
@immutable
class PushConfig {
  const PushConfig({
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
    required this.projectId,
  });

  /// Firebase Web API anahtarı (`current_key`); istemci anahtarıdır, sunucu sırrı DEĞİLDİR
  /// ama yine de depoya girmez.
  final String apiKey;

  /// Firebase uygulama kimliği (`1:<numara>:android:<hash>`).
  final String appId;

  /// FCM gönderen kimliği (proje numarası).
  final String messagingSenderId;

  /// Firebase proje kimliği.
  final String projectId;

  /// `--dart-define` değerlerinden okur. Hepsi dolu değilse `null`.
  ///
  /// `String.fromEnvironment` derleme zamanı sabiti olmak zorundadır; bu yüzden değerler tek tek
  /// `const` bir haritaya konup [fromMap]'e verilir (doğrulama mantığı tek yerde kalır).
  static PushConfig? fromEnvironment() => fromMap(const <String, String?>{
    'FCM_API_KEY': String.fromEnvironment('FCM_API_KEY'),
    'FCM_APP_ID': String.fromEnvironment('FCM_APP_ID'),
    'FCM_SENDER_ID': String.fromEnvironment('FCM_SENDER_ID'),
    'FCM_PROJECT_ID': String.fromEnvironment('FCM_PROJECT_ID'),
  });

  /// Aynı anahtar adlarıyla bir haritadan kurar (testler ve [fromEnvironment] için).
  ///
  /// Değerler kırpılır; boş/eksik biri varsa `null` döner. Tahmin yoktur: yarım yapılandırmayla
  /// push başlatmak yerine hiç başlatmamak daha güvenlidir.
  static PushConfig? fromMap(Map<String, String?> values) {
    final apiKey = _clean(values['FCM_API_KEY']);
    final appId = _clean(values['FCM_APP_ID']);
    final senderId = _clean(values['FCM_SENDER_ID']);
    final projectId = _clean(values['FCM_PROJECT_ID']);
    if (apiKey == null || appId == null || senderId == null || projectId == null) {
      return null;
    }
    return PushConfig(apiKey: apiKey, appId: appId, messagingSenderId: senderId, projectId: projectId);
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is PushConfig &&
      other.apiKey == apiKey &&
      other.appId == appId &&
      other.messagingSenderId == messagingSenderId &&
      other.projectId == projectId;

  @override
  int get hashCode => Object.hash(apiKey, appId, messagingSenderId, projectId);

  /// Değerleri sızdırmaz (hata ayıklayıcı/log çıktısına yapılandırma düşmesin).
  @override
  String toString() => 'PushConfig(***)';
}
