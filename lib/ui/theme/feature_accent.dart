import 'tokens.dart';

/// Özellik vurgu haritası (WP-V9, TEK kaynak): her uygulama özelliği ekrandan ekrana AYNI renk ailesiyle görünür.
///
/// Eskiden aynı özellik çekmecede, konsol kutucuğunda, servis araç kartında ve sayfa başlığında farklı renkteydi
/// ('Pano Envanteri' amber / cyan / violet; 'Aboneler' emerald / cyan / sky; 'Sistem Doktoru' cyan / emerald; 'Pano
/// Değişimi' rose / cyan / violet; 'Wi-Fi Kurtarma' cyan / amber / sky) ve iki farklı özellik aynı rengi paylaşıyordu
/// (violet: servis PIN + pano değişimi; rose: acil sıfırlama + pano değişimi). Bu dosya çelişkileri tek haritayla çözer.
///
/// **İlkeler**
/// 1. AYNI özellik her yerde AYNI aile ([featureFamily]); çekmece, konsol kutucuğu/satırı, servis araç kartı, sayfa/diyalog
///    başlık orb'u, `NeonAppBar` orb'u ve ayar eylem kartı bu haritayı kullanır (ham `AppFamilies.x` değil).
/// 2. İki FARKLI özellik aynı listede (çekmece, konsol kutucukları, servis araç kartları, ayarlar 'Cihaz' bölümü) AYNI
///    aileyi paylaşmaz: [FeatureGroups] her listeyi tanımlar ve birim test benzersizliği kilitler.
/// 3. Anlam (şartname §2.1) korunur: rose yalnız tehlike (acil sıfırlama), amber uyarı/erişim (Wi-Fi kurtarma, servis PIN,
///    çocuk kilidi), emerald sağlık/başarı (doktor, biyometrik), violet gece/ek modül (pano değişimi, gece huzuru), cyan
///    marka/teknoloji (envanter, kurallar, telemetri, ayarlar), sky insan/birincil (aboneler, aile, görünüm, cihaz adresi),
///    slate idari/nötr (servis hesapları, servis modu).
/// 4. Rol satırları ÖZELLİK değildir ve haritada yoktur: tema satırı (güneş amber / ay violet), "Güvenli Çıkış" (rose,
///    tehlike rolü), birincil eylem düğmeleri (CTA gradyanı: sky), pano üst çubuğu simgeleri (marka cyan). Konsol kimliği
///    ise [AppFeature.superConsole] / [AppFeature.serviceConsole] ile haritadadır (çekmece başlığı + 'Konsol' satırı + konsol
///    başlık kartı AYNI rol rengini taşır).
enum AppFeature {
  // --- Servis / yönetim -------------------------------------------------------------------------------------
  /// Pano / cihaz envanteri ve karekod yönetimi.
  inventory(AppFamilies.cyan),

  /// Aboneler, daireler ve Home Admin atama (konsollardaki 'Devreye Alınan' sayacı da buraya bağlıdır).
  subscribers(AppFamilies.sky),

  /// Sistem doktoru (sağlık ve teşhis). Sonuç diyaloğunun başlık orb'u sağlık durumunu (emerald/amber/rose) gösterir; boşta
  /// ve yüklenirken bu aile.
  doctor(AppFamilies.emerald),

  /// Pano değişimi (afet ve hasar): arızalı panonun verilerini yenisine aktarma.
  boardReplace(AppFamilies.violet),

  /// Acil pano sıfırlama (eski sahibine ulaşılamıyor): TEK tehlike özelliği.
  emergencyReset(AppFamilies.rose),

  /// Wi-Fi yapılandırma ve kurtarma (modem/şifre değişimi, pano kurulum ağı).
  wifiRecovery(AppFamilies.amber),

  /// Yetkili servis PIN'i (ev sahibi üretir; servis oturumu açar).
  servicePin(AppFamilies.amber),

  /// Servis hesapları ve yönetimi (servis sorumluları, müşteri hesapları).
  management(AppFamilies.slate),

  /// Devreye alma / servis modu / kurulum sihirbazı (servis paneli).
  commissioning(AppFamilies.slate),

  // --- Ev ---------------------------------------------------------------------------------------------------
  /// Aile ve misafir yönetimi, davet.
  family(AppFamilies.sky),

  /// Daire devri (ev sahibi): aile yönetiminin uyarı düzeyinde eylemi.
  ownershipTransfer(AppFamilies.amber),

  /// Zamanlı kurallar.
  rules(AppFamilies.cyan),

  /// Gece huzur bildirimi / huzur modu ayarı.
  nightPeace(AppFamilies.violet),

  /// Çocuk kilidi.
  childLock(AppFamilies.amber),

  /// Biyometrik giriş.
  biometric(AppFamilies.emerald),

  /// Cihaz adresi (yerel ağ adresi).
  deviceHost(AppFamilies.sky),

  /// Cihaz telemetrisi.
  telemetry(AppFamilies.cyan),

  /// Görünüm / tema.
  appearance(AppFamilies.sky),

  /// Cihaz ve sistem ayarları sayfası.
  settings(AppFamilies.cyan),

  // --- Konsol kimliği (rol) ---------------------------------------------------------------------------------
  /// Süper yönetici konsolu (çekmece başlığı/satırı, konsol başlık kartı).
  superConsole(AppFamilies.violet),

  /// Yetkili servis konsolu.
  serviceConsole(AppFamilies.cyan);

  const AppFeature(this.accentFamily);

  /// Özelliğin renk ailesi (orb, kenar, düğme, rozet). `const` bağlamda kullanılamaz (enum alanı sabit ifade değildir):
  /// `OrbIconBadge(family: AppFeature.inventory.accentFamily)` ya da [featureFamily] gibi, `const` OLMAYAN kurucularda
  /// kullanın. (Alan adı `family` DEĞİL: [AppFeature.family] özellik değeridir.)
  final AccentFamily accentFamily;
}

/// [feature] özelliğinin renk ailesi (tek harita). `feature.accentFamily` ile aynıdır.
AccentFamily featureFamily(AppFeature feature) => feature.accentFamily;

/// Birlikte görünen özellik listeleri (çekmece satırları, konsol kutucukları, araç kartları, ayar bölümü): bir listedeki
/// iki özellik AYNI aileyi paylaşmaz (birim test `feature_accent_test.dart` kilitler). Bir özellik listede birden çok
/// kez görünebilir (aynı özellik = aynı aile; ör. konsolda sayaç + eylem kartı); burada her özellik BİR kez yazılır.
abstract final class FeatureGroups {
  /// Süper yönetici çekmecesi (tema/çıkış satırları rol satırıdır: listede değil).
  static const List<AppFeature> superDrawer = <AppFeature>[
    AppFeature.superConsole,
    AppFeature.inventory,
    AppFeature.management,
    AppFeature.subscribers,
    AppFeature.doctor,
    AppFeature.emergencyReset,
  ];

  /// Kalıcı servis personeli çekmecesi.
  static const List<AppFeature> serviceDrawer = <AppFeature>[
    AppFeature.serviceConsole,
    AppFeature.subscribers,
    AppFeature.commissioning,
    AppFeature.boardReplace,
    AppFeature.wifiRecovery,
    AppFeature.emergencyReset,
  ];

  /// Süper yönetici konsolu: sayaç kutucukları + hızlı işlem satırları.
  static const List<AppFeature> superConsole = <AppFeature>[
    AppFeature.management,
    AppFeature.inventory,
    AppFeature.subscribers,
    AppFeature.doctor,
  ];

  /// Yetkili servis konsolu: sayaç kutucukları + görev satırları.
  static const List<AppFeature> serviceConsole = <AppFeature>[
    AppFeature.inventory,
    AppFeature.subscribers,
    AppFeature.commissioning,
    AppFeature.boardReplace,
    AppFeature.wifiRecovery,
    AppFeature.emergencyReset,
  ];

  /// Servis panelinin "Yönetim araçları" kartları.
  static const List<AppFeature> servicePanelTools = <AppFeature>[
    AppFeature.subscribers,
    AppFeature.inventory,
    AppFeature.boardReplace,
    AppFeature.doctor,
    AppFeature.management,
  ];

  /// Servis yönetimi sayfasının "Görevler ve Araçlar" sekmesi (kurulum sihirbazı kısayolu dahil).
  static const List<AppFeature> managementTools = <AppFeature>[
    AppFeature.commissioning,
    AppFeature.subscribers,
    AppFeature.inventory,
    AppFeature.boardReplace,
    AppFeature.doctor,
  ];

  /// Ayarlar sayfası 'Cihaz' bölümü kartları.
  static const List<AppFeature> settingsDevice = <AppFeature>[
    AppFeature.doctor,
    AppFeature.wifiRecovery,
    AppFeature.boardReplace,
    AppFeature.deviceHost,
    AppFeature.telemetry,
  ];

  /// Ayarlar sayfası 'Otomasyon' bölümü kartları.
  static const List<AppFeature> settingsAutomation = <AppFeature>[
    AppFeature.nightPeace,
    AppFeature.rules,
  ];

  /// Tüm gruplar (ad -> özellikler): test ve belge için.
  static const Map<String, List<AppFeature>> all = <String, List<AppFeature>>{
    'superDrawer': superDrawer,
    'serviceDrawer': serviceDrawer,
    'superConsole': superConsole,
    'serviceConsole': serviceConsole,
    'servicePanelTools': servicePanelTools,
    'managementTools': managementTools,
    'settingsDevice': settingsDevice,
    'settingsAutomation': settingsAutomation,
  };
}
