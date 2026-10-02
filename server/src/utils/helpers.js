const crypto = require('crypto');

function successResponse(res, data = {}, message = 'Islem basarili', statusCode = 200) {
  return res.status(statusCode).json({
    success: true,
    message,
    data,
  });
}

/**
 * Hata govdesi: { success:false, message, code?, errors? }
 * `code` makine tarafindan okunabilir sabit bir koddur (ornegin GUEST_EXPIRED,
 * PIN_LOCKED, RATE_LIMITED). Istemci metne degil koda gore davranir.
 */
function errorResponse(res, message = 'Bir hata olustu', statusCode = 500, errors = null, code = null) {
  const response = {
    success: false,
    message,
  };
  if (code) response.code = code;
  if (errors) response.errors = errors;
  return res.status(statusCode).json(response);
}

/**
 * Servis katmaninda `throw new HttpError(403, 'Mesaj', 'KOD')` ile kullanilir.
 * Global hata yakalayici (`server.js`) `status` ve `code` alanlarini yanita aktarir;
 * 5xx hatalarinda ic mesaji istemciye sizdirmaz.
 */
class HttpError extends Error {
  constructor(status, message, code = null) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.statusCode = status;
    this.code = code;
  }
}

// Kriptografik olarak guvenli rakam dizisi (Math.random KULLANMAYIN).
function generateNumericPin(length = 6) {
  let pin = '';
  for (let i = 0; i < length; i++) {
    pin += crypto.randomInt(0, 10).toString();
  }
  return pin;
}

// Karisikliga yol acan karakterler (0/O, 1/I/L) cikarilmis kod alfabesi.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function generateCode(length = 10, alphabet = CODE_ALPHABET) {
  let out = '';
  for (let i = 0; i < length; i++) {
    out += alphabet[crypto.randomInt(0, alphabet.length)];
  }
  return out;
}

function generateRandomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('hex');
}

// Token/PIN gibi gizli degerler veritabaninda duz metin tutulmaz; SHA-256 ozeti tutulur.
function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

// Sabit zamanli karsilastirma (timing saldirilarina karsi). Uzunluklar farkliysa false.
function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) {
    // Uzunluk bilgisi sizmasin diye yine de sabit sureli bir karsilastirma yap.
    crypto.timingSafeEqual(ba, ba);
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isUuid(value) {
  return typeof value === 'string' && UUID_REGEX.test(value);
}

module.exports = {
  successResponse,
  errorResponse,
  HttpError,
  generateNumericPin,
  generateCode,
  generateRandomToken,
  sha256Hex,
  safeEqual,
  isUuid,
};
