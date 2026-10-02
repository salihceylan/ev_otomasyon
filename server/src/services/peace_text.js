'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Gece huzur hatırlatması: bildirim METNİ üretici     [WP-H §3.1]
// ==============================================================================
//
// Kullanım (peace_reminder.js):
//   const { buildTitle, buildSummary } = require('./services/peace_text');
//   buildTitle('Gül Apartmanı 5')                                   -> 'Gül Apartmanı 5'
//   buildSummary({ lights: [{ room: 'Salon' }, { room: 'Salon' }, { room: 'Mutfak' }],
//                  shutters: [{ room: 'Salon' }] })
//                                  -> 'Salonda 2, Mutfakta 1 lamba, 1 panjur açık.'
//
// Neden ayrı ve saf bir modül?
//   - Türkçe bildirim cümlesi EK uyumu ister (ünlü uyumu, sert ünsüz, iyelik). Bu mantık
//     veritabanı/ağ koduyla karışırsa sınanamaz. Burada bağımlılık, saat, global durum ve
//     G/Ç YOKTUR: aynı girdi hep aynı metni verir ve HİÇBİR girdi istisna fırlatmaz (kötü veri
//     sessizce yok sayılır; bildirim zinciri metin yüzünden kırılmasın).
//   - Metin push gövdesine gider. Diğer API iletilerinin aksine ASCII'ye ÇEVRİLMEZ: ç ğ ı ö ş ü İ
//     korunur (be-night.txt "DELIVERY").
//
// Bulunma eki kuralları (SON KELİMENİN SON ÜNLÜSÜNE göre):
//   - kalın ünlü (a ı o u) -> -da / -ta;  ince ünlü (e i ö ü) -> -de / -te
//   - sert ünsüzle (ç f h k p s ş t) biten kelime -> -ta / -te        ("Mutfak" -> "Mutfakta")
//   - iyelikle (-sı -si -su -sü) biten ad -> -nda / -nde             ("Yatak Odası" -> "Yatak Odasında")
//     Yalnız bu dar kural uygulanır: "Pasi" gibi belirsiz yazımlarda iyelik VARSAYILIR; "Çatı Katı"
//     gibi ünsüzden sonra gelen iyelikler (-ı/-i/-u/-ü) güvenle ayırt edilemediği için taranmaz
//     ("Ana Kapı" gibi düz adları bozmamak için; kesinlik > kapsam).
//   - oda yok / boş / "Genel" -> "Evde"
//   Büyük/küçük harf çevrimi hep Türkçe kurallarıyla yapılır: "KAPI" -> "kapı" (I -> ı),
//   "KİLER" -> "kiler" (İ -> i). Düz toLowerCase() "KAPI"yı "kapi" yapıp "-de" seçtirirdi.
//
// Cümle şablonları (tam sayılar, çoğul eki YOK):
//   1 oda            "Salonda 2 lamba açık."
//   2-3 oda          "Salonda 2, Mutfakta 1 lamba açık."
//   4+ oda           "4 odada 7 lamba açık."
//   lamba + panjur   "Salonda 2 lamba, 1 panjur açık."
//   yalnız panjur    "1 panjur açık."
//   Odalar lamba sayısına göre AZALAN, eşitse ada göre (Türkçe sıralama) dizilir.
//   Panjurlar için oda adı söylenmez (şartname).

const DEFAULT_ROOM = 'Genel'; // endpoints.room varsayılanı (migration 001)
const HOME_LOCATIVE = 'Evde'; // oda bilinmiyorsa: "Evde 2 lamba açık."
const DEFAULT_TITLE = 'Evim';
const MAX_TITLE_LENGTH = 60; // bildirim başlığı satırı; şartname §3.1
const MAX_ROOM_LENGTH = 50; // endpoints.room VARCHAR(50): geçerli veri asla kırpılmaz, bozuk veri payloadu şişirmez
const MAX_LISTED_ROOMS = 3; // 2-3 oda adıyla sayılır; 4+ oda "N odada M lamba"ya özetlenir
const MAX_COUNT = 9999; // makul üst sınır ("1e+21" gibi üstel gösterim metne sızmasın)

const BACK = 'back';
const FRONT = 'front';
const BACK_VOWELS = new Set(['a', 'ı', 'o', 'u', 'â', 'û']);
const FRONT_VOWELS = new Set(['e', 'i', 'ö', 'ü', 'î']);
// "fıstıkçı şahap" sert ünsüzleri. x ("ks") ve q ("k") yabancı harfleri de sert sesle biter.
const VOICELESS_CONSONANTS = new Set(['ç', 'f', 'h', 'k', 'p', 's', 'ş', 't', 'x', 'q']);
// Son ünlüsü kalın olduğu hâlde ince ek alan (yumuşak "l"li) yaygın oda adı: "holde".
const SOFT_L_WORDS = new Set(['hol']);

// Rakamla biten adlarda ek, sayının OKUNUŞUNUN son hecesine uyar ("Oda 3" -> "Oda 3'te").
// sıfır, bir, iki, üç, dört, beş, altı, yedi, sekiz, dokuz
const DIGIT_SUFFIX = { 0: 'da', 1: 'de', 2: 'de', 3: 'te', 4: 'te', 5: 'te', 6: 'da', 7: 'de', 8: 'de', 9: 'da' };
// 0 ile biten sayılar onlar basamağına göre okunur:
// on, yirmi, otuz, kırk, elli, altmış, yetmiş, seksen, doksan (100/1000: "yüz"/"bin" -> -de)
const TENS_SUFFIX = { 1: 'da', 2: 'de', 3: 'da', 4: 'ta', 5: 'de', 6: 'ta', 7: 'te', 8: 'de', 9: 'da' };

// Kilit ekranında metni yanıltabilen/gösterilmeyen karakterler (yumuşak tire, sıfır genişlikli
// boşluk, yön işaretleri). ZWJ/ZWNJ bilerek KORUNUR: emoji dizilerini (ev adındaki 👨‍👩‍👧) bozmasın.
const HIDDEN_FORMAT_CHARS = /[\u00AD\u061C\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]/g;
const CONTROL_OR_SPACE_RUN = /[\p{Cc}\s]+/gu; // satır sonu/sekme/NBSP dahil her boşluk türü
const TRAILING_NON_ALNUM = /[^\p{L}\p{N}\p{M}]+$/u; // "Salon)" -> "Salon": noktalama ek almaz
const TRAILING_DIGITS = /[0-9]+$/;
const ASCII_DIGIT = /[0-9]/;
const POSSESSIVE_ENDING = /s[ıiuü]$/; // -sı -si -su -sü (küçük harfe çevrilmiş kelimede)

// ------------------------------------------------------------------------------
// Türkçe büyük/küçük harf
// ------------------------------------------------------------------------------
// ICU'suz (intl'siz) Node derlemelerinde toLocaleLowerCase('tr') İ/I'yı yanlış çevirir; modül
// yüklenirken BİR kez sınanır, bozuksa aynı kural elle uygulanır (durumsuz, saf).
const TR_CASING_NATIVE = 'I'.toLocaleLowerCase('tr') === 'ı' && 'İ'.toLocaleLowerCase('tr') === 'i';

function lowerTr(text) {
  return TR_CASING_NATIVE
    ? text.toLocaleLowerCase('tr')
    : text.replace(/İ/g, 'i').replace(/I/g, 'ı').toLowerCase();
}

// ------------------------------------------------------------------------------
// Metin temizliği
// ------------------------------------------------------------------------------

/**
 * Oda/ev adını güvenle gösterilebilir hâle getirir: NFC (ayrışık "u"+"¨" -> "ü", yoksa ünlü
 * tespiti şaşar), gizli biçim karakterleri silinir, her boşluk/denetim karakteri dizisi tek
 * boşluk olur, kırpılır, `maxLength` KARAKTERE (kod noktası) kesilir. Harf BÜYÜKLÜĞÜNE dokunulmaz.
 * String değilse '' döner (istisna fırlatmaz).
 */
function cleanText(value, maxLength) {
  if (typeof value !== 'string') return '';
  const text = value
    .normalize('NFC')
    .replace(HIDDEN_FORMAT_CHARS, '')
    .replace(CONTROL_OR_SPACE_RUN, ' ')
    .trim();
  const chars = Array.from(text); // vekil çiftleri (emoji) ortadan bölünmesin
  return chars.length > maxLength ? chars.slice(0, maxLength).join('').trimEnd() : text;
}

/** Boş ya da "Genel" (büyük/küçük harf fark etmez) -> oda belirtilmemiş sayılır. */
function isDefaultRoom(cleanName) {
  return cleanName === '' || lowerTr(cleanName) === 'genel';
}

// ------------------------------------------------------------------------------
// Bulunma eki
// ------------------------------------------------------------------------------

/** Tek karakterin ünlü sınıfı: BACK | FRONT | null (ünlü değil). */
function vowelClass(ch) {
  if (BACK_VOWELS.has(ch)) return BACK;
  if (FRONT_VOWELS.has(ch)) return FRONT;
  // Yabancı aksanlı ünlüler (é, á, ô ...) taban harflerine göre sınıflanır ("Café" -> "Cafede").
  const base = ch.normalize('NFD').charAt(0);
  if (base === ch) return null;
  if (BACK_VOWELS.has(base)) return BACK;
  if (FRONT_VOWELS.has(base)) return FRONT;
  return null;
}

/** Tek harfin (veya kısaltmanın son harfinin) ADIYLA okunuşuna uyan ek: "WC'de", "Blok A'da". */
function letterNameSuffix(ch) {
  const kind = vowelClass(ch);
  if (kind !== null) return kind === FRONT ? 'de' : 'da'; // a, e, ı, i, o, ö, u, ü kendi adlarıdır
  return ch === 'x' ? 'te' : 'de'; // be, ce, de, fe ... hep "e" ile biter; x -> "iks"
}

/** Rakam dizisinin (ör. "10") okunuşuna uyan ek. */
function numberSuffix(digits) {
  const last = digits.charAt(digits.length - 1);
  if (last !== '0') return DIGIT_SUFFIX[last];
  if (digits.length === 1) return DIGIT_SUFFIX[0]; // "sıfır"
  if (digits.endsWith('00')) return 'de'; // "yüz", "bin"
  return TENS_SUFFIX[digits.charAt(digits.length - 2)]; // "on", "yirmi" ...
}

/**
 * Temizlenmiş (boş ve "Genel" olmayan) oda adına gelecek ek.
 * @returns {{suffix: string, apostrophe: boolean}} apostrophe: kesme işareti gerekir
 *          (rakam/kısaltma sonrası: "Oda 3'te", "WC'de"; sözcüklerde yazılmaz).
 */
function locativeEnding(name) {
  // Yalnız SON KELİME incelenir; sondaki noktalama/emoji atılır ("Salon (üst)" -> "(üst").
  const lastWord = name.slice(name.lastIndexOf(' ') + 1);
  const core = lastWord.replace(TRAILING_NON_ALNUM, '');
  if (core === '') return { suffix: 'de', apostrophe: true }; // harf/rakam yok (ör. yalnız emoji)

  const lower = lowerTr(core);
  const chars = Array.from(lower);
  const lastChar = chars[chars.length - 1];

  // 1) Rakamla biten ad: "Oda 3" -> "Oda 3'te"
  if (ASCII_DIGIT.test(lastChar)) {
    return { suffix: numberSuffix(lower.match(TRAILING_DIGITS)[0]), apostrophe: true };
  }

  let lastVowel = null;
  for (let i = chars.length - 1; i >= 0 && lastVowel === null; i--) lastVowel = vowelClass(chars[i]);

  // 2) Tek harf ya da ünlüsüz kısaltma ("Blok A", "WC", "TV"): harf adıyla okunur
  if (chars.length === 1 || lastVowel === null) {
    return { suffix: letterNameSuffix(lastChar), apostrophe: true };
  }

  // 3) İyelik: -sı/-si/-su/-sü ("Yatak Odası" -> "-nda"). Gövdesiz "Su" iyelik DEĞİLDİR ("Suda").
  //    Ek her zaman küçük harfle eklenir ("SALON" -> "SALONda"): adın yazımı olduğu gibi kalır.
  if (chars.length >= 3 && POSSESSIVE_ENDING.test(lower)) {
    return { suffix: vowelClass(lastChar) === BACK ? 'nda' : 'nde', apostrophe: false };
  }

  // 4) Genel kural: SON ünlüye göre -da/-de, sert ünsüzden sonra -ta/-te
  const kind = SOFT_L_WORDS.has(lower) ? FRONT : lastVowel;
  const suffix = (VOICELESS_CONSONANTS.has(lastChar) ? 't' : 'd') + (kind === FRONT ? 'e' : 'a');
  return { suffix, apostrophe: false };
}

/**
 * Oda adını bulunma hâline çevirir.
 *   locative('Salon') -> 'Salonda'; ('Mutfak') -> 'Mutfakta'; ('Antre') -> 'Antrede';
 *   ('Yatak Odası') -> 'Yatak Odasında'; ('') / ('Genel') / (null) -> 'Evde'.
 * Adın harf büyüklüğü olduğu gibi korunur; boşluklar normalleştirilir.
 * @param {*} room  oda adı (string değilse "oda yok" sayılır)
 * @returns {string}
 */
function locative(room) {
  const name = cleanText(room, MAX_ROOM_LENGTH);
  if (isDefaultRoom(name)) return HOME_LOCATIVE;
  const { suffix, apostrophe } = locativeEnding(name);
  return `${name}${apostrophe ? "'" : ''}${suffix}`;
}

// ------------------------------------------------------------------------------
// Özet cümlesi
// ------------------------------------------------------------------------------

/**
 * Bir girdinin kaç adet saydığı. Varsayılan 1; `count` verilmişse pozitif tam sayıya çevrilir
 * (pg sayı metni "2" de kabul), negatif/sıfır/NaN/sayı olmayan -> 0 (yok sayılır).
 * Nesne olmayan girdi (null, sayı, metin) yok sayılır.
 */
function entryCount(entry) {
  if (entry === null || typeof entry !== 'object') return 0;
  let raw = entry.count;
  if (raw === undefined || raw === null) return 1;
  if (typeof raw === 'string' && /^\s*[0-9]{1,15}\s*$/.test(raw)) raw = Number(raw);
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 1) return 0;
  return Math.min(Math.floor(raw), MAX_COUNT);
}

function countEntries(list) {
  if (!Array.isArray(list)) return 0;
  let total = 0;
  for (const entry of list) total += entryCount(entry);
  return total;
}

/** Sayı azalan, eşitse ada göre (Türkçe sıralama: ç c'den sonra, ı i'den ÖNCE; "Oda 2" < "Oda 10"). */
function compareGroups(a, b) {
  if (a.count !== b.count) return b.count - a.count;
  // Anahtarlar benzersizdir (Map), son satır yalnızca sıralamayı her ortamda kesinleştirir.
  return a.key.localeCompare(b.key, 'tr', { numeric: true }) || (a.key < b.key ? -1 : 1);
}

/**
 * Lambaları odaya göre toplar. Aynı odanın yazım türleri ("Salon", "salon", " SALON ") tek
 * oda sayılır (Türkçe küçük harfle karşılaştırılır; ilk görülen yazım gösterilir); boş/"Genel"/
 * string olmayan oda -> "Genel".
 * @returns {Array<{key: string, name: string, count: number}>} sıralı
 */
function groupLightsByRoom(list) {
  if (!Array.isArray(list)) return [];
  const groups = new Map();
  for (const entry of list) {
    const count = entryCount(entry);
    if (count === 0) continue;
    const cleaned = cleanText(entry.room, MAX_ROOM_LENGTH);
    const name = isDefaultRoom(cleaned) ? DEFAULT_ROOM : cleaned;
    const key = lowerTr(name);
    const group = groups.get(key);
    if (group) group.count += count;
    else groups.set(key, { key, name, count });
  }
  return [...groups.values()].sort(compareGroups);
}

function describeLights(groups, total) {
  if (groups.length > MAX_LISTED_ROOMS) return `${groups.length} odada ${total} lamba`;
  const listed = groups.map((group) => `${locative(group.name)} ${group.count}`).join(', ');
  return `${listed} lamba`;
}

/**
 * Açık lamba/panjurları tek Türkçe cümlede özetler; hiçbir şey açık değilse ''.
 *   { lights: [{room}, ...], shutters: [{room}, ...] }
 * Girdiler dizi değilse boş sayılır; her girdi `{ room, count? }` nesnesidir, geçersizler
 * (null, negatif `count` ...) yok sayılır. Girdi DEĞİŞTİRİLMEZ.
 * @returns {string} "Salonda 2, Mutfakta 1 lamba, 1 panjur açık." | ''
 */
function buildSummary(input) {
  const source = input !== null && typeof input === 'object' ? input : {};
  const groups = groupLightsByRoom(source.lights);
  const lightTotal = groups.reduce((sum, group) => sum + group.count, 0);
  const shutterTotal = countEntries(source.shutters);

  const parts = [];
  if (lightTotal > 0) parts.push(describeLights(groups, lightTotal));
  if (shutterTotal > 0) parts.push(`${shutterTotal} panjur`);
  return parts.length === 0 ? '' : `${parts.join(', ')} açık.`;
}

/**
 * Bildirim başlığı = ev adı (boşsa 'Evim'), en çok 60 karakter. Ev adı Türkçe karakterleriyle
 * kalır; fazlası kesilir (üç nokta eklenmez: sonuç tam olarak "en çok 60").
 * @param {*} homeName
 * @returns {string}
 */
function buildTitle(homeName) {
  return cleanText(homeName, MAX_TITLE_LENGTH) || DEFAULT_TITLE;
}

module.exports = {
  DEFAULT_ROOM,
  locative,
  buildSummary,
  buildTitle,
};
