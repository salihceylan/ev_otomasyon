'use strict';

// ==============================================================================
// Kucuk gizli degerlerin (ornegin cihaz yerel anahtari / local_key) veritabaninda
// SIFRELI saklanmasi icin AES-256-GCM kutusu. CONTRACTS §3 ve §6.
//
//   encrypt(plaintext) -> 'v1:<iv>:<tag>:<sifreli>'   (hepsi base64url)
//   decrypt(stored)    -> plaintext
//   generateLocalKey() -> 16 karakterlik rastgele yerel anahtar
//
// Anahtar: LOCAL_KEY_SECRET ortam degiskeni, 32 bayt = 64 onaltilik (hex) karakter.
// Yoksa/gecersizse fonksiyonlar ACIK hata firlatir (fail-closed); varsayilan anahtar YOKTUR.
// Hata mesajlari anahtar veya acik metin icermez.
// ==============================================================================

const crypto = require('crypto');

const FORMAT_VERSION = 'v1';
const IV_BYTES = 12; // GCM icin onerilen nonce uzunlugu
const TAG_BYTES = 16;
const MAX_PLAINTEXT_CHARS = 4096;

// local_key: HTTP basligina ve JSON'a guvenli; karisan karakterler (0/O/1/I/l/o) cikarilmis (56 sembol).
// 16 karakter ~ 93 bit entropi. Firmware 8..32 karakter kabul eder (CONTRACTS §3).
const LOCAL_KEY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
const LOCAL_KEY_LENGTH = 16;
// Firmware'in kabul ettigi biçim (CONTRACTS §3b): 8..32 karakter, yalnizca ASCII 0x21-0x7E (bosluk/kontrol karakteri yok).
const LOCAL_KEY_PATTERN = /^[\x21-\x7E]{8,32}$/;

const KEY_HEX_PATTERN = /^[0-9a-fA-F]{64}$/;

/** Ortamdan 32 baytlik anahtari okur; yoksa/gecersizse firlatir. */
function loadKey() {
  const raw = process.env.LOCAL_KEY_SECRET;
  if (typeof raw !== 'string' || raw.length === 0) {
    throw new Error(
      'LOCAL_KEY_SECRET tanimli degil. Sifreleme yapilamaz (32 bayt = 64 onaltilik karakter olmali).'
    );
  }
  if (!KEY_HEX_PATTERN.test(raw)) {
    throw new Error('LOCAL_KEY_SECRET gecersiz: 32 bayt (64 onaltilik karakter) olmali.');
  }
  return Buffer.from(raw, 'hex');
}

/** LOCAL_KEY_SECRET gecerli bicimde tanimli mi (firlatmadan kontrol). */
function isConfigured() {
  try {
    loadKey();
    return true;
  } catch (_) {
    return false;
  }
}

/** Duz metni AES-256-GCM ile sifreler. Her cagrida yeni rastgele IV kullanilir. */
function encrypt(plaintext) {
  if (typeof plaintext !== 'string' || plaintext.length === 0 || plaintext.length > MAX_PLAINTEXT_CHARS) {
    throw new TypeError('Sifrelenecek deger bos olmayan, makul uzunlukta bir metin olmali.');
  }
  const key = loadKey();
  const iv = crypto.randomBytes(IV_BYTES);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv, { authTagLength: TAG_BYTES });
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [
    FORMAT_VERSION,
    iv.toString('base64url'),
    tag.toString('base64url'),
    ciphertext.toString('base64url'),
  ].join(':');
}

/** encrypt() ciktisini cozer. Bozuk/kurcalanmis/yanlis anahtarli veride GENEL bir hata firlatir. */
function decrypt(stored) {
  const key = loadKey(); // anahtar sorunu ayri ve acik bildirilir
  const fail = () => new Error('Sifreli deger cozulemedi (bozuk veya yanlis anahtar).');

  if (typeof stored !== 'string') throw fail();
  const parts = stored.split(':');
  if (parts.length !== 4 || parts[0] !== FORMAT_VERSION) throw fail();

  try {
    const iv = Buffer.from(parts[1], 'base64url');
    const tag = Buffer.from(parts[2], 'base64url');
    const ciphertext = Buffer.from(parts[3], 'base64url');
    if (iv.length !== IV_BYTES || tag.length !== TAG_BYTES || ciphertext.length === 0) throw fail();

    const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv, { authTagLength: TAG_BYTES });
    decipher.setAuthTag(tag);
    const plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return plain.toString('utf8');
  } catch (_) {
    throw fail();
  }
}

/** Cihaz yerel anahtari uretir (crypto.randomInt; Math.random YASAK). */
function generateLocalKey() {
  let out = '';
  for (let i = 0; i < LOCAL_KEY_LENGTH; i++) {
    out += LOCAL_KEY_ALPHABET[crypto.randomInt(0, LOCAL_KEY_ALPHABET.length)];
  }
  return out;
}

/** Anahtar firmware biçimine (8..32 karakter, ASCII 0x21-0x7E) uyuyor mu? */
function isValidLocalKey(value) {
  return typeof value === 'string' && LOCAL_KEY_PATTERN.test(value);
}

module.exports = {
  encrypt,
  decrypt,
  generateLocalKey,
  isValidLocalKey,
  isConfigured,
  LOCAL_KEY_LENGTH,
  LOCAL_KEY_ALPHABET,
  LOCAL_KEY_PATTERN,
};
