'use strict';

// ==============================================================================
// AHBU Akilli Ev - Uc nokta YERLESIM esitleme: saf yardimcilar          [CONTRACTS §2.4b]
// ==============================================================================
//
// Pano her `state` mesajinda her rolenin id + ad + tipini ve gecerli panjur ciftlerini yayinlar (CONTRACTS §2.4).
// Bu modul o bildirimden bulut `endpoints` satirlarinin NASIL OLMASI GEREKTIGINI hesaplar: servis sorumlusu panoyu
// (hotspot/portal) ayarlar, daire kullanicisinin ekranindaki kontroller kendiliginden ayni yerlesimi alir.
//
// G/C YOKTUR (veritabani, saat, gunluk yok): tum fonksiyonlar saftir ve birim testlidir.
// Uygulayan servis: services/endpoint_layout_sync.js (tek transaction, satir kilidi, denetim kaydi).
//
// KURALLAR (ozet; ayrinti docs/superpowers/specs/2026-10-03-uc-nokta-yerlesim-esitleme-design.md)
//   * TIP ve PANJUR CIFTI: pano esastir. `shutter_up`+`shutter_down` cifti -> iki `shutter` satiri (cift N = kanal
//     2N-1 ve 2N); `impulse` -> `impulse`; `light` -> `light` (bulutta `plug` secilmisse `plug` KORUNUR: priz yalniz
//     bulutta bilinen kozmetik bir ayrimdir).
//   * AD: panodaki ad fabrika varsayilani DEGILSE (servis sorumlusu ad vermis) ve (a) buluttaki ad hala otomatik bir
//     adsa, (b) pano tarafinda ad DEGISMISSE (son yazan kazanir) ya da (c) kanalin sinifi (role <-> panjur) degismisse
//     bulut adi panodan alinir. Kullanici bulutta ad degistirdiyse ve pano tarafi degismediyse bulut adi KORUNUR.
//     Panonun ASCII fabrika adlari ("Salon Aydinlatma") buluta TASINMAZ; bulutun Turkce varsayilanlari kalir.
//   * ODA: panoda oda yoktur. Oda yalniz otomatik degerdeyse (tohum odasi / addan turetilmis / "Genel") yeni addan
//     yeniden turetilir; kullanicinin verdigi oda KORUNUR.
//   * SATIR KUMESI: bildirilen 1..N kanallar icin eksik satir ACILIR; N'den buyuk kanalli satirlar yalniz
//     `confirmShrink` ile SILINIR (servis ayni kuculmeyi ikinci kez gorunce onaylar).
//   * ZAMANLI KURALLAR: sinifi degisen/silinen kanallara bagli kurallar devre disi birakilmak uzere listelenir
//     (lambaya yazilmis "ac" kurali panjura donen kanalda motoru surmesin). Lamba/priz <-> darbe degisimi de role
//     kurallarini kapatir (D2); lamba <-> priz kozmetiktir.
//   * GECICI (fabrika) PANO (D1): servis `provisional` verirse yikici adimlar (panjur -> role, silme, ad/oda, taban)
//     ertelenir; yalniz guvenlik/ekleme adimlari uygulanir. Pano degisiminde kullanici verisi kaybolmaz.

const MAX_CHANNELS = 40; // endpoints.channel_index CHECK 1..40 = firmware MAX_TOTAL_RELAYS
const NAME_MAX = 100; // endpoints.name VARCHAR(100)
const DEFAULT_ROOM = 'Genel';
const DEFAULT_SHUTTER_SEC = 20; // firmware SHUTTER_RUNTIME_DEFAULT_SEC = tohum sablonu
const BASE_VERSION = 1;
const MIN_STATE_VERSION = 2; // firmware `doc["v"] = 2` (relays[].name/type bu surumle gelir)

/** Panonun `relays[].type` metinleri (MqttManager.cpp relayTypeName). */
const RELAY_TYPES = Object.freeze(['light', 'impulse', 'shutter_up', 'shutter_down']);

/**
 * Eylemci rolleri (state v:3 `relays[].act`, tasarim §3.1 kural 6, K1). Bu metinler endpoints.actuator_type'a yazilir
 * (033 CHECK). `type` alani eylemci rolesinde de bugunku RelayType adiyla (light/impulse) gelir ve DEGISMEZ.
 * Bilinmeyen (ileride eklenecek) bir act metni `generic` sayilir: eylemci olarak isaretlemek guvenli taraftir
 * (lamba sayilmaz, duz role komutu ve zamanli kural almaz).
 */
const ACTUATOR_TYPES = Object.freeze(['valve', 'siren', 'fan', 'generic']);
const ACT_RE = /^[a-z][a-z0-9_]{0,15}$/;

/** Ham `act` -> { ok, act }: yok/null -> act null; gecerli metin -> bilinen ya da 'generic'; baska her sey supheli. */
function readAct(raw) {
  if (raw === undefined || raw === null) return { ok: true, act: null };
  if (typeof raw !== 'string' || !ACT_RE.test(raw)) return { ok: false, act: null };
  return { ok: true, act: ACTUATOR_TYPES.includes(raw) ? raw : 'generic' };
}

/** Role satirlarindan imza dizisi: act YOKSA eski bicim [id,type,name] (v:2 imzasi birebir korunur). */
function relaySigRow(r) {
  return r.act ? [r.id, r.type, r.name, r.act] : [r.id, r.type, r.name];
}

// Bulut tohum sablonu: device_service.js SEED_ENDPOINTS_SQL ile BIREBIR ayni olmalidir (test bunu denetler).
// Sahip karari (2026-10-09): HICBIR rolenin sabit gorevi yok -> 1-8 "Röle N" lamba, oda Genel (firmware v1.3.2 fabrika
// varsayilaniyla ayni). Panjur yalniz servisin sablonundan / panonun gercek yerlesiminden gelir.
const SEED_TABLE = Object.freeze([
  null,
  ...[1, 2, 3, 4, 5, 6, 7, 8].map((n) => Object.freeze({ name: `Röle ${n}`, type: 'light', room: DEFAULT_ROOM })),
]);

// 2026-10-09 oncesi bulut tohumu (1-2 Salon / 3-4 Oda panjuru, 5-8 aydinlatma). Mevcut evlerde bu adlar ve odalar duruyor:
// "otomatik ad / oda" sayilmaya devam eder, panonun yerlesimi gelince ustune yazilabilir.
const LEGACY_SEED_TABLE = Object.freeze([
  null,
  Object.freeze({ name: 'Salon Panjur Yukarı', type: 'shutter', room: 'Salon' }),
  Object.freeze({ name: 'Salon Panjur Aşağı', type: 'shutter', room: 'Salon' }),
  Object.freeze({ name: 'Oda Panjur Yukarı', type: 'shutter', room: 'Oda' }),
  Object.freeze({ name: 'Oda Panjur Aşağı', type: 'shutter', room: 'Oda' }),
  Object.freeze({ name: 'Salon Aydınlatma', type: 'light', room: 'Salon' }),
  Object.freeze({ name: 'Mutfak Aydınlatma', type: 'light', room: 'Mutfak' }),
  Object.freeze({ name: 'Koridor Aydınlatma', type: 'light', room: 'Koridor' }),
  Object.freeze({ name: 'Balkon Aydınlatma', type: 'light', room: 'Balkon' }),
]);

/** Kanalin eski tohum kaydi (1-8), yoksa null. */
function legacySeed(channel) {
  const c = Number(channel);
  return Number.isInteger(c) && c >= 1 && c <= 8 ? LEGACY_SEED_TABLE[c] : null;
}

// Panonun fabrika varsayilan adlari.
//  * v1.3.2+ (sahip karari 2026-10-09: HICBIR rolenin sabit rolu yok): 1-8 "Röle N", hepsi lamba (genel ac-kapa);
//    firmware SystemConfig.h applyFactoryRelayDefaults. Panjur yalniz servisin yazdigi sablon/yapilandirmadan gelir.
//  * v1.3.1 ve oncesi (sahada hala var): 1-2 Salon / 3-4 Oda panjuru, 5-8 aydinlatma (ASCII). Bu adlar da "varsayilan ad" sayilir.
// 9+ (ek modul) her iki surumde "Ek Modül Röle N".
const LEGACY_FIRMWARE_DEFAULT_NAMES = Object.freeze([
  null,
  'Salon Panjur (Yukari)',
  'Salon Panjur (Asagi)',
  'Oda Panjur (Yukari)',
  'Oda Panjur (Asagi)',
  'Salon Aydinlatma',
  'Mutfak Aydinlatma',
  'Koridor Aydinlatma',
  'Balkon Aydinlatma',
]);

// Addan oda turetme: Flutter lib/ui/dashboard/labels.dart `_knownRooms` ile ayni kume (+ tohumdaki "Oda").
// [katlanmis anahtar, okunur ad]; en uzun anahtar once denenir ("yatak odasi", "oda"dan once).
const KNOWN_ROOMS = Object.freeze(
  [
    ['yatak odasi', 'Yatak Odası'],
    ['cocuk odasi', 'Çocuk Odası'],
    ['misafir odasi', 'Misafir Odası'],
    ['oturma odasi', 'Oturma Odası'],
    ['yemek odasi', 'Yemek Odası'],
    ['calisma odasi', 'Çalışma Odası'],
    ['salon', 'Salon'],
    ['mutfak', 'Mutfak'],
    ['antre', 'Antre'],
    ['giris', 'Giriş'],
    ['hol', 'Hol'],
    ['koridor', 'Koridor'],
    ['balkon', 'Balkon'],
    ['teras', 'Teras'],
    ['banyo', 'Banyo'],
    ['wc', 'WC'],
    ['tuvalet', 'Tuvalet'],
    ['bahce', 'Bahçe'],
    ['garaj', 'Garaj'],
    ['depo', 'Depo'],
    ['kiler', 'Kiler'],
    ['cati', 'Çatı'],
    ['ofis', 'Ofis'],
    ['oda', 'Oda'],
  ]
    .slice()
    .sort((a, b) => b[0].length - a[0].length)
    .map((pair) => Object.freeze(pair))
);

// Panjur role adlarinin yon eki: "X (Yukari)", "X Aşağı", "X up" ... (Flutter shutterBaseName ile ayni kural).
const DIRECTION_SUFFIX_RE = /\s*\(?\s*(yukar[ıi]|a[sş]a[gğ][ıi]|up|down)\s*\)?\s*$/iu;

// D9: ada girmeyecek karakterler Unicode KATEGORISIYLE belirlenir: Cc (kontrol), Cf (yon degistiriciler, bidi
// yalitimlari, sifir genislik, yumusak tire, BOM, etiket karakterleri), Zl/Zp (satir/paragraf ayirici), Cs (yalniz
// eslesmemis vekiller; gecerli vekil cifti tek kod noktasi olarak gelir ve Cs DEGILDIR). Hangul dolgulari gorunmez
// ama harf sayilir: ayrica listelenir. Sonuc iyi bicimli UTF-16'dir (jsonb yaziminda 22P02 olmaz).
const UNSAFE_CATEGORY_RE = /^[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}]$/u;
const HANGUL_FILLERS = Object.freeze([0x115f, 0x1160, 0x3164, 0xffa0]);

function isUnsafeChar(ch) {
  return UNSAFE_CATEGORY_RE.test(ch) || HANGUL_FILLERS.includes(ch.codePointAt(0));
}

// ------------------------------------------------------------------------------
// Metin yardimcilari
// ------------------------------------------------------------------------------

/**
 * Karsilastirma anahtari: kucuk harf, aksansiz (Turkce dahil), Unicode harf/rakam (\p{L}\p{N}) disi her sey tek
 * bosluk. "Salon Panjur (Yukari)" ve "Salon Panjur Yukarı" ayni anahtara duser; Kiril/Arap/CJK harfler KORUNUR
 * (D8: onceden bu adlar bos anahtara dusup "varsayilan" sayiliyordu).
 */
function foldName(value) {
  let s = String(value === null || value === undefined ? '' : value);
  s = s.replace(/[İI]/g, 'i').toLowerCase();
  s = s
    .replace(/ı/g, 'i')
    .replace(/ş/g, 's')
    .replace(/ğ/g, 'g')
    .replace(/ü/g, 'u')
    .replace(/ö/g, 'o')
    .replace(/ç/g, 'c');
  // NFKD ile ayrisan birlestirici isaretleri (U+0300..U+036F) at
  s = Array.from(s.normalize('NFKD'))
    .filter((ch) => {
      const cp = ch.codePointAt(0);
      return cp < 0x300 || cp > 0x36f;
    })
    .join('');
  return s.replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

/** Ad bos mu? Yalniz TEMIZLENMIS HAM ad bossa (D8: yalniz emoji/noktalamadan olusan ad bos DEGILDIR). */
function isBlankName(value) {
  return sanitizeReportedName(typeof value === 'string' ? value : '') === '';
}

/** Panodan gelen adi guvenli/duzgun hale getirir; gecersizse bos dizge. En cok NAME_MAX karakter. */
function sanitizeReportedName(raw) {
  if (typeof raw !== 'string') return '';
  let s = '';
  for (const ch of raw) s += isUnsafeChar(ch) ? ' ' : ch; // for..of eslesmemis vekili tek "karakter" verir
  s = s.replace(/\s+/g, ' ').trim();
  const chars = Array.from(s); // kod noktasi bazinda kes (vekil ciftleri bolme)
  if (chars.length > NAME_MAX) s = chars.slice(0, NAME_MAX).join('').trim();
  return s;
}

/** 'shutter' | 'relay' (panonun shutter_up/shutter_down'u ve bulutun shutter'i ayni siniftir). */
function classOf(type) {
  return type === 'shutter' || type === 'shutter_up' || type === 'shutter_down' ? 'shutter' : 'relay';
}

// ------------------------------------------------------------------------------
// Varsayilanlar
// ------------------------------------------------------------------------------

/** Bulut tohum sablonu (SEED_ENDPOINTS_SQL'in JS karsiligi). */
function seedDefaults(channel) {
  const c = Number(channel);
  if (Number.isInteger(c) && c >= 1 && c <= 8) {
    const s = SEED_TABLE[c];
    const shutter = s.type === 'shutter';
    return {
      name: s.name,
      type: s.type,
      room: s.room,
      pair: shutter ? Math.ceil(c / 2) : null,
      durationSec: shutter ? DEFAULT_SHUTTER_SEC : null,
    };
  }
  return { name: `Ek Modül Röle ${c - 8}`, type: 'light', room: DEFAULT_ROOM, pair: null, durationSec: null };
}

/** Panonun (v1.3.2+) fabrika varsayilan adi: 1-8 "Röle N", 9+ "Ek Modül Röle N". */
function firmwareDefaultName(channel) {
  const c = Number(channel);
  if (Number.isInteger(c) && c >= 1 && c <= 8) return `Röle ${c}`;
  return `Ek Modül Röle ${c - 8}`;
}

/** v1.3.1 ve oncesi panonun fabrika adi (1-4 Salon/Oda panjuru, 5-8 aydinlatma); 9+ yeni surumle ayni. */
function legacyFirmwareDefaultName(channel) {
  const c = Number(channel);
  if (Number.isInteger(c) && c >= 1 && c <= 8) return LEGACY_FIRMWARE_DEFAULT_NAMES[c];
  return firmwareDefaultName(c);
}

/** Sinifi tohumdan farkli kanal icin tarafsiz ad: "Panjur 3 Yukarı" / "Röle 2". */
function genericName(channel, reportedType) {
  const c = Number(channel);
  if (classOf(reportedType) === 'shutter') return `Panjur ${Math.ceil(c / 2)} ${c % 2 === 1 ? 'Yukarı' : 'Aşağı'}`;
  return `Röle ${c}`;
}

/**
 * Pano ad vermemisse (fabrika adi) bulutta kullanilacak ad. Eski surum pano (v1.3.1-) kendi eski fabrika adini (ya da eski
 * tohum adini) bildiriyorsa eski tohum adi kullanilir (mevcut evlerde adlar degismesin); aksi halde guncel tohum / genel ad.
 */
function defaultNameFor(channel, reportedType, reportedName) {
  const legacy = legacySeed(channel);
  if (legacy !== null && classOf(legacy.type) === classOf(reportedType) && typeof reportedName === 'string') {
    const f = foldName(reportedName);
    if (f === foldName(legacyFirmwareDefaultName(channel)) || f === foldName(legacy.name)) return legacy.name;
  }
  const seed = seedDefaults(channel);
  return classOf(seed.type) === classOf(reportedType) ? seed.name : genericName(channel, reportedType);
}

/** Panodaki ad "servis sorumlusu ad vermedi" anlamina mi geliyor? (bos / fabrika adi / tohum adi) */
function isBoardDefaultName(channel, name) {
  if (isBlankName(name)) return true;
  const f = foldName(name);
  const legacy = legacySeed(channel);
  return (
    f === foldName(firmwareDefaultName(channel)) ||
    f === foldName(legacyFirmwareDefaultName(channel)) ||
    f === foldName(seedDefaults(channel).name) ||
    (legacy !== null && f === foldName(legacy.name))
  );
}

/** Buluttaki ad otomatik (kullanicinin vermedigi) bir ad mi? */
function isCloudAutoName(channel, name) {
  if (isBlankName(name)) return true;
  const f = foldName(name);
  const legacy = legacySeed(channel);
  return (
    f === foldName(seedDefaults(channel).name) ||
    (legacy !== null && f === foldName(legacy.name)) ||
    f === foldName(firmwareDefaultName(channel)) ||
    f === foldName(legacyFirmwareDefaultName(channel)) ||
    f === foldName(genericName(channel, 'light')) ||
    f === foldName(genericName(channel, 'shutter_up'))
  );
}

// ------------------------------------------------------------------------------
// Oda turetme
// ------------------------------------------------------------------------------

/** Adin basindaki bilinen oda adini dondurur ("Yatak Odası Panjur (Yukari)" -> "Yatak Odası"); yoksa null. */
function deriveRoom(name) {
  const base = sanitizeReportedName(typeof name === 'string' ? name : '').replace(DIRECTION_SUFFIX_RE, '');
  const f = foldName(base);
  if (f === '') return null;
  for (const [key, label] of KNOWN_ROOMS) {
    if (f === key || f.startsWith(`${key} `)) return label;
  }
  return null;
}

/** Bir ad icin otomatik oda: tohum adiysa tohum odasi, degilse addan turetilen oda, o da yoksa "Genel". */
function autoRoomFor(channel, name, reportedType) {
  const legacy = legacySeed(channel);
  if (legacy !== null && classOf(legacy.type) === classOf(reportedType) && foldName(name) === foldName(legacy.name)) {
    return legacy.room;
  }
  const seed = seedDefaults(channel);
  if (classOf(seed.type) === classOf(reportedType) && foldName(name) === foldName(seed.name)) return seed.room;
  return deriveRoom(name) || DEFAULT_ROOM;
}

/** Satirdaki oda otomatik bir deger mi? (bos / "Genel" / tohum odasi / eski addan turetilmis oda) */
function isAutoRoom(channel, room, previousName) {
  if (isBlankName(room)) return true; // D8 ile ayni kural: yalniz simgeden olusan kullanici odasi otomatik DEGIL
  const k = foldName(room);
  if (k === foldName(DEFAULT_ROOM)) return true;
  if (k === foldName(seedDefaults(channel).room)) return true;
  const legacy = legacySeed(channel);
  if (legacy !== null && k === foldName(legacy.room)) return true;
  const derived = deriveRoom(previousName);
  return derived !== null && k === foldName(derived);
}

// ------------------------------------------------------------------------------
// state -> bildirilen yerlesim
// ------------------------------------------------------------------------------

/**
 * Ham `state` nesnesinden (JSON.parse sonucu) yerlesimi cikarir. KATI dogrulama: en kucuk suphede `null`
 * doner ve esitleme o mesaj icin HIC calismaz (kismi/bozuk yukle satir degistirilmez).
 *
 * Gecerlilik: v >= 2; relays = 1..N (N <= 40) bosluksuz ve yinelemesiz; her rolede bilinen `type` ve boolean
 * `state`; panjur ciftleri (2p-1 = shutter_up, 2p = shutter_down) tam; `shutters[]` icindeki cift kumesi
 * tiplerden cikan cift kumesiyle AYNI (pano yalniz gecerli ciftleri bildirir).
 *
 * @returns {null | {count:number, relays:Array<{id:number,type:string,name:string,state:boolean}>,
 *                   pairs:number[], shutterPos:Object<number,number>, signature:string}}
 */
function extractReportedLayout(obj) {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) return null;
  if (!Number.isInteger(obj.v) || obj.v < MIN_STATE_VERSION) return null;
  if (!Array.isArray(obj.relays) || !Array.isArray(obj.shutters)) return null;

  const n = obj.relays.length;
  if (n < 1 || n > MAX_CHANNELS) return null;

  const relays = new Array(n).fill(null);
  for (let i = 0; i < n; i += 1) {
    const r = obj.relays[i];
    if (r === null || typeof r !== 'object' || Array.isArray(r)) return null;
    if (!Number.isInteger(r.id) || r.id < 1 || r.id > n) return null;
    if (relays[r.id - 1] !== null) return null; // yinelenen id
    if (r.id !== i + 1) return null; // D15: pano 1..N sirasiyla yayinlar; sira disi yuk supheli
    if (typeof r.type !== 'string' || !RELAY_TYPES.includes(r.type)) return null;
    if (typeof r.state !== 'boolean') return null;
    if (r.name !== undefined && typeof r.name !== 'string') return null; // D15: null dahil dizge olmayan ad -> null
    const act = readAct(r.act); // v:3 eylemci rolu [Y2]
    if (!act.ok) return null;
    relays[r.id - 1] = { id: r.id, type: r.type, name: sanitizeReportedName(r.name), state: r.state };
    if (act.act) relays[r.id - 1].act = act.act; // v:2'de anahtar HIC yok: role nesnesi eskisiyle ayni
  }

  const pairs = [];
  for (let p = 1; p <= Math.floor(n / 2); p += 1) {
    const up = relays[2 * p - 2].type;
    const down = relays[2 * p - 1].type;
    if (up === 'shutter_down' || down === 'shutter_up') return null; // ters/yetim
    const isUp = up === 'shutter_up';
    const isDown = down === 'shutter_down';
    if (isUp !== isDown) return null; // yetim panjur rolesi
    if (isUp) pairs.push(p);
  }
  if (n % 2 === 1 && classOf(relays[n - 1].type) === 'shutter') return null; // eslesmemis son role

  const shutterPos = {};
  const seen = new Set();
  for (const s of obj.shutters) {
    if (s === null || typeof s !== 'object' || Array.isArray(s)) return null;
    if (!Number.isInteger(s.pair) || seen.has(s.pair)) return null;
    seen.add(s.pair);
    if (Number.isInteger(s.pos) && s.pos >= 0 && s.pos <= 100) shutterPos[s.pair] = s.pos;
  }
  if (seen.size !== pairs.length || !pairs.every((p) => seen.has(p))) return null; // tutarsiz anlik goruntu

  const signature = JSON.stringify(relays.map(relaySigRow));
  return { count: n, relays, pairs, shutterPos, signature };
}

// ------------------------------------------------------------------------------
// Taban (devices.reported_layout): bu panonun EN SON uygulanan bildirimi
// ------------------------------------------------------------------------------

function serializeBase(reported) {
  return {
    v: BASE_VERSION,
    relays: reported.relays.map((r) => (r.act ? { id: r.id, type: r.type, name: r.name, act: r.act } : { id: r.id, type: r.type, name: r.name })),
  };
}

/** Veritabanindan gelen JSONB'yi (nesne ya da dizge) dogrular; bozuksa null (= "bu panoyla hic esitlenmedi"). */
function parseBase(raw) {
  let v = raw;
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v);
    } catch (_) {
      return null;
    }
  }
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return null;
  if (v.v !== BASE_VERSION || !Array.isArray(v.relays)) return null;
  const relays = [];
  for (const r of v.relays) {
    if (r === null || typeof r !== 'object') return null;
    if (!Number.isInteger(r.id) || r.id < 1 || r.id > MAX_CHANNELS) return null;
    if (typeof r.type !== 'string' || typeof r.name !== 'string') return null;
    if (r.act !== undefined && (typeof r.act !== 'string' || !ACTUATOR_TYPES.includes(r.act))) return null;
    relays.push(r.act ? { id: r.id, type: r.type, name: r.name, act: r.act } : { id: r.id, type: r.type, name: r.name });
  }
  return { v: BASE_VERSION, relays };
}

function sameBase(a, b) {
  if (!a || !b) return false;
  return JSON.stringify(a.relays.map(relaySigRow)) === JSON.stringify(b.relays.map(relaySigRow));
}

/** Bildirimde ya da tabanda eylemci var mi? (Eylemci esitleme sorgusu yalniz o zaman calisir: v:2 yolu aynen.) */
function hasActuators(layoutOrBase) {
  return Boolean(layoutOrBase && Array.isArray(layoutOrBase.relays) && layoutOrBase.relays.some((r) => r && r.act));
}

/** Kanal -> act (yoksa null) listesi: endpoints.actuator_type toplu esitlemesi icin [kanallar], [act|null]. */
function actuatorVector(reported) {
  const channels = [];
  const acts = [];
  for (const r of reported.relays) {
    channels.push(r.id);
    acts.push(r.act || null);
  }
  return { channels, acts };
}

// Panonun fabrika tipleri: v1.3.2+ hepsi lamba (sabit rol yok); v1.3.1 ve oncesi 1-2 ve 3-4 panjur cifti, 5-8 lamba.
const FACTORY_TYPES = Object.freeze(new Array(8).fill('light'));
const LEGACY_FACTORY_TYPES = Object.freeze(['shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light', 'light', 'light']);

/**
 * D1: bildirim panonun TAM fabrika yerlesimi mi? Tam 8 role; tipler fabrika tipleri; her ad varsayilan
 * (isBoardDefaultName: fabrika adi, tohum adi ya da bos). Yeni/sifirlanmis pano henuz yapilandirilmadan boyle baglanir.
 */
function isFactoryLayout(reported) {
  if (!reported || !Array.isArray(reported.relays) || reported.count !== FACTORY_TYPES.length) return false;
  if (reported.relays.length !== FACTORY_TYPES.length) return false;
  // Eylemci tasiyan pano kurulumcu tarafindan yapilandirilmistir: GECICI (D1) degildir; eylemci atamasi ertelenmez.
  if (hasActuators(reported)) return false;
  // Fabrika tip vektorlerinden BIRI (v1.3.2+ ya da eski surum) tum kanallarda tutmali; adlar varsayilan olmali.
  return [FACTORY_TYPES, LEGACY_FACTORY_TYPES].some((types) =>
    reported.relays.every((r, i) => r && r.id === i + 1 && r.type === types[i] && isBoardDefaultName(r.id, r.name))
  );
}

// ------------------------------------------------------------------------------
// Plan
// ------------------------------------------------------------------------------

function cloudTypeFor(reportedType, row) {
  if (classOf(reportedType) === 'shutter') return 'shutter';
  if (reportedType === 'impulse') return 'impulse';
  return row && row.type === 'plug' ? 'plug' : 'light';
}

/**
 * Bildirilen yerlesim + taban + mevcut satirlardan yapilacak isleri hesaplar (SAF).
 *
 * @param {object} p
 * @param {object} p.reported          extractReportedLayout sonucu
 * @param {object|null} [p.base]       parseBase(devices.reported_layout); null = bu panoyla ilk esitleme
 * @param {Array<object>} [p.rows]     cihazin endpoints satirlari: { id, channel_index, name, type, room,
 *                                     shutter_pair_index, shutter_duration_sec }
 * @param {boolean} [p.confirmShrink]  true: N'den buyuk kanalli satirlar silinir
 * @param {boolean} [p.provisional]    D1 GECICI mod (servis verir: cihaz devreye alinmamis + taban bos + bildirim
 *                                     isFactoryLayout). Yalniz guvenlik/ekleme adimlari uygulanir: role -> panjur
 *                                     sinif degisimi (+ kural kapatma), lamba/priz <-> darbe (+ kural kapatma),
 *                                     eksik satir ekleme. ERTELENIR: panjur -> role, satir silme (kuculme kaydi da
 *                                     tutulmaz), ad/oda degisiklikleri, taban yazimi. Ertelenecek bir sey yoksa plan
 *                                     normal planla BIREBIRDIR.
 * @returns {{inserts:Array, updates:Array, deletes:Array, deleteAbove:number|null, pendingShrink:boolean,
 *            ruleRelayChannels:number[], ruleShutterPairs:number[], newBase:object|null, baseChanged:boolean,
 *            changed:boolean, deferred:number, summary:object}}
 *            deferred > 0 iken newBase null ve baseChanged false (taban YAZILMAZ).
 */
function planLayoutSync({ reported, base = null, rows = [], confirmShrink = false, provisional = false }) {
  if (provisional) {
    const held = planCore({ reported, base, rows, confirmShrink, provisional: true });
    if (held.deferred > 0) return held;
  }
  return planCore({ reported, base, rows, confirmShrink, provisional: false });
}

function planCore({ reported, base, rows, confirmShrink, provisional }) {
  const n = reported.count;
  const baseById = new Map();
  if (base && Array.isArray(base.relays)) for (const b of base.relays) baseById.set(b.id, b);
  const rowByChannel = new Map();
  for (const row of rows) rowByChannel.set(Number(row.channel_index), row);

  const inserts = [];
  const updates = [];
  const deletes = [];
  const ruleRelayChannels = new Set();
  const ruleShutterPairs = new Set();
  const summary = { inserted: 0, retyped: 0, renamed: 0, reroomed: 0, deleted: 0 };
  let deferred = 0;

  for (const r of reported.relays) {
    const c = r.id;
    const row = rowByChannel.get(c) || null;
    const cls = classOf(r.type);
    const pair = cls === 'shutter' ? Math.ceil(c / 2) : null;
    const custom = !isBoardDefaultName(c, r.name);
    const position = cls === 'shutter' && Number.isInteger(reported.shutterPos[pair]) ? reported.shutterPos[pair] : 0;

    if (!row) {
      const name = custom ? r.name : defaultNameFor(c, r.type, r.name);
      inserts.push({
        channel_index: c,
        name,
        type: cloudTypeFor(r.type, null),
        room: autoRoomFor(c, name, r.type),
        shutter_pair_index: pair,
        shutter_duration_sec: cls === 'shutter' ? DEFAULT_SHUTTER_SEC : null,
        current_state: r.state,
        current_position: position,
      });
      summary.inserted += 1;
      continue;
    }

    const classChanged = classOf(row.type) !== cls;
    if (provisional && classChanged && cls === 'relay') {
      // D1: panjurdan roleye donus ertelenir (pano panjur rolesine gelen komutu `pairConfigured` ile zaten reddeder)
      deferred += 1;
      continue;
    }
    const type = cloudTypeFor(r.type, row);

    // --- ad ---
    let name = row.name;
    if (classChanged) {
      name = custom ? r.name : defaultNameFor(c, r.type, r.name);
    } else {
      const b = baseById.get(c);
      const prev = b && typeof b.name === 'string' ? b.name : undefined;
      if (custom) {
        if (prev !== undefined && prev !== r.name) name = r.name; // pano tarafinda ad degisti: son yazan kazanir
        else if (isCloudAutoName(c, row.name)) name = r.name; // bulut adi otomatik: pano adini al
      } else if (prev !== undefined && prev !== r.name && !isBoardDefaultName(c, prev) && row.name === prev) {
        name = defaultNameFor(c, r.type, r.name); // pano adi varsayilana dondu ve bulut eski pano adini gosteriyordu
      }
    }

    // --- oda ---
    let room = row.room;
    if (classChanged || (name !== row.name && isAutoRoom(c, row.room, row.name))) {
      room = autoRoomFor(c, name, r.type);
    }

    if (provisional) {
      // D1: ad ve oda (varsayilana donus dahil) ertelenir; kullanicinin verisi oldugu gibi kalir
      if (name !== row.name) {
        deferred += 1;
        name = row.name;
      }
      if (room !== row.room) {
        deferred += 1;
        room = row.room;
      }
    }

    const set = {};
    if (type !== row.type) {
      set.type = type;
      summary.retyped += 1;
    }
    if (name !== row.name) {
      set.name = name;
      summary.renamed += 1;
    }
    if (room !== row.room) {
      set.room = room;
      summary.reroomed += 1;
    }

    if (cls === 'shutter') {
      if (row.shutter_pair_index !== pair) set.shutter_pair_index = pair;
      const cur = row.shutter_duration_sec;
      const keep = !classChanged && Number.isInteger(cur) && cur >= 1;
      if (!keep) set.shutter_duration_sec = DEFAULT_SHUTTER_SEC;
      if (classChanged) {
        set.current_position = position;
        ruleRelayChannels.add(c); // role kurali artik panjur motorunu surerdi
      }
    } else if (classChanged) {
      set.shutter_pair_index = null;
      set.shutter_duration_sec = null;
      set.current_position = 0;
      // Panjur kurali panonun cift numarasiyla (kanal 2p-1 / 2p) adreslenir; satirdaki shutter_pair_index'e bakmaz
      // (scheduled_rules_service checkChannelAgainstEndpoints). Bu yuzden KANALDAN turetilir.
      ruleShutterPairs.add(Math.ceil(c / 2));
    } else if (type !== row.type && (type === 'impulse' || row.type === 'impulse')) {
      // D2: role sinifi icinde darbe <-> lamba/priz degisimi davranisi degistirir ("lambayi ac" kurali kapi/kilit
      // darbesini tetiklerdi). light <-> plug kozmetiktir: kapatma yok.
      ruleRelayChannels.add(c);
    }

    if (Object.keys(set).length > 0) updates.push({ id: row.id, channel_index: c, set });
  }

  // --- pano artik bildirmedigi kanallar (ek modul kuculdu/kapandi) ---
  let pendingShrink = false;
  const stale = rows.filter((row) => Number(row.channel_index) > n);
  if (stale.length > 0) {
    if (provisional) {
      deferred += stale.length; // D1: silme ertelenir, kuculme kaydi da tutulmaz (pendingShrink false)
    } else if (confirmShrink) {
      for (const row of stale) {
        const c = Number(row.channel_index);
        deletes.push({ id: row.id, channel_index: c });
        if (classOf(row.type) === 'shutter') {
          ruleShutterPairs.add(Math.ceil(c / 2)); // kanaldan (yukaridaki gerekce)
        } else {
          ruleRelayChannels.add(c);
        }
      }
      summary.deleted = deletes.length;
    } else {
      pendingShrink = true;
    }
  }

  // D1: ertelenen bir sey varsa taban YAZILMAZ (sonraki bildirimler de gecici modda kalir)
  const newBase = deferred > 0 ? null : serializeBase(reported);
  const baseChanged = newBase !== null && !sameBase(base, newBase);
  const changed = inserts.length > 0 || updates.length > 0 || deletes.length > 0;

  return {
    inserts,
    updates,
    deletes,
    deleteAbove: deletes.length > 0 ? n : null,
    pendingShrink,
    ruleRelayChannels: [...ruleRelayChannels].sort((a, b) => a - b),
    ruleShutterPairs: [...ruleShutterPairs].sort((a, b) => a - b),
    newBase,
    baseChanged,
    changed,
    deferred,
    summary,
  };
}

module.exports = {
  MAX_CHANNELS,
  NAME_MAX,
  DEFAULT_ROOM,
  DEFAULT_SHUTTER_SEC,
  BASE_VERSION,
  MIN_STATE_VERSION,
  RELAY_TYPES,
  ACTUATOR_TYPES,
  readAct,
  hasActuators,
  actuatorVector,
  foldName,
  sanitizeReportedName,
  classOf,
  seedDefaults,
  firmwareDefaultName,
  legacyFirmwareDefaultName,
  genericName,
  defaultNameFor,
  isBoardDefaultName,
  isCloudAutoName,
  deriveRoom,
  autoRoomFor,
  isAutoRoom,
  extractReportedLayout,
  serializeBase,
  parseBase,
  sameBase,
  isFactoryLayout,
  planLayoutSync,
};
