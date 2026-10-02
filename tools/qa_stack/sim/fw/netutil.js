// NetUtil.h'nin (firmware, src/NetUtil.h) JavaScript portu: ag/web katmani ortak yardimcilari.
// C'deki NUL sonlandirmali bayt dizileri burada "ilk NUL'a kadar" JS string'i olarak modellenir; uzunluk kurallari
// (SSID 32 bayt, parola 63 bayt ...) UTF-8 BAYT sayisiyla uygulanir (karakter sayisiyla degil).
//
// ZAMAN KURALI (N6, CONTRACTS 3c): firmware NetUtil.h'den "hedef zaman gecti mi" isaretli karsilastirmasi (timeReached) KALDIRILDI: saklanmis hedef eski
// kalirsa millis() 24,86 gun sonra onu "hala gelecekte" sanir ve zamanlayici donar. Ag katmaninin tum zamanlayicilari "son olay + bekleme" ciftleridir
// (NetUtil::Wait, NetTime.h) -> burada sim/fw/net_time.js. Bu modulde timeReached YOKTUR ve geri eklenmemelidir (test/fw_netutil.test.js bunu denetler).
//
// Dogrulama: test/fw_netutil.test.js (NetUtil.h'nin Unity testi yoktur: Arduino.h'a bagimlidir; ozellikler elle turetilmistir).

export const MIN_VALID_EPOCH = 1700000000;

/** Ilk NUL'a kadar kesilmis bayt dizisi (C string semantigi). */
export function cBytes(s) {
  if (s === null || s === undefined) return Buffer.alloc(0);
  const b = Buffer.isBuffer(s) ? s : Buffer.from(String(s), 'utf8');
  const z = b.indexOf(0);
  return z === -1 ? b : b.subarray(0, z);
}

/** strlen: UTF-8 bayt uzunlugu (ilk NUL'a kadar). */
export const cStrLen = (s) => cBytes(s).length;

/** strncpy(dst, src, cap-1) + NUL: en fazla cap-1 BAYT (karakteri ortadan kesebilir: ham C davranisi). */
export function cCopy(s, cap) {
  const b = cBytes(s);
  const cut = b.length > cap - 1 ? b.subarray(0, cap - 1) : b;
  return cut.toString('utf8');
}

/** Sabit zamanli karsilastirma: ilk farkta cikmaz, uzunluk farkini da sonuca katar; null bos dizge sayilir. */
export function constantTimeEquals(a, b) {
  const ba = cBytes(a);
  const bb = cBytes(b);
  const la = ba.length;
  const lb = bb.length;
  const n = la > lb ? la : lb;
  let diff = la !== lb ? 1 : 0;
  for (let i = 0; i < n; i++) {
    const ca = i < la ? ba[i] : 0;
    const cb = i < lb ? bb[i] : 0;
    diff |= (ca ^ cb) & 0xFF;
  }
  return diff === 0;
}

/** Bir UTF-8 dizisinin (RFC 3629) bas baytindan beklenen toplam uzunlugu; gecersizse 0. */
export function utf8SeqLen(p, off, remaining) {
  const c = p[off];
  if (c < 0x80) return 1;
  if (c >= 0xC2 && c <= 0xDF) {
    if (remaining < 2 || (p[off + 1] & 0xC0) !== 0x80) return 0;
    return 2;
  }
  if (c >= 0xE0 && c <= 0xEF) {
    if (remaining < 3 || (p[off + 1] & 0xC0) !== 0x80 || (p[off + 2] & 0xC0) !== 0x80) return 0;
    if (c === 0xE0 && p[off + 1] < 0xA0) return 0;   // overlong
    if (c === 0xED && p[off + 1] > 0x9F) return 0;   // UTF-16 vekil cifti
    return 3;
  }
  if (c >= 0xF0 && c <= 0xF4) {
    if (remaining < 4 || (p[off + 1] & 0xC0) !== 0x80 || (p[off + 2] & 0xC0) !== 0x80 || (p[off + 3] & 0xC0) !== 0x80) return 0;
    if (c === 0xF0 && p[off + 1] < 0x90) return 0;   // overlong
    if (c === 0xF4 && p[off + 1] > 0x8F) return 0;   // > U+10FFFF
    return 4;
  }
  return 0;
}

/** Gecerli UTF-8 mi ve (allowControl=false iken) kontrol karakteri icermiyor mu? Girdi: Buffer veya string. */
export function isCleanUtf8(input, allowControl = false) {
  const p = Buffer.isBuffer(input) ? input : Buffer.from(String(input), 'utf8');
  let i = 0;
  while (i < p.length) {
    const c = p[i];
    if (!allowControl && (c < 0x20 || c === 0x7F)) return false;
    const n = utf8SeqLen(p, i, p.length - i);
    if (n === 0) return false;
    i += n;
  }
  return true;
}

/** JSON'a basilacak dis kaynakli metni guvenli hale getirir: gecersiz bayt -> U+FFFD, C0/DEL -> bosluk. Girdi: Buffer/string. */
export function sanitizeUtf8(input, maxBytes = 256) {
  if (input === null || input === undefined) return '';
  const all = cBytes(input);
  const p = all.length > maxBytes ? all.subarray(0, maxBytes) : all;
  const out = [];
  let i = 0;
  while (i < p.length) {
    const c = p[i];
    if (c < 0x20 || c === 0x7F) { out.push(Buffer.from(' ')); i++; continue; }
    const n = utf8SeqLen(p, i, p.length - i);
    if (n === 0) { out.push(Buffer.from([0xEF, 0xBF, 0xBD])); i++; continue; }
    out.push(p.subarray(i, i + n));
    i += n;
  }
  return Buffer.concat(out).toString('utf8');
}

/** sanitizeInto: sabit boyutlu (cap) hedef icin: gecersiz bayt -> '?', kontrol -> ' ', karakteri ortadan kesmez. */
export function sanitizeInto(cap, input) {
  if (cap === 0) return '';
  const out = [];
  let o = 0;
  if (input !== null && input !== undefined) {
    const all = cBytes(input);
    const p = all.length > 256 ? all.subarray(0, 256) : all;
    let i = 0;
    while (i < p.length) {
      const c = p[i];
      if (c < 0x20 || c === 0x7F) {
        if (o + 1 >= cap) break;
        out.push(Buffer.from(' ')); o++; i++;
        continue;
      }
      const n = utf8SeqLen(p, i, p.length - i);
      if (n === 0) {
        if (o + 1 >= cap) break;
        out.push(Buffer.from('?')); o++; i++;
        continue;
      }
      if (o + n + 1 > cap) break;
      out.push(p.subarray(i, i + n));
      o += n;
      i += n;
    }
  }
  return Buffer.concat(out).toString('utf8');
}

/** copyUtf8Truncated: dst[cap]'e kopya; UTF-8 karakterini ortadan kesmez. */
export function copyUtf8Truncated(cap, input) {
  if (cap === 0) return '';
  const src = input === null || input === undefined ? Buffer.alloc(0) : cBytes(input);
  let n = src.length;
  if (n > cap - 1) n = cap - 1;
  if (src.length > 0 && n > 0 && n < src.length) {
    while (n > 0 && (src[n] & 0xC0) === 0x80) n--;
  }
  return src.subarray(0, n).toString('utf8');
}

/** Yalnizca [-]?[0-9]{1,9}; gecersizse null, aksi halde sayi. (Firmware: bool + out parametresi.) */
export function parseIntStrict(s) {
  if (s === null || s === undefined || s === '') return null;
  const str = String(s);
  let i = 0;
  let neg = false;
  if (str[0] === '-') { neg = true; i = 1; }
  let digits = 0;
  let v = 0;
  for (; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    if (ch < 48 || ch > 57) return null;
    v = v * 10 + (ch - 48);
    if (++digits > 9) return null;
  }
  if (digits === 0) return null;
  return neg ? -v : v;
}

/** Gunler (civil date) -> Unix epoch (UTC), Howard Hinnant days_from_civil. */
export function epochFromUtc(year, month, day, hour, minute, second) {
  const y = year - (month <= 2 ? 1 : 0);
  const era = Math.trunc((y >= 0 ? y : y - 399) / 400);
  const yoe = y - era * 400;
  const mp = (month + 9) % 12;
  const doy = Math.trunc((153 * mp + 2) / 5) + day - 1;
  const doe = yoe * 365 + Math.trunc(yoe / 4) - Math.trunc(yoe / 100) + doy;
  const days = era * 146097 + doe - 719468;
  return days * 86400 + hour * 3600 + minute * 60 + second;
}

/** Bosluksuz yazdirilabilir ASCII (0x21..0x7E) mi? */
export function isPrintableAsciiNoSpace(input) {
  const b = Buffer.isBuffer(input) ? input : Buffer.from(String(input), 'utf8');
  for (let i = 0; i < b.length; i++) if (b[i] < 0x21 || b[i] > 0x7E) return false;
  return true;
}
