import 'package:flutter/foundation.dart';

enum PushPermission {
  /// İzin var (iOS'ta "geçici/sessiz" izin de buraya düşer: token alınıp kayıt yapılabilir).
  granted,

  /// Kullanıcı reddetti (Android 13+ "bir daha sorma" dahil: arayüz sistem ayarlarına yönlendirmelidir).
  denied,

  /// Henüz sorulmadı.
  notDetermined,

  /// Bu cihaz/derleme push desteklemiyor (web, masaüstü) ya da push gönderim katmanı yapılandırılmadı
  /// (bu sürümde hep böyle).
  unsupported,
}

/// Gelen FCM mesajının uygulamaya ait, platformdan bağımsız hali.
///
/// Platform paketinin mesaj türü (ör. FCM istemcisinin `RemoteMessage`'ı) uygulamaya sızmasın diye (test
/// edilebilirlik ve paket değişimine dayanıklılık) yalnızca ihtiyaç duyulan alanlar taşınır.
@immutable
class PushMessage {
  const PushMessage({required this.data, this.title, this.body});

  /// FCM `data` alanı (sunucu sözleşmesine göre değerlerin hepsi metin).
  final Map<String, dynamic> data;

  /// `RemoteMessage.notification?.title`.
  final String? title;

  /// `RemoteMessage.notification?.body`.
  final String? body;
}

/// FCM platform kanalının arkasındaki dar arayüz.
///
/// Koordinatör yalnızca bu arayüzü bilir: bu sürümde her zaman [UnsupportedPushGateway] (push gönderim katmanı
/// yapılandırılmadı: no-op; Firebase/APNs kullanılmaz), testlerde sahte bir uygulama kullanılır. İleride gerçek
/// push istenirse bu arayüzün yeni bir gerçeklemesi ayrıca eklenir.
/// Hiçbir yöntem istisna fırlatmaz (hata = `null`/[PushPermission.unsupported]/boş akış).
abstract class PushGateway {
  /// Platform (yalnız Android/iOS; web DEĞİL) VE yapılandırma tamam mı. [initialize] başarısız
  /// olursa `false`'a döner.
  bool get isSupported;

  /// Push istemcisini (gerçek bir gerçeklemede platform SDK'sını) başlatır. Idempotent; başlatma yalnızca
  /// burada yapılır. Başarısızlık istisna olarak değil, `isSupported == false` olarak bildirilir.
  Future<void> initialize();

  /// Mevcut izin durumu (kullanıcıya soru sormaz).
  Future<PushPermission> permissionStatus();

  /// Gerekirse sistem izin penceresini gösterir (Android 13+ ve iOS), sonucu döndürür.
  Future<PushPermission> requestPermission();

  /// FCM kayıt belirteci; alınamazsa `null`.
  Future<String?> getToken();

  /// Belirteç yenilendiğinde yeni değeri verir.
  Stream<String> get onTokenRefresh;

  /// Uygulama açıkken gelen mesajlar.
  Stream<PushMessage> get onForegroundMessage;

  /// Arka plandayken sistem bildirimine dokunulduğunda gelen mesajlar.
  Stream<PushMessage> get onMessageOpened;

  /// Uygulama kapalıyken bildirime dokunularak açıldıysa o mesaj (platform bir kez verir).
  Future<PushMessage?> getInitialMessage();

  /// Bu cihazın FCM kayıt belirtecini YERELDE geçersiz kılar (çıkış/oturum bitişi).
  ///
  /// Neden gerekli: sunucu bir belirteç satırını yalnızca FCM `UNREGISTERED` (kalıcı geçersiz) gördüğünde
  /// kapatır. Çıkış yapılmış bir telefonda belirteç geçerli kalırsa gönderim BAŞARILI olur ve gece
  /// bildirimi (ev adı + açık lamba özeti) çıkış yapmış telefona düşer. Belirteç iptal edilince sonraki
  /// gönderim `UNREGISTERED` döner ve sunucu satırı kendisi kapatır. Sunucuya `DELETE` gitse de gitmese
  /// de çağrılır; ikisi bağımsızdır.
  ///
  /// Sınır (bilinen): FCM silme isteği ağ ister; çevrimdışıyken başarısız olabilir (hata yutulur,
  /// koordinatör sonraki çıkışta yeniden dener). Süre sınırlıdır ve hiçbir zaman fırlatmaz.
  Future<void> deleteToken();
}

/// Hiçbir şey yapmayan uygulama: push gönderim katmanı yapılandırılmadı (bu sürümde tüm derlemeler) ve
/// desteklenmeyen platformlar.
///
/// Hiçbir platform kanalına dokunmaz (Firebase/APNs kullanılmaz); uygulama davranışı push eklenmeden önceki
/// haliyle birebir aynı kalır.
class UnsupportedPushGateway implements PushGateway {
  const UnsupportedPushGateway();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<PushPermission> permissionStatus() async => PushPermission.unsupported;

  @override
  Future<PushPermission> requestPermission() async => PushPermission.unsupported;

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();

  @override
  Stream<PushMessage> get onForegroundMessage => const Stream<PushMessage>.empty();

  @override
  Stream<PushMessage> get onMessageOpened => const Stream<PushMessage>.empty();

  @override
  Future<PushMessage?> getInitialMessage() async => null;

  @override
  Future<void> deleteToken() async {}
}
