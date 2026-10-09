#include "ConfigManager.h"
#include "LocalKeyFp.h"
#include <mbedtls/md.h>
#include <string.h>
#include <stdlib.h>

using namespace sysconfig_detail;   // isAsciiRange, copyStr, terminate (SystemConfig.h)

// ---------------------------------------------------------------------------------------------
// ConfigManager
// ---------------------------------------------------------------------------------------------
ConfigManager& ConfigManager::instance() {
  static ConfigManager mgr;
  return mgr;
}

ConfigManager::ConfigManager()
    : _mutex(nullptr), _prefsOk(false), _generation(0), _resetCount(0), _keyGen(0), _fpGen(0), _fpValid(false) {
  memset(_fp, 0, sizeof(_fp));
  _mutex = xSemaphoreCreateRecursiveMutex();
  applyDefaults();
}

void ConfigManager::lock() {
  if (_mutex) xSemaphoreTakeRecursive(_mutex, portMAX_DELAY);
}

void ConfigManager::unlock() {
  if (_mutex) xSemaphoreGiveRecursive(_mutex);
}

// RAM'i varsayılana çeker. NVS'e DOKUNMAZ (yapıcı da kullanır). Kimlik alanları boş kalır.
void ConfigManager::applyDefaults() {
  memset(&config, 0, sizeof(config));
  keyChanged();   // local_key silindi (load/resetToDefaults sonra geri yazar): lk_fp önbelleği geçersiz

  copyStr(config.device_name, "AHBU Akilli Ev Kontrol");
  config.wifi_sta_enabled = false;
  config.rs485_baud = 9600;

  // Ek Genişletme Modülü Varsayılanları
  config.ext_module_enabled = false;
  config.ext_module_channels = 0;
  config.ext_module_address = 1;

  // Güvenli MQTTS: sunucu/port varsayılan, KİMLİK BOŞ (provizyonla gelir)
  config.mqtt_enabled = true;
  copyStr(config.mqtt_server, DEFAULT_MQTT_SERVER);
  config.mqtt_port = DEFAULT_MQTT_PORT;

  // local_key / ap_pass boş = provizyonsuz cihaz (memset ile sıfırlandı)

  // Varsayılan röle / DI tablosu (sahip kararı 2026-10-09): HİÇBİR rölenin sabit rolü yok. Yerel röleler "Röle N" genel aç-kapa
  // (süre 0), ek modül röleleri "Ek Modül Röle N"; DI n -> röle n TOGGLE. Panjur eşleşmesi/kilidi yalnız servisin yazdığı
  // şablon/yapılandırmadan gelir (eskiden röle 1-4 "Salon/Oda Panjur" ve DI 1/3 panjur butonu olarak gelirdi).
  applyFactoryRelayDefaults(config);
  applyFactoryDiDefaults(config);
}

void ConfigManager::begin() {
  ConfigLock lk(*this);
  _prefsOk = prefs.begin(NVS_NS_CFG, false);
  if (!_prefsOk) {
    // NVS açılamadı: yerel çalışma için RAM varsayılanlarıyla devam et, yazma denemeleri false döner.
    printf("[CONFIG] HATA: NVS '%s' acilamadi, RAM varsayilanlariyla devam.\r\n", NVS_NS_CFG);
    applyDefaults();
    config.validate();
    return;
  }
  load();
}

void ConfigManager::load() {
  ConfigLock lk(*this);
  if (!_prefsOk) {
    applyDefaults();
    config.validate();
    return;
  }

  if (!prefs.isKey("cfg_init")) {
    // İlk açılış: varsayılanları yaz
    applyDefaults();
    config.validate();
    if (!save()) printf("[CONFIG] UYARI: ilk acilis varsayilanlari NVS'e yazilamadi.\r\n");
    return;
  }

  // Eksik anahtarlar varsayılanı korusun diye varsayılandan başla.
  applyDefaults();

  // Dizgi okumaları yalnızca anahtar VARSA yapılır: Arduino getString() eksik anahtarda log_e basar
  // (eski firmware'den yükseltilen cihazlarda "lk"/"ap_pw" yoktur). Eksikse varsayılan (boş) korunur.
  auto readStr = [&](const char* key, char* dst, size_t cap) {
    if (prefs.isKey(key)) prefs.getString(key, dst, cap);
  };
  readStr("dev_name", config.device_name, sizeof(config.device_name));
  readStr("sta_ssid", config.wifi_ssid, sizeof(config.wifi_ssid));
  readStr("sta_pass", config.wifi_pass, sizeof(config.wifi_pass));
  config.wifi_sta_enabled = prefs.getBool("sta_en", false);
  config.rs485_baud = prefs.getUInt("rs_baud", 9600);

  config.ext_module_enabled = prefs.getBool("ext_en", false);
  config.ext_module_channels = prefs.getUChar("ext_ch", 0);
  config.ext_module_address = prefs.getUChar("ext_addr", 1);

  // Güvenli MQTTS (kimlik yoksa BOŞ kalır; derleme içi varsayılan yok)
  config.mqtt_enabled = prefs.getBool("mq_en", true);
  readStr("mq_srv", config.mqtt_server, sizeof(config.mqtt_server));
  config.mqtt_port = prefs.getUShort("mq_port", DEFAULT_MQTT_PORT);
  readStr("mq_usr", config.mqtt_user, sizeof(config.mqtt_user));
  readStr("mq_pwd", config.mqtt_pass, sizeof(config.mqtt_pass));

  // Yerel erişim kimliği
  readStr("lk", config.local_key, sizeof(config.local_key));
  readStr("ap_pw", config.ap_pass, sizeof(config.ap_pass));

  // GÖÇ: eski firmware'in NVS'e yazdığı paylaşımlı "home_*" MQTT kimliği artık geçersiz/ifşa olmuş
  // sayılır (CONTRACTS §2.2 legacy). Silinir; cihaz yeniden provizyon (POST /api/mqtt/config) bekler.
  bool legacyPurged = false;
  if (strncmp(config.mqtt_user, "home_", 5) == 0) {
    memset(config.mqtt_user, 0, sizeof(config.mqtt_user));
    memset(config.mqtt_pass, 0, sizeof(config.mqtt_pass));
    legacyPurged = true;
    printf("[CONFIG] Eski paylasimli MQTT kimligi silindi; yeni kimlik provizyonu gerekli.\r\n");
  }

  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "r_nm_%d", i);
    readStr(key, config.relays[i].name, sizeof(config.relays[i].name));

    snprintf(key, sizeof(key), "r_tp_%d", i);
    config.relays[i].type = prefs.getUChar(key, config.relays[i].type);

    snprintf(key, sizeof(key), "r_rt_%d", i);
    config.relays[i].runtime_sec = prefs.getUShort(key, config.relays[i].runtime_sec);
  }

  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "d_nm_%d", i);
    readStr(key, config.dis[i].name, sizeof(config.dis[i].name));

    snprintf(key, sizeof(key), "d_tr_%d", i);
    config.dis[i].target_relay = prefs.getUChar(key, config.dis[i].target_relay);

    snprintf(key, sizeof(key), "d_md_%d", i);
    config.dis[i].mode = prefs.getUChar(key, config.dis[i].mode);
  }

  // Bozuk/aralık dışı NVS değeri hiçbir zaman olduğu gibi kullanılmaz.
  bool wasValid = config.validate();
  if (!wasValid || legacyPurged) {
    printf("[CONFIG] Yapilandirma dogrulamada onarildi, NVS'e geri yaziliyor.\r\n");
    save();
  }
}

bool ConfigManager::save() {
  ConfigLock lk(*this);
  if (!_prefsOk) return false;

  config.validate();   // hiçbir yazma yolu doğrulamasız NVS'e değer yazmaz
  const bool ok = writeAll(config);
  _generation = _generation + 1;
  return ok;
}

// v1.3.0 (K-Ş3, şablon uygulama): canlı RAM'e DOKUNMADAN verilen yapılandırmayı NVS'e yazar (yalnız değişen anahtarlar). Çağıran
// adayı doğrulamış olmalıdır; burada ayrıca kopya üzerinde validate() çalışır (canlı yapılandırma değişmez). Başarısız yazımda çağıran
// eski yapılandırmayı aynı yolla geri yazar (template/TemplateApply).
bool ConfigManager::saveCandidate(const SystemConfig& c) {
  ConfigLock lk(*this);
  if (!_prefsOk) return false;
  SystemConfig* v = (SystemConfig*)malloc(sizeof(SystemConfig));
  if (!v) return false;
  memcpy(v, &c, sizeof(SystemConfig));
  v->validate();
  const bool ok = writeAll(*v);
  memset(v, 0, sizeof(SystemConfig));   // kimlik alanları öbekte kalmasın
  free(v);
  return ok;
}

bool ConfigManager::writeAll(const SystemConfig& config) {
  bool ok = true;
  // NVS AŞINMA KORUMASI: yalnızca DEĞİŞEN değerler flash'a yazılır (okuma-karşılaştırma uygulama katmanındadır).
  auto putStr = [&](const char* key, const char* val) {
    char cur[72];
    if (prefs.isKey(key)) {
      // DİKKAT: Arduino Preferences::getString(key, buf, max) NUL DAHİL uzunluk döndürür (0 = hata); bu yüzden
      // uzunlukla değil İÇERİKLE karşılaştırılır (uzunluk karşılaştırması gerçek donanımda hiç eşleşmezdi).
      size_t n = prefs.getString(key, cur, sizeof(cur));
      if (n > 0 && strcmp(cur, val) == 0) return;                  // aynı: yazma
    }
    size_t want = strlen(val);
    size_t got = prefs.putString(key, val);
    if (got != want) {          // boş dizgede putString 0 döner; want==0 iken eşit
      ok = false;
      printf("[CONFIG] HATA: '%s' NVS'e yazilamadi.\r\n", key);
    }
  };
  auto putU8 = [&](const char* key, uint8_t v) {
    if (prefs.isKey(key) && prefs.getUChar(key, (uint8_t)(v ^ 0xFF)) == v) return;
    if (prefs.putUChar(key, v) != sizeof(uint8_t)) { ok = false; printf("[CONFIG] HATA: '%s' NVS'e yazilamadi.\r\n", key); }
  };
  auto putBoolIfChanged = [&](const char* key, bool v) {
    if (prefs.isKey(key) && prefs.getBool(key, !v) == v) return;
    if (prefs.putBool(key, v) != sizeof(uint8_t)) { ok = false; printf("[CONFIG] HATA: '%s' NVS'e yazilamadi.\r\n", key); }
  };
  auto putU16 = [&](const char* key, uint16_t v) {
    if (prefs.isKey(key) && prefs.getUShort(key, (uint16_t)(v ^ 0xFFFF)) == v) return;
    if (prefs.putUShort(key, v) != sizeof(uint16_t)) { ok = false; printf("[CONFIG] HATA: '%s' NVS'e yazilamadi.\r\n", key); }
  };
  auto putU32 = [&](const char* key, uint32_t v) {
    if (prefs.isKey(key) && prefs.getUInt(key, v ^ 0xFFFFFFFFu) == v) return;
    if (prefs.putUInt(key, v) != sizeof(uint32_t)) { ok = false; printf("[CONFIG] HATA: '%s' NVS'e yazilamadi.\r\n", key); }
  };

  putStr("dev_name", config.device_name);
  putStr("sta_ssid", config.wifi_ssid);
  putStr("sta_pass", config.wifi_pass);
  putBoolIfChanged("sta_en", config.wifi_sta_enabled);
  putU32("rs_baud", config.rs485_baud);

  putBoolIfChanged("ext_en", config.ext_module_enabled);
  putU8("ext_ch", config.ext_module_channels);
  putU8("ext_addr", config.ext_module_address);

  // Güvenli MQTTS
  putBoolIfChanged("mq_en", config.mqtt_enabled);
  putStr("mq_srv", config.mqtt_server);
  putU16("mq_port", config.mqtt_port);
  putStr("mq_usr", config.mqtt_user);
  putStr("mq_pwd", config.mqtt_pass);

  // Yerel erişim kimliği
  putStr("lk", config.local_key);
  putStr("ap_pw", config.ap_pass);

  uint8_t totalR = config.totalRelays();
  uint8_t totalD = config.totalDIs();

  for (int i = 0; i < totalR; i++) {
    char key[16];
    snprintf(key, sizeof(key), "r_nm_%d", i);
    putStr(key, config.relays[i].name);

    snprintf(key, sizeof(key), "r_tp_%d", i);
    putU8(key, config.relays[i].type);

    snprintf(key, sizeof(key), "r_rt_%d", i);
    putU16(key, config.relays[i].runtime_sec);
  }

  for (int i = 0; i < totalD; i++) {
    char key[16];
    snprintf(key, sizeof(key), "d_nm_%d", i);
    putStr(key, config.dis[i].name);

    snprintf(key, sizeof(key), "d_tr_%d", i);
    putU8(key, config.dis[i].target_relay);

    snprintf(key, sizeof(key), "d_md_%d", i);
    putU8(key, config.dis[i].mode);
  }

  // "cfg_init" EN SON yazılır: yazma yarıda kalırsa (elektrik kesintisi) bir sonraki açılış
  // varsayılanlarla yeniden başlar, yarım yapılandırma "geçerli" sayılmaz.
  putBoolIfChanged("cfg_init", true);
  return ok;
}

// NVS'teki uygulama anahtarlarını siler. Kimlik/provizyon anahtarları (mq_*, lk, ap_pw) KORUNUR.
bool ConfigManager::eraseAppKeys() {
  bool ok = true;
  auto rm = [&](const char* key) {
    if (prefs.isKey(key) && !prefs.remove(key)) {
      ok = false;
      printf("[CONFIG] HATA: '%s' silinemedi.\r\n", key);
    }
  };

  rm("cfg_init");
  rm("dev_name");
  rm("sta_ssid");
  rm("sta_pass");
  rm("sta_en");
  rm("rs_baud");
  // Ek modül anahtarları (eskiden sıfırlamada NVS'te kalıp hayalet yapılandırma doğuruyordu)
  rm("ext_en");
  rm("ext_ch");
  rm("ext_addr");

  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "r_nm_%d", i);  rm(key);
    snprintf(key, sizeof(key), "r_tp_%d", i);  rm(key);
    snprintf(key, sizeof(key), "r_rt_%d", i);  rm(key);
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "d_nm_%d", i);  rm(key);
    snprintf(key, sizeof(key), "d_tr_%d", i);  rm(key);
    snprintf(key, sizeof(key), "d_md_%d", i);  rm(key);
  }
  return ok;
}

static bool clearNamespace(const char* ns) {
  Preferences p;
  if (!p.begin(ns, false)) return true;   // ad alanı yoksa silinecek bir şey yok
  bool r = p.clear();
  p.end();
  return r;
}

bool ConfigManager::resetToDefaults() {
  ConfigLock lk(*this);

  // Kimlik/provizyon alanlarını koru
  char keepLocalKey[sizeof(config.local_key)];
  char keepApPass[sizeof(config.ap_pass)];
  char keepMqttServer[sizeof(config.mqtt_server)];
  char keepMqttUser[sizeof(config.mqtt_user)];
  char keepMqttPass[sizeof(config.mqtt_pass)];
  uint16_t keepMqttPort = config.mqtt_port;
  bool keepMqttEnabled = config.mqtt_enabled;
  memcpy(keepLocalKey, config.local_key, sizeof(keepLocalKey));
  memcpy(keepApPass, config.ap_pass, sizeof(keepApPass));
  memcpy(keepMqttServer, config.mqtt_server, sizeof(keepMqttServer));
  memcpy(keepMqttUser, config.mqtt_user, sizeof(keepMqttUser));
  memcpy(keepMqttPass, config.mqtt_pass, sizeof(keepMqttPass));

  applyDefaults();

  memcpy(config.local_key, keepLocalKey, sizeof(keepLocalKey));
  memcpy(config.ap_pass, keepApPass, sizeof(keepApPass));
  memcpy(config.mqtt_server, keepMqttServer, sizeof(keepMqttServer));
  memcpy(config.mqtt_user, keepMqttUser, sizeof(keepMqttUser));
  memcpy(config.mqtt_pass, keepMqttPass, sizeof(keepMqttPass));
  config.mqtt_port = keepMqttPort;
  config.mqtt_enabled = keepMqttEnabled;
  config.validate();

  if (!_prefsOk) return false;

  bool ok = eraseAppKeys();
  if (!clearNamespace(NVS_NS_AUTO)) ok = false;   // çocuk kilidi
  if (!clearNamespace(NVS_NS_POS)) ok = false;    // panjur konumları
  if (!clearNamespace(NVS_NS_SAFETY)) ok = false; // güvenlik yapılandırması (NVS_NS_LATCH bilinçli olarak SİLİNMEZ [Y-5])
  if (!clearNamespace(NVS_NS_TPL)) ok = false;    // kurulum şablonu kaydı (v1.3.0): yapılandırma varsayılana döndü
  if (!save()) ok = false;
  _resetCount = _resetCount + 1;                  // SmartAutomation RAM'deki çocuk kilidini de sıfırlar
  return ok;
}

// ---------------------------------------------------------------------------------------------
// Kimlik/provizyon yardımcıları
// ---------------------------------------------------------------------------------------------
// RAM + NVS BİRLİKTE değişir ya da hiçbiri: kalıcılaştırma başarısızsa RAM'deki eski değer geri yüklenir (aksi halde
// cihaz yeniden başlayana dek "yeni anahtarla provizyonlu" görünür, NVS'te ise eski/boş durur).
bool ConfigManager::setLocalKey(const char* key) {
  ConfigLock lk(*this);
  char old[sizeof(config.local_key)];
  memcpy(old, config.local_key, sizeof(old));
  if (!config.setLocalKey(key)) return false;
  const bool ok = _prefsOk && (prefs.putString("lk", config.local_key) == strlen(config.local_key));
  if (!ok) memcpy(config.local_key, old, sizeof(old));
  memset(old, 0, sizeof(old));
  if (ok) keyChanged();
  return ok;
}

bool ConfigManager::setApPass(const char* pass) {
  ConfigLock lk(*this);
  char old[sizeof(config.ap_pass)];
  memcpy(old, config.ap_pass, sizeof(old));
  if (!config.setApPass(pass)) return false;
  const bool ok = _prefsOk && (prefs.putString("ap_pw", config.ap_pass) == strlen(config.ap_pass));
  if (!ok) memcpy(config.ap_pass, old, sizeof(old));
  memset(old, 0, sizeof(old));
  return ok;
}

bool ConfigManager::clearLocalKey() {
  ConfigLock lk(*this);
  memset(config.local_key, 0, sizeof(config.local_key));
  keyChanged();
  if (!_prefsOk) return false;
  if (!prefs.isKey("lk")) return true;
  return prefs.remove("lk");
}

// Denetim + biçim + yazma TEK kilit altında (ConfigLock özyinelemeli: setApPass/setLocalKey aynı kilidi yeniden alır).
ConfigManager::ProvisionResult ConfigManager::provisionIfEmpty(const char* key, const char* pass) {
  ConfigLock lk(*this);
  if (config.hasLocalKey()) return PROVISION_ALREADY;
  if (!isAsciiRange(key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) return PROVISION_INVALID_KEY;
  if (!isAsciiRange(pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) return PROVISION_INVALID_AP_PASS;

  char oldPass[sizeof(config.ap_pass)];
  memcpy(oldPass, config.ap_pass, sizeof(oldPass));
  ProvisionResult r = PROVISION_STORAGE;
  if (setApPass(pass)) {          // 1) ap_pass (yazılamazsa setApPass RAM'i geri aldı: hiçbir şey değişmedi)
    if (setLocalKey(key)) {       // 2) local_key (yazılamazsa setLocalKey RAM'i geri aldı: local_key boş)
      r = PROVISION_OK;
    } else {
      restoreApPass(oldPass);     // yarım provizyon kalmasın: ap_pass da önceki hâline
    }
  }
  memset(oldPass, 0, sizeof(oldPass));
  return r;
}

// ap_pass'i önceki değerine döndürür. RAM, NVS'i izler: NVS geri yazılamazsa RAM de yeni değerde kalır (yeniden açılışta
// aynı değer okunur). Provizyonsuz cihazda ap_pass kullanılmaz (kurulum AP'si açıktır); yeniden deneme üstüne yazar.
void ConfigManager::restoreApPass(const char* old) {
  if (old[0] != '\0') {
    setApPass(old);               // RAM + NVS birlikte ya da hiçbiri
    return;
  }
  if (!_prefsOk) return;
  if (!prefs.isKey("ap_pw") || prefs.remove("ap_pw")) memset(config.ap_pass, 0, sizeof(config.ap_pass));
}

bool ConfigManager::setMqttCredentials(const char* server, uint16_t port, const char* user, const char* pass) {
  // Sunucu: 1..63 karakter, kontrol karakteri/boşluk yok. Kimlik: 1..47 / 1..63 yazdırılabilir ASCII.
  if (!isAsciiRange(server, 1, sizeof(config.mqtt_server) - 1, 0x21, 0x7E)) return false;
  if (port == 0) return false;
  if (!isAsciiRange(user, 1, sizeof(config.mqtt_user) - 1, 0x21, 0x7E)) return false;
  if (!isAsciiRange(pass, 1, sizeof(config.mqtt_pass) - 1, 0x20, 0x7E)) return false;

  ConfigLock lk(*this);
  copyStr(config.mqtt_server, server);
  config.mqtt_port = port;
  copyStr(config.mqtt_user, user);
  copyStr(config.mqtt_pass, pass);
  if (!_prefsOk) return false;

  bool ok = true;
  ok &= (prefs.putString("mq_srv", config.mqtt_server) == strlen(config.mqtt_server));
  ok &= (prefs.putUShort("mq_port", config.mqtt_port) == sizeof(uint16_t));
  ok &= (prefs.putString("mq_usr", config.mqtt_user) == strlen(config.mqtt_user));
  ok &= (prefs.putString("mq_pwd", config.mqtt_pass) == strlen(config.mqtt_pass));
  return ok;
}

bool ConfigManager::saveRelayRuntime(uint8_t relayIndex) {
  if (relayIndex >= MAX_TOTAL_RELAYS) return false;
  ConfigLock lk(*this);
  if (!_prefsOk) return false;
  char key[16];
  snprintf(key, sizeof(key), "r_rt_%d", relayIndex);
  return prefs.putUShort(key, config.relays[relayIndex].runtime_sec) == sizeof(uint16_t);
}

// ---------------------------------------------------------------------------------------------
// Yerel anahtar parmak izi (lk_fp; sözleşme 1, LocalKeyFp.h)
// ---------------------------------------------------------------------------------------------
static bool hmacSha256(const uint8_t* key, size_t keyLen, const uint8_t* msg, size_t msgLen, uint8_t* out) {
  const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return md && mbedtls_md_hmac(md, key, keyLen, msg, msgLen, out) == 0;
}

bool ConfigManager::localKeyFp(const char* uid, char* out, size_t cap) {
  if (!out || cap < lkfp::FP_BUF) return false;
  out[0] = '\0';
  char key[sizeof(config.local_key)];
  uint32_t gen;
  {
    ConfigLock lk(*this);
    if (!config.hasLocalKey()) return false;
    if (_fpValid && _fpGen == _keyGen) {
      memcpy(out, _fp, lkfp::FP_BUF);
      return true;
    }
    memcpy(key, config.local_key, sizeof(key));
    gen = _keyGen;
  }
  key[sizeof(key) - 1] = '\0';
  char fp[lkfp::FP_BUF];
  const bool ok = lkfp::compute(key, uid, fp, hmacSha256);   // HMAC kilit dışında
  memset(key, 0, sizeof(key));
  if (!ok) return false;
  {
    ConfigLock lk(*this);
    if (gen == _keyGen) {                                     // arada anahtar değişmediyse önbelleğe al
      memcpy(_fp, fp, sizeof(_fp));
      _fpGen = gen;
      _fpValid = true;
    }
  }
  memcpy(out, fp, lkfp::FP_BUF);
  return true;
}
