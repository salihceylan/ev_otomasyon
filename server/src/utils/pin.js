'use strict';

// ==============================================================================
// AHBU Akilli Ev - PIN / kisa kod ozetleme (HMAC-SHA256 + PIN_PEPPER)
// ==============================================================================
//
// 6 haneli PIN'lerin (kurulum PIN'i, servis PIN'i, OTP kodlari) yalin SHA-256 ozeti
// 10^6 olasilik nedeniyle veritabani sizintisinda saniyeler icinde kirilir. Bu yuzden
// ozet, yalnizca sunucu ortaminda bulunan gizli bir anahtar (PIN_PEPPER) ile HMAC'lenir.
//
// Bicim:   "h1$" + 64 hex  (HMAC-SHA256(PIN_PEPPER, pin))
// Eski:    64 hex          (tuzsuz SHA-256(pin)) -> yalnizca DOGRULANIR, basarida yukseltilir.
//
// hashPin deterministiktir (ayni PIN -> ayni ozet); bu sayede servis PIN'i gibi
// "yalnizca PIN ile arama" gereken yerlerde `WHERE pin_hash = $1` sorgusu yapilabilir.
//
// API:
//   hashPin(pin)                      -> "h1$<hex>"          (PIN_PEPPER yoksa HATA firlatir)
//   verifyPin(pin, storedHash)        -> boolean             (sabit zamanli; eski bicimi de dogrular)
//   needsUpgrade(storedHash)          -> boolean             (eski tuzsuz bicim mi?)
//   verifyAndUpgrade(pin, storedHash) -> { valid, upgradedHash }
//        valid=true ve eski bicimse upgradedHash = hashPin(pin); cagiran bunu DB'ye yazar:
//          const { valid, upgradedHash } = verifyAndUpgrade(pin, row.pin_hash);
//          if (valid && upgradedHash) await tx.query('UPDATE ... SET pin_hash=$1 WHERE id=$2', [upgradedHash, row.id]);
//   assertPinConfig()                 -> PIN_PEPPER yoksa/kisaysa HATA (server.js acilista cagirir)
//
// GUVENLIK: PIN degerleri ve ozetleri log'a yazilmaz.

const crypto = require('crypto');

const HASH_PREFIX = 'h1$';
const MIN_PEPPER_LENGTH = 32;
const LEGACY_SHA256_RE = /^[0-9a-f]{64}$/i;
const CURRENT_RE = /^h1\$[0-9a-f]{64}$/;

class PinConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'PinConfigError';
  }
}

function getPepper() {
  const pepper = process.env.PIN_PEPPER;
  if (!pepper || String(pepper).length < MIN_PEPPER_LENGTH) {
    throw new PinConfigError(
      `[PIN] PIN_PEPPER tanimli degil veya ${MIN_PEPPER_LENGTH} karakterden kisa. PIN ozetleme yapilamaz (fail-closed).`
    );
  }
  return String(pepper);
}

/** Sunucu acilisinda cagrilir; yapilandirma eksikse sunucu BASLAMAZ. */
function assertPinConfig() {
  getPepper();
  return true;
}

function normalizePin(pin) {
  if (pin === null || pin === undefined) return '';
  return String(pin).trim();
}

function hmacHex(value) {
  return crypto.createHmac('sha256', getPepper()).update(value, 'utf8').digest('hex');
}

function sha256HexRaw(value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex');
}

/**
 * PIN'i HMAC-SHA256(PIN_PEPPER) ile ozetler. Bos PIN kabul edilmez.
 * @returns {string} "h1$" + 64 hex
 */
function hashPin(pin) {
  const p = normalizePin(pin);
  if (!p) {
    throw new TypeError('[PIN] Bos PIN ozetlenemez.');
  }
  return HASH_PREFIX + hmacHex(p);
}

// Esit uzunluklu hex dizilerini sabit zamanda karsilastirir.
function constantTimeHexEqual(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) {
    crypto.timingSafeEqual(ba, ba);
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

function needsUpgrade(storedHash) {
  return typeof storedHash === 'string' && LEGACY_SHA256_RE.test(storedHash);
}

/**
 * Ayrintili dogrulama. Hicbir durumda istisna firlatmaz (PIN_PEPPER eksikligi haric:
 * yapilandirma hatasi oldugu icin yukari tasinir ve istek 500 ile reddedilir).
 * @returns {{ valid: boolean, upgradedHash: string|null }}
 */
function verifyAndUpgrade(pin, storedHash) {
  const p = normalizePin(pin);
  // Yapilandirma eksikse dogrulama YAPILMAZ (eski ozetler dahil) -> fail-closed.
  getPepper();

  if (!p || typeof storedHash !== 'string' || storedHash.length === 0) {
    // Zamanlama farkini azaltmak icin yine de bir HMAC hesapla.
    hmacHex(p || 'x');
    return { valid: false, upgradedHash: null };
  }

  if (CURRENT_RE.test(storedHash)) {
    const candidate = HASH_PREFIX + hmacHex(p);
    return { valid: constantTimeHexEqual(candidate, storedHash), upgradedHash: null };
  }

  if (LEGACY_SHA256_RE.test(storedHash)) {
    const candidate = sha256HexRaw(p);
    const valid = constantTimeHexEqual(candidate, storedHash.toLowerCase());
    return { valid, upgradedHash: valid ? hashPin(p) : null };
  }

  // Taninmayan bicim (duz metin vb.) ASLA kabul edilmez.
  hmacHex(p);
  return { valid: false, upgradedHash: null };
}

/**
 * PIN dogrulama (boolean). Sabit zamanli karsilastirma kullanir.
 * Eski tuzsuz SHA-256 ozetlerini de kabul eder; yukseltme icin verifyAndUpgrade kullanin.
 */
function verifyPin(pin, storedHash) {
  return verifyAndUpgrade(pin, storedHash).valid === true;
}

module.exports = {
  hashPin,
  verifyPin,
  verifyAndUpgrade,
  needsUpgrade,
  assertPinConfig,
  PinConfigError,
  HASH_PREFIX,
  MIN_PEPPER_LENGTH,
};
