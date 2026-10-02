import 'push_config.dart';
import 'push_gateway.dart';

/// Uygulamanın kullanacağı [PushGateway]'i üretir (Firebase'SİZ sürüm).
///
/// Push gönderim katmanı yapılandırılmadı: [config] ne olursa olsun hiçbir şey yapmayan [UnsupportedPushGateway]
/// döner (no-op). Firebase/APNs kullanılmaz; projede `firebase_core` / `firebase_messaging` paketleri yoktur,
/// push özelliği sessizce kapalı kalır ve uygulama push'suz sürümle birebir aynı davranır (bildirim yalnızca
/// uygulama açıkken ya da açılınca yedek afişle görünür).
///
/// İleride gerçek push istenirse ayrıca eklenir: yeni bir [PushGateway] gerçeklemesi yazılır ve bu fabrika
/// [config] doluysa onu döndürecek şekilde değiştirilir; [PushConfig] ve bu fonksiyonun imzası aynı kalabilir
/// (ayrıntı: ENTEGRASYON.md, "Ek: Firebase ileride istenirse").
PushGateway createPushGateway(PushConfig? config) => const UnsupportedPushGateway();
