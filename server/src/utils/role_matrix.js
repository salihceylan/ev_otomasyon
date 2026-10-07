'use strict';

// ==============================================================================
// Yetki matrisi (CONTRACTS §1.4) - WP-B'yi ilgilendiren satirlar.
//
// Rol sozlugu, `requireHomeAccess(allowedRoles)` ile AYNIDIR (auth_middleware.js):
//   'super_user'      global super kullanici (yalnizca listede ACIKCA varsa uyeliksiz gecer)
//   'service_user'    kalici servis personeli (staff) - home_users uyeligi olan evlerde
//   'service_session' PIN ile acilan, tek eve kapsamli gecici servis oturumu
//   'owner' | 'resident' | 'guest'   ev bazli roller
//
// Bu dosya hem route katmaninda (requireHomeAccess listesi) hem de servis katmaninda
// (derinlemesine savunma) kullanilir; boylece matris tek yerde durur.
// UI gizlemesi yetki degildir: sunucu esastir.
// ==============================================================================

const ROLES = Object.freeze({
  SUPER: 'super_user',
  STAFF: 'service_user',
  SESSION: 'service_session',
  OWNER: 'owner',
  RESIDENT: 'resident',
  GUEST: 'guest',
});

const ALL_ROLES = Object.freeze([
  ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT, ROLES.GUEST,
]);

// Yetenek -> izinli roller (matris satirlari).
const CAPABILITIES = Object.freeze({
  // Durum gorme (state / endpoint listesi / cihaz listesi / cocuk kilidi durumu)
  view: ALL_ROLES,
  // Role / panjur komutu (gecerli misafir dahil)
  control: ALL_ROLES,
  // Toplu komut (all_*) ve "hepsini kapat": misafir YOK
  group: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT]),
  // Cocuk kilidi / gece huzur bildirimi ayari: misafir YOK
  child_lock: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT]),
  // Panjur kalibrasyonu, kanal adi/oda: aile sakini ve misafir YOK
  calibrate: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]),
  // Devreye alma (commissioning): ev sahibi/sakin/misafir YOK
  commission: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION]),
  // Pano degisimi
  replace_board: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]),
  // Cihaz yerel anahtari (LAN dogrudan mod) - CONTRACTS §1.5 (A'nin LOCAL_KEY kumesiyle ayni)
  local_key: Object.freeze([ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT]),
  // Cihaz MQTT kimligini (tek seferlik) yeniden uretme: kurulum/pano yetkisiyle ayni
  device_credential: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]),
  // Uygulama (salt-okunur) MQTT kimligi: her gecerli uye
  mqtt_credentials: ALL_ROLES,
  // --- Guvenlik modulu (WP-S4, tasarim §5.2.4; misafir karari §7.2b-4) ---
  // Guvenli yon: vanayi KAPATMAK, sireni/fani SUSTURMAK. Mevcut `control` ile ayni kume (misafir dahil).
  actuator_close: ALL_ROLES,
  // Alarm onayi / susturma: misafir YOK
  safety_ack: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT]),
  // Su vanasi acma, siren/fan/generic acma: misafir YOK. GAZ VANASI ACMA HICBIR ROLDE YOK (yalniz yerinde, [K-4]).
  actuator_control: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT]),
  // Bolge testi ve guvenlik yapilandirmasi: aile sakini ve misafir YOK
  safety_test: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]),
  safety_config: Object.freeze([ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]),
  // Hirsiz alarmi kurma/cozme (Faz 2 F2.B.6, karar F2-3): YALNIZ ev sakinleri. Misafir ve servis rolleri (super/staff/
  // servis oturumu) buluttan YAPAMAZ (gizlilik/hirsizlik riski); kurulumda test LAN (yerel anahtar) ya da CLI ile yapilir.
  safety_arm: Object.freeze([ROLES.OWNER, ROLES.RESIDENT]),
});

/**
 * `requireHomeAccess(...)` listesi (kopya doner; auth_middleware dizi bekler).
 * @param {string} capability
 */
function rolesFor(capability) {
  const roles = CAPABILITIES[capability];
  if (!roles) throw new Error(`Bilinmeyen yetenek: ${capability}`);
  return roles.slice();
}

/**
 * `req.homeAccess` -> matristeki etkin rol.
 * is_super / is_service_session bayraklari role'den ONCE degerlendirilir.
 */
function effectiveRole(homeAccess) {
  if (!homeAccess || typeof homeAccess !== 'object') return null;
  if (homeAccess.is_super === true) return ROLES.SUPER;
  if (homeAccess.is_service_session === true) return ROLES.SESSION;
  const role = homeAccess.role;
  if (role === 'super_user') return ROLES.SUPER;
  if (role === 'service_session') return ROLES.SESSION;
  return typeof role === 'string' ? role : null;
}

/** Etkin rol bu yetenege sahip mi? Bilinmeyen rol/yetenek = HAYIR (beyaz liste). */
function can(capability, homeAccessOrRole) {
  const allowed = CAPABILITIES[capability];
  if (!allowed) return false;
  const role =
    typeof homeAccessOrRole === 'string' ? homeAccessOrRole : effectiveRole(homeAccessOrRole);
  return role !== null && allowed.includes(role);
}

/** Kisitli roller (misafir) icin kisa kontrol. */
function isGuest(homeAccessOrRole) {
  const role =
    typeof homeAccessOrRole === 'string' ? homeAccessOrRole : effectiveRole(homeAccessOrRole);
  return role === ROLES.GUEST;
}

module.exports = {
  ROLES,
  ALL_ROLES,
  CAPABILITIES,
  rolesFor,
  effectiveRole,
  can,
  isGuest,
};
